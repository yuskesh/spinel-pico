# Time layer (PIO::TimedProgram): write PIO programs in units of time
require_relative "pio/asm"
require_relative "pio/encode"

module Pico
  module PIO
    # ---- PIO instruction format from the RP2040 datasheet (section 3.4) ----
    MAX_INSTRUCTIONS = 32       # size of instruction memory
    MAX_DELAY = 31              # delay field (5 bits when side-set is not used)
    MAX_SET_DATA = 31           # set data field (5 bits)
    DELAY_SHIFT = 8             # position of the delay field (bits 8-12)
    NS_PER_SECOND = 1_000_000_000

    # Instruction opcodes (bits 13-15)
    OP_JMP  = 0x0000
    OP_OUT  = 0x6000
    OP_PULL = 0x8080            # same opcode as push; bit 7 = 1 means pull
    OP_MOV  = 0xA000
    OP_SET  = 0xE000

    # jmp conditions (bits 5-7)
    JMP_ALWAYS   = 0 << 5
    JMP_X_DEC    = 2 << 5       # jump if x is nonzero, then decrement x
    JMP_PIN      = 6 << 5       # jump if the JMP pin is high
    JMP_NOT_Y    = 3 << 5       # jump if y is zero (y unchanged)
    JMP_Y_DEC    = 4 << 5       # jump if y is nonzero, then decrement y
    JMP_NOT_OSRE = 7 << 5       # jump if the bits shifted out of OSR have not reached the threshold

    # pull fields
    PULL_NOBLOCK = 0 << 5       # bit 5 (block) = 0: if the FIFO is empty, don't wait; copy X to OSR
    PULL_BLOCK   = 1 << 5       # if the FIFO is empty, stall until a word arrives

    # mov / set / out destination (bits 5-7) and mov source (bits 0-2)
    DEST_PINS = 0 << 5
    DEST_X    = 1 << 5
    DEST_Y    = 2 << 5
    DEST_NULL = 3 << 5          # out only
    DEST_OSR  = 7 << 5
    SRC_PINS  = 0
    SRC_X     = 1
    SRC_Y     = 2
    SRC_NULL  = 3
    SRC_ISR   = 6
    SRC_OSR   = 7

    # Register usage
    #   X: holds the value received by inbox.current (used by pull noblock when the FIFO is empty)
    #   Y: wait counter. Inside each_bit it holds the current iteration's bit
    #   OSR: word received by inbox.take; each_bit shifts it out 1 bit at a time (count via jmp !osre, no register used)
    #   ISR: bits read by input.sample, sent to the RX FIFO by outbox.push or autopush

    module_function

    def jmp(cond, addr) = OP_JMP | cond | addr
    def pull(flags)     = OP_PULL | flags
    def mov(dest, src)  = OP_MOV | dest | src
    def out(dest, bits) = OP_OUT | dest | (bits & 31)
    def nop             = mov(DEST_Y, SRC_Y)      # same encoding as pioasm's nop (mov y, y)
    def set(dest, data)
      raise "set value must be 0..#{MAX_SET_DATA}" unless data.between?(0, MAX_SET_DATA)
      OP_SET | dest | data
    end

    # value received by inbox.current (held in X; at most one per program) or set by the CPU before the start with
    # inbox.preset (held in the ISR)
    class Received
      attr_reader :src
      def initialize(src) = @src = src
    end

    class Cycles
      attr_reader :n
      def initialize(n) = @n = n
    end

    class Duration
      attr_reader :ns
      def initialize(ns) = @ns = ns
    end

    # wait whose length depends on the bit value (sleep bit.pick(when 1, when 0); pin -1) or on an input's level
    # (sleep din.pick(when high, when low); pin = the input's position)
    class Choice
      attr_reader :one, :zero, :pin
      def initialize(one, zero, pin)
        @one = one
        @zero = zero
        @pin = pin
      end
    end

    # bit of one each_bit iteration (loaded into Y with out y, 1 on first use in that iteration)
    class Bit
      def initialize(prog) = @prog = prog
      def pick(one, zero) = Choice.new(one, zero, -1)
      # bit.branch { |one| if one ... else ... end }: different statements for bit 1 and bit 0 (see TimedProgram#branch_on)
      def branch(&block) = @prog.branch_on(-1, "bit", &block)
    end

    # the next n bits of the words received with autopull (inbox.next(n))
    class Chunk
      attr_reader :n
      def initialize(n) = @n = n
    end

    # word received by inbox.take (held in OSR)
    class Word
      def initialize(prog) = @prog = prog
      # n bits one at a time, from the top bit (order: :msb) or the bottom bit (:lsb)
      def each_bit(n, order: :msb, &block) = @prog.bit_loop(n, order, false, &block)
    end

    # output :name: a SET pin (set pins in the order declared; see TimedProgram#set_change), or with side: true a
    # side-set pin, changed by side-set: then it takes no instruction of its own (see TimedProgram#side_change)
    # output :name, out: true: the OUT pin (one), written with mov pins
    class Output
      def initialize(prog, name, side, set)
        @prog = prog
        @name = name
        @side = side
        @set = set
      end
      def on  = @set == -2 ? @prog.emit_user(PIO.mov(DEST_PINS, 0x08 | SRC_NULL), "#{@name}.on", true) :
                (@side < 0 ? @prog.set_change(@set, 1, "#{@name}.on") : @prog.side_change(@side, 1, "#{@name}.on"))
      def off = @set == -2 ? @prog.emit_user(PIO.mov(DEST_PINS, SRC_NULL), "#{@name}.off", true) :
                (@side < 0 ? @prog.set_change(@set, 0, "#{@name}.off") : @prog.side_change(@side, 0, "#{@name}.off"))

      # put(bit) inside each_bit: the OUT pin takes the bit (mov pins, y)
      def put(bit)
        raise "#{@prog.class}: #{@name}.put: only an OUT pin (output :#{@name}, out: true) takes a bit" unless @set == -2
        @prog.put_bit("#{@name}.put(bit)")
      end

      # write(inbox.next(n)): the next n bits of the received words onto the OUT pins at once (out pins, n)
      def write(chunk)
        raise "#{@prog.class}: #{@name}.write: only an OUT output (output :#{@name}, out: true) takes bits" unless @set == -2
        @prog.write_chunk(chunk.n, "#{@name}.write(inbox.next(#{chunk.n}))")
      end
    end

    # input :name. Inputs are IN pins in the order declared (the first is the IN base)
    class Input
      def initialize(prog, index, name)
        @prog = prog
        @index = index
        @name = name
      end
      # wait 1 pin n / wait 0 pin n: stall until the pin is high / low
      def wait_high = @prog.emit_wait(Encode.wait_pin(true, @index), "#{@name}.wait_high")
      def wait_low  = @prog.emit_wait(Encode.wait_pin(false, @index), "#{@name}.wait_low")
      # in pins, width: shift this pin and the width - 1 inputs declared after it into the ISR. in reads from the IN
      # base, so only the first input can be sampled
      def sample(width = 1)
        raise "#{@prog.class}: #{@name}.sample: only the first input declared can be sampled (in reads from the IN base pin)" if @index != 0
        n = @prog.class.inputs.size
        raise "#{@prog.class}: #{@name}.sample(#{width}): width must be 1-#{n} (the inputs declared)" unless width.between?(1, n)
        @prog.use_isr(:data)
        @prog.emit_user(Encode.in_(:pins, width), width == 1 ? "#{@name}.sample" : "#{@name}.sample(#{width})")
      end

      # sleep din.pick(when high, when low): a wait whose length depends on the pin, read by a jmp pin at the start of the
      # wait (report says how many cycles after the previous statement). The pin becomes the state machine's JMP pin, so
      # only one input can be picked on
      def pick(high, low) = Choice.new(high, low, @index)

      # din.branch { |high| if high ... else ... end }: different statements while the pin is high and while it is low
      # (see TimedProgram#branch_on). The pin becomes the JMP pin, as for pick
      def branch(&block) = @prog.branch_on(@index, @name.to_s, &block)
    end

    # values sent to the CPU through the RX FIFO
    class Outbox
      def initialize(prog) = @prog = prog
      # push block: send the ISR (stalls while the RX FIFO is full)
      def push
        @prog.use_isr(:data)
        @prog.emit_user(Encode.push(false, true), "outbox.push")
      end
      # push the ISR by itself every n bits (autopush), shifting in from the top bit first (order: :msb) or the bottom
      def autopush(n, order: :msb) = @prog.set_autopush(n, order)
    end

    # IRQ flag n (0-7) of the PIO block; rel: true adds the state machine number (pioasm's rel)
    class IrqFlag
      def initialize(prog, n, rel)
        raise "#{prog.class}: irq flag must be 0-7 (got #{n})" unless n.between?(0, 7)
        @prog = prog
        @n = n
        @rel = rel
      end
      def label = "irq(#{@n}#{@rel ? ', rel: true' : ''})"
      # irq set n: raise the flag and go on
      def set = @prog.emit_user(Encode.irq_set(@rel, @n), "#{label}.set")
      # irq wait n: raise the flag and stall until something (the CPU or another SM) clears it
      def set_and_wait = @prog.emit_wait(Encode.irq_wait(@rel, @n), "#{label}.set_and_wait")
      # irq clear n
      def clear = @prog.emit_user(Encode.irq_clear(@rel, @n), "#{label}.clear")
      # wait 1 irq n: stall until the flag is raised, then clear it
      def wait = @prog.emit_wait(Encode.wait_irq(true, @rel, @n), "#{label}.wait")
    end

    class Inbox
      def initialize(prog) = @prog = prog

      # current inbox value: replaced by the next word if one is in the FIFO, otherwise keeps the previous value (X).
      # Does not drain the FIFO (one word per call)
      def current
        @prog.take_inbox(:current)
        @prog.emit_user(PIO.pull(PULL_NOBLOCK), "inbox.current")
        @prog.emit_user(PIO.mov(DEST_X, SRC_OSR), "inbox.current")
        Received.new(:x)
      end

      # a value the CPU puts in the ISR before starting the state machine (StateMachine#load_isr; in C, the header's
      # <name>_load_preset), as pico-examples' PWM keeps its period. It takes no instruction and stays until the CPU
      # loads another; the ISR is then not free for sample, push or autopush
      def preset
        @prog.use_isr(:preset)
        Received.new(:isr)
      end

      # stream bits without word boundaries (autopull). Must be the only thing inside loop.
      # Each iteration's bit is loaded at the head of the iteration (after the previous iteration's last statement), so that is where it stalls on an empty FIFO
      def each_bit(n, order: :msb, &block)
        @prog.take_inbox(:take)
        @prog.bit_loop(n, order, true, &block)
      end

      # inbox.next(n): the next n bits of the received words, for Output#write. The words are pulled by themselves
      # (autopull, every `word` bits, from the top bit with order: :msb), so out stalls while the TX FIFO is empty.
      # Takes no instruction itself
      def next(n, word: 32, order: :msb)
        @prog.take_inbox(:next)
        @prog.set_autopull(n, word, order)
        Chunk.new(n)
      end

      # receive the next word; stall until one arrives (the pin stays as it is meanwhile)
      def take
        @prog.take_inbox(:take)
        @prog.emit_user(PIO.pull(PULL_BLOCK), "inbox.take")
        Word.new(@prog)
      end
    end

    class TimedProgram
      # output :led (a SET pin; only one), output :clk, side: true (side-set pins, in the order declared).
      # (Spinel expands these define_method calls only in this shape: helper calls, then define_method)
      def self.output(name, side: false, out: false, width: 1)
        register_output(name, side, out, width)
        define_method(name) { Pico::PIO::Output.new(self, name, self.class.side_index(name), self.class.set_index(name)) }
      end

      # input :din (IN pins, in the order declared)
      def self.input(name)
        register_input(name)
        define_method(name) { Pico::PIO::Input.new(self, self.class.input_index(name), name) }
      end

      def self.register_output(name, side, out, width)
        raise "#{self}: output :#{name}: width is for an OUT output (out: true)" if width != 1 && !out
        raise "#{self}: output :#{name}: width must be 1-32 (got #{width})" unless width.between?(1, 32)
        if out
          @out_outputs = [] if @out_outputs.nil?
          @out_outputs << name
          @out_width = width
        elsif side
          @side_outputs = [] if @side_outputs.nil?
          @side_outputs << name
        else
          @set_outputs = [] if @set_outputs.nil?
          @set_outputs << name
        end
      end

      def self.register_input(name)
        @inputs = [] if @inputs.nil?
        @inputs << name
      end

      def self.side_index(name) = @side_outputs.nil? ? -1 : (@side_outputs.index(name) || -1)
      def self.input_index(name) = @inputs.index(name)
      def self.set_index(name)
        return -2 if !@out_outputs.nil? && @out_outputs.include?(name)      # the OUT pin
        @set_outputs.nil? ? -1 : (@set_outputs.index(name) || -1)
      end
      def self.out_outputs = @out_outputs.nil? ? [] : @out_outputs
      def self.out_width = @out_width.nil? ? 0 : @out_width
      def self.side_outputs = @side_outputs.nil? ? [] : @side_outputs
      def self.set_outputs = @set_outputs.nil? ? [] : @set_outputs
      def self.inputs = @inputs.nil? ? [] : @inputs

      # PIO clock (Hz), per program class. Used only for calculation; the SM's clkdiv is set by the caller
      def self.clock(hz = nil)
        @clock = hz if hz
        raise "#{self}: clock is not specified" unless @clock
        @clock
      end

      # tolerance. When given, sleep lengths are rounded to the nearest cycle count, and it stops if the deviation exceeds this.
      # When omitted, no rounding (stops unless the length is an exact multiple of the clock period)
      def self.tolerance(t = nil)
        @tolerance = t if t
        @tolerance
      end

      def clock_hz = self.class.clock
      def side_count = self.class.side_outputs.size

      # delay limit: the side-set bits take the top of the 5-bit delay field
      def max_delay = (1 << (5 - side_count)) - 1

      def initialize
        raise "#{self.class}: at most 5 side-set outputs (got #{side_count})" if side_count > 5
        raise "#{self.class}: at most 5 SET outputs (got #{self.class.set_outputs.size})" if self.class.set_outputs.size > 5
        raise "#{self.class}: only one OUT output (got #{self.class.out_outputs.size})" if self.class.out_outputs.size > 1
        @words = []
        @delay = []                         # delay per instruction (0..max_delay)
        @reps = []                          # times each instruction runs per iteration (excluding the n part). Used only for branch-free programs
        @per_n = []                         # times each instruction runs per iteration in proportion to n (inbox.current)
        @per_m = []                         # same for m (inbox.preset)
        @isr_use = nil                      # :preset or :data (sample, push, autopush)
        @loops = []                         # marks a jmp y-- to itself (no delay can be added here)
        @user = []                          # whether the instruction corresponds to a user statement (sleep measures between these) or was added by the builder
        @labels = {}                        # branch target name -> position
        @fixups = {}                        # position -> jump target name (filled in by finish)
        @label_count = 0
        @nomerge = {}                       # no delay can be added to the instruction just before this position (a branch target label is here)
        @outputs = []                       # positions and names of instructions that change the pin
        @recv_movs = []                     # positions of the mov y, x for sleep(received value)
        @notes = []                         # lengths of built segments [previous statement, next statement, description]
        @inbox_use = nil
        @loop_state = :before               # :before → :inside → :after
        @wrap_from = 0
        @wrap_to = 0
        @pending = nil                      # pending sleep: Integer or [when 1, when 0]
        @since = 0                          # cycles from the start of the previous statement's instruction to the current position
        @last_label = nil                   # name of the previous statement
        @branchy = false                    # whether branches were built (if so, segment lengths are reported from @notes)
        @in_bits = false
        @bit_loaded = false
        @bits_used = false
        @out_shift_right = nil
        @pull_threshold = nil
        @autopull = false
        @pending_tol = nil                  # tolerance for the pending sleep (in units of q)
        @rounded = []                       # rounded segments [previous statement, next statement, written q, cycles, tolerance q]
        @bit_notes = []                     # segment lengths inside each_bit [when 1, when 0] (cycles)
        @stream_at = nil                    # position where inbox.each_bit starts
        @set_mask = []                      # SET pins a set pins instruction changes (bit per SET output)
        @set_val = []
        @side_mask = []                     # side-set pins each instruction changes (bit per side output)
        @side_val = []                      # their new levels
        @pside_mask = 0                     # side-set change written but not yet placed on an instruction
        @pside_val = 0
        @pside_label = nil
        @dside_mask = 0                     # side-set change waiting for the first instruction of the sleep after it
        @dside_val = 0
        @dside_label = nil
        @last_user_at = -1                  # position of the last user statement's instruction
        @stalls = []                        # positions of instructions that wait without an upper bound
        @in_shift_right = nil
        @push_threshold = nil
        @autopush = false
        @jmp_pin = -1                       # input picked on (the JMP pin)
        @osr_pins = false                   # another input is read through the OSR
        @pin_in_bits = false
        @repeat_at = -1                     # start of the repeat body while inside it
        @repeats = false
        @repeat_depth = 0
        @bits_in_repeat = false
        @repeat_in_bits = false
        @y_counts = 0                       # inside a repeat that counts in Y
        @branch_ats = []                    # positions of the jmp of each branch
        @in_bit_branch = false
        @path_bit = 0
        @zero_ok = false
        @path_resets = {}                   # position -> the branch instruction whose pin levels the path starts from
        @path_merges = []                   # [last instruction of one path, of the other] that must leave the same levels
      end

      def outbox = Outbox.new(self)
      def irq(n, rel: false) = IrqFlag.new(self, n, rel)

      # the ISR holds either inbox.preset or data on its way to the RX FIFO
      def use_isr(kind)
        if !@isr_use.nil? && @isr_use != kind
          raise "#{self.class}: inbox.preset keeps its value in the ISR, which sample, outbox.push and outbox.autopush use"
        end
        @isr_use = kind
      end

      def set_autopush(n, order)
        use_isr(:data)
        raise "#{self.class}: outbox.autopush bit count must be 1..32" unless n.between?(1, 32)
        raise "#{self.class}: order must be :msb or :lsb" unless order == :msb || order == :lsb
        raise "#{self.class}: outbox.autopush can be given only once (one ISR threshold per state machine)" unless @push_threshold.nil?
        @in_shift_right = order == :lsb       # MSB first: shift left, so the first bit ends up at the top
        @push_threshold = n
        @autopush = true
      end

      # fixed loop period: no branches, bit loops or waits
      def fixed? = !(@branchy || @bits_used || !@stalls.empty?)

      def inbox = Inbox.new(self)

      # ---- OUT pin ----
      def put_bit(label)
        raise "#{self.class}: put(bit) is allowed only inside each_bit" unless @in_bits
        unless @bit_loaded
          resolve(1, label)                 # out y, 1 comes just before the statement's mov
          load_bit
        end
        emit_user(PIO.mov(DEST_PINS, SRC_Y), label, true)
      end

      def set_autopull(n, word, order)
        raise "#{self.class}: inbox.next bit count must be 1..32" unless n.between?(1, 32)
        raise "#{self.class}: inbox.next word: must be 1..32" unless word.between?(1, 32)
        raise "#{self.class}: order must be :msb or :lsb" unless order == :msb || order == :lsb
        if @pull_threshold.nil?
          @pull_threshold = word
          @out_shift_right = order == :lsb
          @autopull = true
        elsif @pull_threshold != word || @out_shift_right != (order == :lsb)
          raise "#{self.class}: inbox.next: every inbox.next shares one word: and order: (one OSR setting per state machine)"
        end
      end

      def write_chunk(n, label)
        w = self.class.out_width
        raise "#{self.class}: #{label}: #{n} bits for #{w} OUT pins (they must match)" if n != w
        emit_user(Encode.out(:pins, n), label, true)
      end

      # ---- repeat ----
      # repeat(n) { ... }: the body n times (1-32), counted in X (set x, n - 1 before it, jmp x-- after it). The last
      # sleep in the body leads to the next pass and, after the last pass, to the statement after the repeat (a sleep
      # written after the repeat adds to it)
      def repeat(n)
        raise "#{self.class}: repeat count must be 1..32 (got #{n})" unless n.between?(1, 32)
        raise "#{self.class}: repeat is allowed only inside loop" unless @loop_state == :inside
        inner = @repeat_depth > 0            # a repeat inside a repeat counts in Y
        raise "#{self.class}: repeat can be nested only once (the counters are X and Y)" if @repeat_depth > 1
        raise "#{self.class}: a repeat inside a repeat counts in Y, which each_bit uses for the bit" if inner && @in_bits
        if !inner && @inbox_use == :current
          raise "#{self.class}: repeat counts in X, which inbox.current uses for the received value"
        end
        @repeats = true
        @repeat_in_bits = true if @in_bits
        @branchy = true
        flush_side
        resolve(1, "repeat")                # set x / set y comes just before the body's first statement
        emit(PIO.set(inner ? DEST_Y : DEST_X, n - 1))
        @since += 1
        start = new_label
        place_label(start)
        outer_at = @repeat_at
        @repeat_at = @words.size
        body_at = @words.size
        @repeat_depth += 1
        @y_counts += 1 if inner             # waits inside cannot use Y (nops only)
        yield
        flush_side
        raise "#{self.class}: no statements inside repeat" if (body_at...@words.size).none? { |i| @user[i] }
        head = head_cycles(body_at)
        c = resolve(1 + head, "next repeat")
        check_deferred_side
        emit_jump(inner ? JMP_Y_DEC : JMP_X_DEC, start)
        @y_counts -= 1 if inner
        @repeat_depth -= 1
        @since += 1
        @since = -head unless c.nil?        # count a following sleep from where the body's last sleep ends
        shorter = head > 0 ? " (#{head} cycles shorter)" : ""
        @notes << ["repeat(#{n})", "", "the body #{n} times (counted in #{inner ? 'Y' : 'X'}); after the last pass, the body's last sleep leads to the next statement#{shorter}"]
        @repeat_at = outer_at
      end

      # cycles from position `from` to the first statement after it: up to the first statement's instruction, or, when
      # a branch comes first, up to and including its jmp (each path's first statement follows it)
      def head_cycles(from)
        first_user = (from...@words.size).find { |i| @user[i] }
        first_branch = @branch_ats.find { |i| i >= from }
        stop = first_user.nil? ? @words.size : first_user
        stop = first_branch + 1 if !first_branch.nil? && first_branch < stop
        (from...stop).sum { |i| 1 + @delay[i] }
      end

      # ---- branch ----
      # din.branch { |high| ... } / bit.branch { |one| ... }: the block runs twice, once per path (first the path that
      # falls through the jmp, then the one it jumps to), and its statements go into that path:
      #   jmp pin taken / jmp !y taken    (one instruction; for a bit, out y, 1 first if the bit is not loaded yet)
      #   <the other path>; jmp end
      #   taken: <this path>
      #   end:
      # The sleep before the branch leads to the first statement of each path (a sleep at the head of a path adds to it). Each path's last sleep leads to the
      # statement after the branch (in each_bit, the next bit's first statement), and a sleep written after the branch
      # adds to it (as for repeat): the paths are padded so that the same number of cycles is left at the end, and that
      # is carried past the end as a sleep. Both paths end with a sleep, or neither. A pin the paths leave at different
      # levels must be changed before an instruction drives it again (see levels)
      def branch_on(pin, name)
        raise "#{self.class}: #{name}.branch is allowed only inside loop" unless @loop_state == :inside
        raise "#{self.class}: bit.branch inside a bit.branch (the bit is already known there)" if pin < 0 && @in_bit_branch
        label = "#{name}.branch"
        if pin < 0
          raise "#{self.class}: bit.branch is allowed only inside each_bit" unless @in_bits
          raise "#{self.class}: bit.branch cannot follow a bit.pick in the same segment" if @pending.is_a?(Array) && @pending[2] < 0 && !@bit_loaded
        else
          claim_pin(pin)
          @pin_in_bits = true if @in_bits
        end
        via_y = pin >= 0 && pin != @jmp_pin
        flush_side
        resolve(via_y ? 1 + pin_load_cycles(pin) : (pin < 0 && !@bit_loaded ? 2 : 1), label)
        load_bit if pin < 0
        load_pin(pin) if via_y
        check_deferred_side
        @branchy = true
        outer_bit = @path_bit
        outer_in_bit = @in_bit_branch
        @in_bit_branch = true if pin < 0
        taken = new_label
        done = new_label
        branch_at = @words.size
        @branch_ats << branch_at
        emit_jump(pin < 0 || via_y ? JMP_NOT_Y : JMP_PIN, taken)
        fall = pin < 0 || via_y             # jmp !y falls through on bit 1 (or a high pin read into Y); jmp pin on low
        names = pin < 0 ? ["bit 1", "bit 0"] : ["#{name} high", "#{name} low"]
        f_name = fall ? names[0] : names[1]
        t_name = fall ? names[1] : names[0]
        start_path(label, f_name, pin < 0 ? 1 : outer_bit)
        yield fall
        nf = @bit_notes.size
        rf = end_path(1, label, f_name)
        f_note = @bit_notes.size > nf ? nf : -1
        if !rf.nil? && rf > max_delay                  # what is left must fit the delay of the jmp to the end
          pad(rf - max_delay, "the statement after #{label} [#{f_name}]")
          rf = max_delay
        end
        fall_end = @words.size
        emit_jump(JMP_ALWAYS, done)
        check_deferred_side
        place_label(taken)
        @path_resets[@words.size] = branch_at
        start_path(label, t_name, pin < 0 ? 2 : outer_bit)
        yield !fall
        nt = @bit_notes.size
        rt = end_path(0, label, t_name)
        t_note = @bit_notes.size > nt ? nt : -1
        if rf.nil? != rt.nil?
          raise "#{self.class}: #{label}: both paths end with a sleep (to the statement after the branch), or neither"
        end
        unless rf.nil?
          r = rf < rt ? rf : rt
          @delay[fall_end] = rf - r                     # the rest of the fall-through path's wait, on its jmp to the end
          pad(rt - r, "the statement after #{label} [#{t_name}]")
          # the r cycles both paths still wait are counted again by the sleep carried past the end
          take_off_note(f_note, r)
          take_off_note(t_note, r)
        end
        check_deferred_side
        @path_merges << [fall_end, @words.size == fall_end + 1 ? branch_at : @words.size - 1, @words.size]
        place_label(done)
        @in_bit_branch = outer_in_bit
        @path_bit = outer_bit
        @since = 0
        @last_label = "end of #{label}"
        @last_user_at = -1
        @pending = rf.nil? ? nil : r * NS_PER_SECOND   # the cycles both paths still wait, carried past the end
        @zero_ok = true
      end

      # path_bit: inside each_bit, which bit the path runs for (1: bit 1, 2: bit 0; 0 otherwise), for the bit totals
      # A path counts from its start (right after the branch): a sleep at its head adds to the sleep before the branch
      def start_path(label, path, path_bit)
        @path_bit = path_bit
        @since = 0
        @last_label = "#{label} [#{path}]"
        @last_user_at = -1                  # nothing may join the instruction before the path
        @nomerge[@words.size] = true
      end

      # the path's last sleep leads to the statement after the branch: returns the cycles still to wait after the path's
      # last instruction (tail: the jmp to the end), or nil if the path ends without a sleep
      def end_path(tail, label, path)
        flush_side
        if @pending.nil?
          @notes << [@last_label, "end of #{label}", "#{@since + tail} [#{path}, no sleep: the next statement follows the end]"]
          return nil
        end
        raise "#{self.class}: #{label}: a path cannot end with a pick" if @pending.is_a?(Array)
        p = @pending
        @pending = nil
        zero = p == 0 && @zero_ok                     # carried from a branch inside this path: nothing more to wait
        @zero_ok = false
        c = zero ? @since + tail : round_q(p, take_tolerance, @last_label, "the statement after #{label} [#{path}]")
        if zero && (@since > 0 || tail > 0)
          raise "#{self.class}: #{@last_label} → the statement after #{label}: too short a sleep (the jmp to the end needs a cycle)" if tail > 0
        end
        r = c - @since - tail
        raise "#{self.class}: #{@last_label} → the statement after #{label}: too short a sleep (the path's instructions already take #{-r} cycles more)" if r < 0
        @notes << [@last_label, "the statement after #{label}", "#{cyc_ns(c)} [#{path}]"]
        add_bit_note(c)
        r
      end

      def take_off_note(i, r)
        return if i < 0
        n = @bit_notes[i]
        @bit_notes[i] = [n[0] > 0 ? n[0] - r : 0, n[1] > 0 ? n[1] - r : 0]
      end

      # segment lengths inside each_bit, for the totals per bit: a path of bit.branch counts only for its bit
      def add_bit_note(c)
        return unless @in_bits
        @bit_notes << (@path_bit == 1 ? [c, 0] : (@path_bit == 2 ? [0, c] : [c, c]))
      end

      def take_inbox(kind)
        raise "#{self.class}: inbox uses the OSR, which reads the second input this program branches on" if @osr_pins
        raise "#{self.class}: inbox.current keeps the received value in X, which repeat uses" if kind == :current && @repeats
        if kind == :current && @inbox_use == :current
          raise "#{self.class}: inbox.current can be used only once (X holds only one received value)"
        end
        if @inbox_use && @inbox_use != kind
          names = { current: "inbox.current", take: "inbox.take / inbox.each_bit", next: "inbox.next" }
          raise "#{self.class}: #{names[@inbox_use]} and #{names[kind]} cannot be used together (both use the OSR)"
        end
        @inbox_use = kind
      end

      # ---- emitting instructions ----
      def emit(word, delay = 0, reps = 1, self_loop = false, per_n = 0, user = false)
        raise "#{self.class}: no instructions allowed after loop (unreachable)" if @loop_state == :after
        raise "#{self.class}: more than #{MAX_INSTRUCTIONS} instructions" if @words.size >= MAX_INSTRUCTIONS
        @words << word
        @delay << delay
        @reps << reps
        @per_n << per_n
        @per_m << 0
        @loops << self_loop
        @user << user
        @side_mask << 0
        @side_val << 0
        @set_mask << 0
        @set_val << 0
        attach_deferred_side(@words.size - 1) unless @dside_label.nil?
      end

      # instruction for a user statement. Turns the preceding sleep into instructions here. A side-set change written
      # just before rides on this instruction
      def emit_user(word, label, output = false)
        full = if @pside_label.nil? then label
               elsif label.empty? then @pside_label                 # the nop a side-set change gets for itself
               else "#{@pside_label} + #{label}"
               end
        resolve(0, full)
        at = @words.size
        emit(word, 0, 1, false, 0, true)
        attach_side(at) unless @pside_label.nil?
        add_output(at, label) if output
        @since = 1
        @last_label = full
        @last_user_at = at
      end

      # a statement that waits (wait, irq wait): its time is when the wait ends
      def emit_wait(word, label)
        emit_user(word, label)
        @stalls << @words.size - 1
        @notes << [@last_label, "", "waits, no upper bound (times after it count from when it ends)"]
      end

      def add_output(at, label)
        if !@outputs.empty? && @outputs[-1][0] == at
          @outputs[-1] = [at, "#{@outputs[-1][1]} + #{label}"]
        else
          @outputs << [at, label]
        end
      end

      # ---- side-set ----
      # A side-set change happens at the start of an instruction and takes none of its own. It rides on the next
      # statement's instruction (on a wait, it acts when the wait begins, and the pin holds it while the SM stalls);
      # when a sleep follows it (or the loop ends), it rides on the previous statement's instruction if no sleep came in
      # between and that is not a wait, and otherwise gets a nop. Before its first change in the loop, a pin
      # holds the level it has at the end of the loop (also while the SM stalls at the loop head)
      def side_change(index, value, label)
        raise "#{self.class}: no instructions allowed after loop (unreachable)" if @loop_state == :after
        raise "#{self.class}: #{label}: the pin already changes at this point" if ((@pside_mask >> index) & 1) == 1
        @pside_mask |= 1 << index
        @pside_val |= value << index
        @pside_label = @pside_label.nil? ? label : "#{@pside_label} + #{label}"
      end

      def attach_side(at)
        @side_mask[at] |= @pside_mask
        @side_val[at] |= @pside_val
        add_output(at, @pside_label)
        @pside_mask = 0
        @pside_val = 0
        @pside_label = nil
      end

      # place a pending side-set change before a sleep, the end of a loop or each_bit
      # before_sleep: a sleep follows. Then a change that cannot ride on the previous instruction starts the sleep's
      # segment: it rides on the first instruction the sleep makes (a branch, a nop, set y) instead of getting a nop
      def flush_side(before_sleep = false)
        return if @pside_label.nil?
        at = @words.size - 1
        # not onto a wait: side-set acts when the instruction starts, and a wait's time is when it ends
        if @pending.nil? && at >= 0 && at == @last_user_at && !@nomerge[@words.size] && (@side_mask[at] & @pside_mask) == 0 &&
           !@stalls.include?(at)
          label = @pside_label
          attach_side(at)
          @last_label = "#{@last_label} + #{label}"
        elsif before_sleep
          label = @pside_label
          resolve(0, label)                 # place an earlier sleep first: the change comes after it
          @dside_mask = @pside_mask
          @dside_val = @pside_val
          @dside_label = label
          @pside_mask = 0
          @pside_val = 0
          @pside_label = nil
          @nomerge[@words.size] = true      # the sleep must start a new instruction here (not lengthen the previous one)
          @since = 0
          @last_label = label
        else
          emit_user(PIO.nop, "")
        end
      end

      # the first instruction after a deferred side-set change carries it
      def attach_deferred_side(at)
        @side_mask[at] |= @dside_mask
        @side_val[at] |= @dside_val
        add_output(at, @dside_label)
        @user[at] = true                    # a statement happens here (the head of a loop is measured to it)
        @dside_label = nil
      end

      def check_deferred_side
        return if @dside_label.nil?
        raise "#{self.class}: #{@dside_label}: no instruction starts at this point (the sleep after it is used up by the " \
              "instructions that follow); lengthen the sleep or move the change"
      end

      # ---- SET pins ----
      # set pins writes every SET pin, so each set pins instruction carries the levels the other pins have at that point
      # (followed through the program as for side-set). A change right after another statement's set pins, with no
      # sleep in between, joins that instruction: the pins change together
      def set_change(index, value, label)
        at = @words.size - 1
        if @pending.nil? && @pside_label.nil? && @dside_label.nil? && at >= 0 && at == @last_user_at && !@nomerge[@words.size] &&
           @set_mask[at] != 0 && (@set_mask[at] & (1 << index)) == 0
          @set_mask[at] |= 1 << index
          @set_val[at] |= value << index
          add_output(at, label)
          @last_label = "#{@last_label} + #{label}"
          return
        end
        emit_user(PIO.set(DEST_PINS, 0), label, true)
        @set_mask[@words.size - 1] = 1 << index
        @set_val[@words.size - 1] = value << index
      end

      # levels of each instruction for pins changed through masks / vals (see side_change: before its first change in the
      # loop, a pin holds the level it has at the end of the loop)
      # The levels at the end of the loop do not depend on the guess for the start, except for pins no instruction changes
      # (they stay 0): the second pass starts from what the first ends with. A branch's second path starts from the levels
      # after the branch instruction. Where the paths end with different levels, the pin's level is unknown until it is
      # changed again, and no instruction that drives it may run before that: for side-set (drives_all) any instruction,
      # for SET pins a set pins that does not change it
      def levels(masks, vals, count, drives_all, kind)
        first = levels_from(0, 0, masks, vals)
        st = first[0].empty? ? 0 : first[0][-1]
        unk = first[2]
        out, unks = levels_from(st, @loop_state == :after ? unk : 0, masks, vals)
        unks.each_with_index do |u, i|
          next if u == 0 || !(drives_all || masks[i] != 0)
          k = (0...count).find { |b| ((u >> b) & 1) == 1 }
          raise "#{self.class}: #{kind} pin #{k} (in the order declared) is left at different levels by the two paths of a branch, " \
                "and instruction #{i} drives it before it is changed again; set it at the end of both paths or right after the branch"
        end
        out
      end

      def levels_from(start, start_unk, masks, vals)
        state = start
        unk = 0
        out = []
        unks = []
        @words.size.times do |i|
          unk |= start_unk if i == @wrap_to             # unknown at the end of the loop: unknown again at its head
          if @path_resets.key?(i)
            state = out[@path_resets[i]]
            unk = unks[@path_resets[i]]
          end
          m = @path_merges.find { |pm| pm[2] == i }
          unk |= (out[m[0]] ^ out[m[1]]) | unks[m[0]] | unks[m[1]] unless m.nil?
          state = (state & ~masks[i]) | vals[i]
          unk &= ~masks[i]
          out << state
          unks << unk
        end
        m = @path_merges.find { |pm| pm[2] == @words.size }       # a branch at the end of the loop: unknown at its head
        unk |= (out[m[0]] ^ out[m[1]]) | unks[m[0]] | unks[m[1]] unless m.nil?
        [out, unks, unk]
      end

      def side_levels = levels(@side_mask, @side_val, side_count, true, "side-set")

      def new_label
        @label_count += 1
        :"_l#{@label_count}"
      end

      def place_label(name)
        @labels[name] = @words.size
        @nomerge[@words.size] = true
      end

      def emit_jump(cond, label, delay = 0)
        @fixups[@words.size] = label
        emit(PIO.jmp(cond, 0), delay)
      end

      # ---- sleep ----
      # sleep: makes the time from the start of the previous statement's instruction to the start of the next one this long.
      # Consecutive sleeps are added together. Waiting on a received value n gives n + (instruction overhead)
      # Length is kept as q (= seconds x clock x 10^9, integer). Cycles = q / 10^9. Rounding is done after the segment is collected
      def sleep(t, within: nil)
        flush_side(true)
        raise "#{self.class}: sleep cannot come before the first instruction (no instruction to count from)" if @words.empty? && @dside_label.nil?
        if @repeat_at == @words.size && @dside_label.nil?
          raise "#{self.class}: a repeat body cannot start with a sleep (no statement to count from in the first pass)"
        end
        if t.is_a?(Received)
          raise "#{self.class}: cannot sleep for a received value inside each_bit (Y is used for bits)" if @in_bits
          raise "#{self.class}: cannot sleep for a received value inside a repeat that counts in Y" if @y_counts > 0
          resolve(0, "sleep(received value)")
          @recv_movs << @words.size
          emit(PIO.mov(DEST_Y, t.src == :isr ? SRC_ISR : SRC_X))
          # jump to itself: with y = n it executes n+1 times. 1 time counted in reps, the remaining n in per_n (per_m)
          if t.src == :isr
            emit(PIO.jmp(JMP_Y_DEC, @words.size), 0, 1, true, 0)
            @per_m[-1] = 1
          else
            emit(PIO.jmp(JMP_Y_DEC, @words.size), 0, 1, true, 1)
          end
          @since = 0
          return
        end
        if t.is_a?(Choice)
          raise "#{self.class}: bit.pick is allowed only inside each_bit" if t.pin < 0 && !@in_bits
          if t.pin >= 0
            claim_pin(t.pin)
            @pin_in_bits = true if @in_bits
          end
          one = to_q(t.one)
          zero = to_q(t.zero)
          base = @pending.is_a?(Array) ? nil : (@pending || 0)
          raise "#{self.class}: at most one pick per segment" if base.nil?
          @pending = [base + one, base + zero, t.pin]
          add_tolerance(within)
          return
        end
        c = to_q(t)
        raise "sleep length must be greater than 0" if c <= 0
        add_tolerance(within)
        if @pending.is_a?(Array)
          @pending = [@pending[0] + c, @pending[1] + c, @pending[2]]
        else
          @pending = (@pending || 0) + c
        end
      end

      def to_q(t)
        return t.n * NS_PER_SECOND if t.is_a?(Cycles)
        raise "#{self.class}: write lengths as e.g. 2.us or 100.cycles" unless t.is_a?(Duration)
        t.ns * clock_hz
      end

      # tolerance for a segment: the narrowest within: among its sleeps, or tolerance if none
      def add_tolerance(within)
        return if within.nil?
        q = to_q(within)
        raise "#{self.class}: within: must be 0 or more" if q < 0
        @pending_tol = @pending_tol.nil? || q < @pending_tol ? q : @pending_tol
      end

      def take_tolerance
        t = @pending_tol
        @pending_tol = nil
        return t unless t.nil?
        g = self.class.tolerance
        g.nil? ? 0 : to_q(g)
      end

      def q_ns(q) = q.to_f / clock_hz       # q to ns

      # round q to the nearest cycle count; stop if the deviation exceeds tol
      def round_q(q, tol, prev_label, next_label)
        c = (q + NS_PER_SECOND / 2) / NS_PER_SECOND
        dev = c * NS_PER_SECOND - q
        if dev.abs > tol
          msg = if tol == 0
                  "#{prev_label} → #{next_label}: #{fmt_ns(q_ns(q))} is not a whole number of cycles at #{clock_hz}Hz" \
                  " (nearest is #{c} cycles = #{fmt_ns(c * 1e9 / clock_hz)}; allow a deviation with tolerance or within:)"
                else
                  "#{prev_label} → #{next_label}: #{fmt_ns(q_ns(q))} at #{clock_hz}Hz is #{c} cycles = " \
                  "#{fmt_ns(c * 1e9 / clock_hz)}; deviation #{fmt_dev(q_ns(dev))} exceeds tolerance #{fmt_ns(q_ns(tol))}"
                end
          raise "#{self.class}: #{msg}"
        end
        raise "#{self.class}: #{prev_label} → #{next_label}: becomes 0 cycles (sleep must be at least 1 cycle)" if c < 1
        @rounded << [prev_label, next_label, q, c, tol] if dev != 0
        c
      end

      def fmt_ns(x)
        r = x.round(1)
        r == r.round ? "#{r.round}ns" : "#{r}ns"
      end

      def fmt_dev(x) = (x >= 0 ? "+" : "−") + fmt_ns(x.abs)

      # cycles with ns (used to describe segments with branches)
      def cyc_ns(c) = "#{c} (#{fmt_ns(c * 1e9 / clock_hz)})"

      # turn the pending sleep into instructions. tail = builder instructions after this before the next statement's instruction
      def resolve(tail, next_label)
        p = @pending
        return if p.nil?
        @pending = nil
        tol = take_tolerance
        if p.is_a?(Integer)
          if p == 0 && @zero_ok                       # carried past a branch: nothing more to wait
            @zero_ok = false
            pad(-@since - tail, next_label)
            @notes << [@last_label, next_label, "0"]
            return 0
          end
          @zero_ok = false
          c = round_q(p, tol, @last_label, next_label)
          pad(c - @since - tail, next_label)
          @notes << [@last_label, next_label, cyc_ns(c)]
          add_bit_note(c)
          return c
        end
        pin = p[2]
        hi = pin < 0 ? "bit 1" : "#{self.class.inputs[pin]} high"
        lo = pin < 0 ? "bit 0" : "#{self.class.inputs[pin]} low"
        one = round_q(p[0], tol, @last_label, "#{next_label} (#{hi})")
        zero = round_q(p[1], tol, @last_label, "#{next_label} (#{lo})")
        @bit_notes << (@path_bit == 1 ? [one, 0] : (@path_bit == 2 ? [0, zero] : [one, zero])) if @in_bits
        via_y = pin >= 0 && pin != @jmp_pin
        if pin < 0
          load_bit
          @notes << [@last_label, next_label, "#{cyc_ns(one)} if bit is 1, #{cyc_ns(zero)} if 0"]
        else
          read = @since                     # the branch (or the mov osr, pins before it) is the first instruction of the wait
          load_pin(pin) if via_y
          @notes << [@last_label, next_label, "#{cyc_ns(one)} if #{hi.sub(' high', '')} is high, #{cyc_ns(zero)} if low " \
                                              "(read #{read} cycle#{read == 1 ? '' : 's'} after #{@last_label})"]
        end
        # the branch jumps on bit 0 (jmp !y) or on a high pin (jmp pin): "taken" is that case, "fall" the other
        on_y = pin < 0 || via_y
        cond = on_y ? JMP_NOT_Y : JMP_PIN
        t_len = on_y ? zero : one
        f_len = on_y ? one : zero
        t_name = on_y ? lo : hi
        f_name = on_y ? hi : lo
        et = t_len - @since - tail
        ef = f_len - @since - tail
        if et == ef
          pad(et, next_label)
          return nil
        end
        @branchy = true
        merge = new_label
        if pin >= 0 && (et < ef ? et - 1 : ef - 2) > max_delay
          # long waits on a pin: branch first, so the pin is read when the wait begins, and wait on each path
          raise "#{self.class}: #{next_label} is preceded by too short a wait for #{f_name} (needs #{2 - ef} more cycles)" if ef < 2
          taken = new_label
          emit_jump(cond, taken)
          fill_wait(ef - 2)
          emit_jump(JMP_ALWAYS, merge)
          place_label(taken)
          fill_wait(et - 1)
          place_label(merge)
          @since = f_len - tail
          return nil
        end
        if et < ef
          # the taken case is shorter: jump to the merge point. The other falls through and nops add the length
          raise "#{self.class}: #{next_label} is preceded by too short a wait for #{t_name} (needs #{1 - et} more cycles)" if et < 1
          c = et - 1
          pre = c > max_delay ? c - max_delay : 0
          pad(pre, next_label) if pre > 0
          emit_jump(cond, merge, c - pre)
          fill_wait(ef - et)
        else
          # the fall-through case is shorter: the taken case jumps to the longer path, the other jumps to the merge point
          raise "#{self.class}: #{next_label} is preceded by too short a wait for #{f_name} (needs #{2 - ef} more cycles)" if ef < 2
          c = ef - 2
          pre = c > max_delay ? c - max_delay : 0
          pad(pre, next_label) if pre > 0
          longer = new_label
          emit_jump(cond, longer, c - pre)
          emit_jump(JMP_ALWAYS, merge)
          place_label(longer)
          fill_wait(et - pre - (1 + c - pre))
        end
        place_label(merge)
        # elapsed time at the merge point differs per path. After this only builder instructions (tail) and the next
        # statement's instruction follow, and counting restarts at that statement, so the fall-through value is stored
        @since = f_len - tail
        nil
      end

      # add extra cycles at the current position: try the previous instruction's delay, a nop, then set y + jmp y--
      def pad(extra, next_label)
        raise "#{self.class}: #{next_label} is preceded by too short a sleep (instructions in between already take #{-extra} cycles more)" if extra < 0
        return if extra == 0
        last = @words.size - 1
        if last >= 0 && !@loops[last] && !@nomerge[@words.size] && !jump?(last) && @delay[last] + extra <= max_delay
          @delay[last] += extra
        elsif extra <= max_delay + 1
          emit(PIO.nop, extra - 1)
        elsif (@in_bits && @bit_loaded) || @y_counts > 0
          fill(extra)                                  # Y holds the bit or a repeat's count, so set y can't be used
        else
          long_wait(extra)
        end
        @since += extra
      end

      def jump?(i) = (@words[i] & 0xE000) == OP_JMP && @fixups.key?(i)

      # k cycles of consecutive nops (where no delay can be added to the previous instruction, e.g. after a branch)
      def fill(k)
        while k > 0
          d = k > max_delay + 1 ? max_delay + 1 : k
          emit(PIO.nop, d - 1)
          k -= d
        end
      end

      # k cycles after a branch (no delay can go on the instruction before): set y + jmp y-- when Y is free, else nops
      def fill_wait(k)
        if k > max_delay + 1 && !(@in_bits && @bit_loaded) && @y_counts == 0
          long_wait(k)
        else
          fill(k)
        end
      end

      # wait extra cycles with set y, k [a] and jmp y-- [d]: (1+a) + (k+1)(1+d) = extra. Longer waits chain several
      def long_wait(extra)
        limit = (1 + max_delay) + (MAX_SET_DATA + 1) * (1 + max_delay)
        while extra > limit
          chunk = extra - limit >= 2 ? limit : extra - 2     # leave at least 2 for the last pair
          long_wait1(chunk)
          extra -= chunk
        end
        long_wait1(extra)
      end

      def long_wait1(extra)
        (0..max_delay).each do |a|
          (0..MAX_SET_DATA).each do |k|
            (0..max_delay).each do |d|
              next unless (1 + a) + (k + 1) * (1 + d) == extra
              emit(PIO.set(DEST_Y, k), a)
              emit(PIO.jmp(JMP_Y_DEC, @words.size), d, k + 1, true)
              return
            end
          end
        end
        raise "#{extra} cycles is too long (slow the PIO with clkdiv or pass it via inbox)"
      end

      # ---- inputs to branch on ----
      # The first input a program picks or branches on becomes the JMP pin (jmp pin). Any other input is read into Y:
      # mov osr, pins; out null, k (for input k > 0); out y, 1; then jmp !y. That uses the OSR (shifting right, the
      # state machine's default) and Y, so it does not go with inbox, each_bit or a repeat that counts in Y
      def claim_pin(pin)
        if @jmp_pin < 0
          @jmp_pin = pin
        elsif @jmp_pin != pin
          name = self.class.inputs[pin]
          raise "#{self.class}: #{name}: a second input to branch on is read through the OSR, which inbox uses" unless @inbox_use.nil?
          raise "#{self.class}: #{name}: a second input to branch on is read into Y, which each_bit uses for the bit" if @in_bits
          raise "#{self.class}: #{name}: a second input to branch on is read into Y, which this repeat counts in" if @y_counts > 0
          @osr_pins = true
        end
      end

      def pin_load_cycles(pin) = pin == 0 ? 2 : 3

      def load_pin(pin)
        emit(PIO.mov(DEST_OSR, SRC_PINS))
        emit(PIO.out(DEST_NULL, pin)) if pin > 0
        emit(PIO.out(DEST_Y, 1))
        @since += pin_load_cycles(pin)
      end

      # ---- each_bit ----
      def load_bit
        return if @bit_loaded
        raise "#{self.class}: bit is allowed only inside each_bit" unless @in_bits
        emit(PIO.out(DEST_Y, 1))
        @since += 1
        @bit_loaded = true
      end

      def bit_loop(n, order, stream)
        raise "#{self.class}: only one each_bit per program (one OSR threshold per state machine)" if @bits_used
        raise "#{self.class}: each_bit inside a repeat that counts in Y (a repeat inside a repeat)" if @y_counts > 0
        if stream
          raise "#{self.class}: inbox.each_bit is allowed only inside loop" unless @loop_state == :inside
          raise "#{self.class}: inbox.each_bit must come first in loop (words stream without breaks, so no statement may precede it)" if @words.size != @wrap_to
          @autopull = true
          @stream_at = @words.size
        end
        raise "#{self.class}: each_bit bit count must be 1..32" unless n.between?(1, 32)
        raise "#{self.class}: order must be :msb or :lsb" unless order == :msb || order == :lsb
        @bits_used = true
        @out_shift_right = order == :lsb
        @pull_threshold = n
        flush_side
        resolve(0, "each_bit")
        start = new_label
        place_label(start)
        start_at = @words.size
        @in_bits = true
        @bit_loaded = false
        load_bit if stream                  # load the bit at the head of the iteration (stalls here if the FIFO is empty; the pin keeps the previous iteration's last state)
        yield Bit.new(self)
        raise "#{self.class}: bit is not used inside each_bit (the OSR never advances, so it cannot exit)" unless @bit_loaded
        raise "#{self.class}: no statements inside each_bit" if (start_at...@words.size).none? { |i| @user[i] }
        flush_side
        head = head_cycles(start_at)        # builder instructions at the head of the iteration before the first statement
        if stream
          resolve(head, "next bit")         # wrap returns to the head (no instruction needed)
          check_deferred_side
          @stream_end = @words.size
        else
          resolve(1 + head, "next bit")
          check_deferred_side
          emit_jump(JMP_NOT_OSRE, start)
          @since += 1
          @bits_in_repeat = @repeat_depth > 0
          @word_end_at = @words.size          # after the word's last bit, execution goes from here to the head of the next word
          @bits_start_at = start_at
        end
        @in_bits = false
        @bit_loaded = false
      end

      # ---- loop ----
      # Only one loop. Instructions before it run once as initialization; the loop body repeats via wrap
      def loop
        raise "#{self.class}: only one loop allowed (no nesting)" unless @loop_state == :before
        flush_side
        @loop_state = :inside
        @wrap_to = @words.size
        @nomerge[@words.size] = true
        yield
        flush_side
        raise "#{self.class}: no instructions inside loop" if @words.size == @wrap_to
        if @stream_at && @stream_end != @words.size
          raise "#{self.class}: no statements allowed after inbox.each_bit (words stream without breaks, so it must be the whole loop body)"
        end
        head = (@wrap_to...@words.size).any? { |i| @user[i] } ? head_cycles(@wrap_to) : 0
        resolve(head, "loop head")
        check_deferred_side
        raise "#{self.class}: no instructions inside loop" if @words.size == @wrap_to
        @wrap_from = @words.size - 1
        @loop_state = :after
      end

      def encoded
        s = side_count
        sides = s > 0 ? side_levels : []
        sets = levels(@set_mask, @set_val, self.class.set_outputs.size, false, "SET")
        @words.each_with_index.map do |w, i|
          w | (@set_mask[i] != 0 ? sets[i] : 0) | (@delay[i] << DELAY_SHIFT) | (s > 0 ? sides[i] << (13 - s) : 0)
        end
      end

      # cycles of instruction i per iteration [coefficient of n, constant]
      def cost(i) = [@per_n[i] * (1 + @delay[i]), @reps[i] * (1 + @delay[i]), @per_m[i] * (1 + @delay[i])]

      # cycles per iteration (loop body only) [coefficient of n, constant]. Only without branches
      def cycles
        raise "#{self.class}: loop period is not fixed because of branches or waits (see the report segments or use sim)" unless fixed?
        pn = 0
        fx = 0
        pm = 0
        (@wrap_to..@wrap_from).each do |i|
          a, b, m = cost(i)
          pn += a
          fx += b
          pm += m
        end
        pm == 0 ? [pn, fx] : [pn, fx, pm]          # m only with inbox.preset
      end

      # segments from one pin-changing instruction to the next (counted going once around the loop). Only without branches
      # returns [label, next label, coefficient of n, constant, instruction positions in the segment, coefficient of m]
      def phases
        outs = @outputs.select { |o| o[0] >= @wrap_to && o[0] <= @wrap_from }
        len = @wrap_from - @wrap_to + 1
        result = []
        outs.each_with_index do |o, k|
          nxt = outs[(k + 1) % outs.size]
          steps = (nxt[0] - o[0]) % len
          steps = len if steps == 0
          pn = 0
          fx = 0
          pm = 0
          idx = []
          steps.times do |s|
            i = @wrap_to + (o[0] - @wrap_to + s) % len
            a, b, m = cost(i)
            pn += a
            fx += b
            pm += m
            idx << i
          end
          result << [o[1], nxt[1], pn, fx, idx, pm]
        end
        result
      end

      # make segments that wait on the same received value equal in length: add delay to the shorter segment's mov y, x
      # (prevents only the segment containing inbox.current's 2 instructions from being longer, which would skew a square wave's High and Low)
      def balance
        return unless fixed?
        if phases.any? { |ph| ph[5] > 0 }
          # with inbox.preset: align the segments that wait on the same values the same number of times
          groups = {}
          phases.select { |ph| ph[2] > 0 || ph[5] > 0 }.each do |ph|
            k = "#{ph[2]},#{ph[5]}"
            groups[k] = [] unless groups.key?(k)
            groups[k] << ph
          end
          groups.each_value { |g| align(g) if g.size >= 2 }
          return
        end
        timed = phases.select { |ph| ph[2] > 0 }
        return if timed.size < 2
        if timed.map { |ph| ph[2] }.uniq.size > 1
          raise "#{self.class}: cannot align: the coefficient of n differs between segments"
        end
        align(timed)
      end

      def align(timed)
        target = timed.map { |ph| ph[3] }.max
        timed.each do |ph|
          pad = target - ph[3]
          next if pad == 0
          mv = ph[4].find { |i| @recv_movs.include?(i) }
          raise "#{self.class}: delay needed for alignment exceeds #{max_delay}" if @delay[mv] + pad > max_delay
          @delay[mv] += pad
        end
      end

      def finish
        raise "#{self.class}: no loop (wrap point is undefined)" unless @loop_state == :after
        @fixups.each do |i, name|
          addr = @labels[name]
          addr = @wrap_to if addr == @words.size      # a label at the last position goes to the loop head (same as wrap)
          @words[i] |= addr
        end
        balance
        self
      end

      def self.assemble
        prog = new
        prog.main
        prog.finish
      end

      # C name: Board::Tick -> board_tick
      def name
        s = self.class.to_s.split("::").map { |part| part.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase }.join("_")
        raise "#{self.class}: cannot make a C name from #{s}" unless s.match?(/\A[a-z_][a-z0-9_]*\z/)
        s
      end

      # produce the same artifact as the instruction layer (what PIO.asm returns), including OSR settings
      def assembled
        a = PIO::Assembled.new(name, encoded, @wrap_to, @wrap_from, -1, 0, side_count, false, false, [], [])
        a.out_shift_right = @out_shift_right
        a.pull_threshold = @pull_threshold
        a.autopull = @autopull
        a.in_shift_right = @in_shift_right
        a.push_threshold = @push_threshold
        a.autopush = @autopush
        a.set_count = self.class.set_outputs.size
        a.out_count = self.class.out_width
        a.in_count = self.class.inputs.size
        a.jmp_input = @jmp_pin
        a.clock_hz = clock_hz
        a
      end

      # n: inbox.current, m: inbox.preset
      def expr(pn, fx, pm = 0)
        t = +""
        t << "#{pn == 1 ? '' : pn}n + " if pn > 0
        t << "#{pm == 1 ? '' : pm}m + " if pm > 0
        "#{t}#{fx}"
      end

      # for per-word each_bit: cycles of instructions run after the word's last bit (next inbox.take etc.)
      def word_gap
        return nil unless @word_end_at
        return nil if @bits_in_repeat
        after = (@word_end_at..@wrap_from).sum { |i| 1 + @delay[i] }
        head = (@wrap_to...@bits_start_at).sum { |i| 1 + @delay[i] }
        after + head
      end

      def timing_lines
        unless fixed?
          lines = @notes.map { |n| n[1].empty? ? "#{n[0]}: #{n[2]}" : "#{n[0]} → #{n[1]}: #{n[2]}" }
          if !@bit_notes.empty? && !@pin_in_bits && !@repeat_in_bits
            b1 = @bit_notes.sum { |n| n[0] }
            b0 = @bit_notes.sum { |n| n[1] }
            lines << "1 bit: #{cyc_ns(b1)} if 1, #{cyc_ns(b0)} if 0"
          end
          g = word_gap
          lines << "+#{g} after the last bit of a word (next word's inbox.take etc.; longer while waiting for a word)" if g && g > 0
          lines
        else
          phases.map { |ph| "#{ph[0]} → #{ph[1]}: #{expr(ph[2], ph[3], ph[5])}" }
        end
      end

      # rounded segments: written length -> cycles and actual length, deviation, tolerance
      def rounding_lines
        @rounded.map do |r|
          actual = r[3] * 1e9 / clock_hz
          "rounded #{r[0]} → #{r[1]}: #{fmt_ns(q_ns(r[2]))} → #{r[3]} cycles = #{fmt_ns(actual)} " \
            "(#{fmt_dev(actual - q_ns(r[2]))}, tolerance #{fmt_ns(q_ns(r[4]))})"
        end
      end

      # <name>_program_init in the style of pico-examples: pins of each role the program declares, the GPIO functions and
      # pin directions of its outputs, and the clkdiv for its PIO clock. Leaves the SM stopped
      def init_c
        a = assembled
        n = name
        args = []
        args << "uint set_base" if a.set_count > 0
        args << "uint sideset_base" if a.side_set_count > 0
        args << "uint out_base" if a.out_count > 0
        args << "uint in_base" if a.in_count > 0
        s = +"\n#if !PICO_NO_HARDWARE\n#include \"hardware/clocks.h\"\n\n"
        s << "#define #{n}_clock_hz #{clock_hz}\n\n"
        s << "static inline void #{n}_program_init(#{(['PIO pio', 'uint sm', 'uint offset'] + args).join(', ')}) {\n"
        s << "    pio_sm_config c = #{n}_program_get_default_config(offset);\n"
        [["set_base", a.set_count, "sm_config_set_set_pins(&c, set_base, #{a.set_count});"],
         ["sideset_base", a.side_set_count, "sm_config_set_sideset_pins(&c, sideset_base);"],
         ["out_base", a.out_count, "sm_config_set_out_pins(&c, out_base, #{a.out_count});"]].each do |base, count, cfg|
          next if count == 0
          s << "    #{cfg}\n"
          s << "    for (uint i = 0; i < #{count}; i++) pio_gpio_init(pio, #{base} + i);\n"
          s << "    pio_sm_set_consecutive_pindirs(pio, sm, #{base}, #{count}, true);\n"
        end
        s << "    sm_config_set_in_pins(&c, in_base);\n" if a.in_count > 0
        s << "    sm_config_set_jmp_pin(&c, in_base + #{a.jmp_input});\n" if a.jmp_input >= 0
        s << "    sm_config_set_clkdiv(&c, (float)clock_get_hz(clk_sys) / #{n}_clock_hz);\n"
        s << "    pio_sm_init(pio, sm, offset, &c);\n"
        s << "}\n"
        if @isr_use == :preset
          s << "\n// inbox.preset: put the value in the ISR while the state machine is stopped and its TX FIFO is empty\n"
          s << "static inline void #{n}_load_preset(PIO pio, uint sm, uint32_t value) {\n"
          s << "    pio_sm_put_blocking(pio, sm, value);\n"
          s << "    pio_sm_exec(pio, sm, pio_encode_pull(false, false));\n"
          s << "    pio_sm_exec(pio, sm, pio_encode_out(pio_isr, 32));\n"
          s << "}\n"
        end
        s << "#endif\n"
        s
      end

      def pin_roles
        r = []
        sets = self.class.set_outputs
        r << "SET pins from the base: #{sets.join(', ')}" unless sets.empty?
        sides = self.class.side_outputs
        r << "side-set pins from the base: #{sides.join(', ')}" unless sides.empty?
        outs = self.class.out_outputs
        r << "OUT pin: #{outs[0]}" unless outs.empty?
        ins = self.class.inputs
        r << "IN pins from the base: #{ins.join(', ')}" unless ins.empty?
        r << "JMP pin: #{ins[@jmp_pin]}" if @jmp_pin >= 0
        r.empty? ? "no pins" : r.join("; ")
      end

      def report
        puts "#{self.class}: #{@words.size} instructions / #{MAX_INSTRUCTIONS}"
        if fixed?
          puts "loop period = #{expr(*cycles)} cycles"
        end
        timing_lines.each { |l| puts "  #{l}" }
        rounding_lines.each { |l| puts "  #{l}" }
        puts "wrap #{@wrap_from} -> #{@wrap_to}"
        puts encoded.map { |w| format("0x%04X", w) }.join(" ")
      end

      def to_c
        per = fixed? ? ", loop period #{expr(*cycles)} cycles" : ""
        s = +"// #{self.class}: #{@words.size} instructions#{per} (computed for PIO at #{clock_hz}Hz)\n"
        timing_lines.each { |l| s << "//   #{l}\n" }
        rounding_lines.each { |l| s << "//   #{l}\n" }
        s << "// #{pin_roles}\n"
        s << assembled.to_c
        s << init_c
        s
      end
    end
  end
end

class Integer
  def cycles = Pico::PIO::Cycles.new(self)
  def us = Pico::PIO::Duration.new(self * 1000)
  def ns = Pico::PIO::Duration.new(self)
end
