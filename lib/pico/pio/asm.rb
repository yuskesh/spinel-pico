# Instruction layer: write PIO instructions one at a time. Names follow pioasm and pico-sdk (pio_instructions.h)
#
#   code = Pico::PIO.asm(:ws2812, side_set: 1) do
#     t1 = define(:T1, 3, public: true)
#     wrap_target
#     label :bitloop
#     out :x, 1, side: 0, delay: 3
#     jmp :not_x, :do_zero, side: 1, delay: 2
#     ...
#     wrap
#   end
#   code.instructions  # => [0x6321, ...]
#   puts code.to_c     # header in the same form as pioasm's c-sdk output
module Pico
  module PIO
    INSTRUCTION_MEMORY = 32

    # jmp conditions (pio_encode_jmp_<name>)
    JMP_CONDITIONS = { always: 0, not_x: 1, x_dec: 2, not_y: 3, y_dec: 4, x_ne_y: 5, pin: 6, not_osre: 7 }

    # Destinations and sources. Which ones are allowed differs per instruction (datasheet 3.4)
    IN_SOURCES   = { pins: 0, x: 1, y: 2, null: 3, isr: 6, osr: 7 }
    OUT_DESTS    = { pins: 0, x: 1, y: 2, null: 3, pindirs: 4, pc: 5, isr: 6, exec: 7 }
    MOV_DESTS    = { pins: 0, x: 1, y: 2, exec: 4, pc: 5, isr: 6, osr: 7 }
    MOV_DESTS_V1 = { pindirs: 3 }
    MOV_SOURCES  = { pins: 0, x: 1, y: 2, null: 3, status: 5, isr: 6, osr: 7 }
    MOV_OPS      = { none: 0, invert: 1, reverse: 2 }
    SET_DESTS    = { pins: 0, x: 1, y: 2, pindirs: 4 }
    WAIT_SOURCES = { gpio: 0, pin: 1, irq: 2 }
    WAIT_SOURCES_V1 = { jmppin: 3 }
    IRQ_MODES    = { set: 0, nowait: 0, wait: 1, clear: 2 }
    # pio_version 1 (RP2350): the flag of the previous / next PIO block (bits 4:3 of the index; rel is 0x10)
    IRQ_BLOCKS   = { prev: 0x08, next: 0x18 }
    # pio_version 1: what the RX FIFO's four registers are used for (.fifo; pico-sdk's PIO_FIFO_JOIN_*)
    FIFO_MODES   = { txrx: "NONE", tx: "TX", rx: "RX", txput: "TXPUT", txget: "TXGET", putget: "PUTGET" }

    # rxfifo(:y) / rxfifo(0..3): one of the RX FIFO's registers, for mov (pio_version 1)
    class RxFifoEntry
      attr_reader :index
      def initialize(index) = @index = index
      def code = @index == :y ? 0 : 0x08 | @index
    end

    class AsmError < StandardError; end

    # Assembled result: instruction words plus the values needed to configure the state machine
    class Assembled
      attr_reader :name, :instructions, :wrap_target, :wrap, :origin, :pio_version,
                  :side_set_count, :side_set_opt, :side_set_pindirs, :defines, :public_labels
      # OSR settings (decided by each_bit in the time layer). nil leaves the state machine default
      attr_accessor :out_shift_right, :pull_threshold, :autopull
      # ISR settings (decided by outbox.autopush in the time layer). nil leaves the state machine default
      attr_accessor :in_shift_right, :push_threshold, :autopush
      # pin roles from the time layer: SET / OUT / IN pin counts and the input used as the JMP pin (-1: none). The
      # instruction layer leaves them 0 / -1 (the caller sets the pins)
      attr_accessor :set_count, :out_count, :in_count, :jmp_input
      # PIO clock (Hz) when written in the time layer. nil for the instruction layer
      attr_accessor :clock_hz
      # .fifo: :txrx (default), :tx, :rx, and with pio_version 1 :txput, :txget, :putget
      attr_accessor :fifo
      # from the .in / .out / .set / .mov_status / .clock_div directives (nil when not given): [pin count, shift right,
      # auto, threshold], the SET pin count, [STATUS_* name, n], [int, frac]
      attr_accessor :in_decl, :out_decl, :set_decl, :mov_status, :clock_div

      def initialize(name, instructions, wrap_target, wrap, origin, pio_version,
                     side_set_count, side_set_opt, side_set_pindirs, defines, public_labels)
        @name = name
        @instructions = instructions
        @wrap_target = wrap_target
        @wrap = wrap
        @origin = origin
        @pio_version = pio_version
        @side_set_count = side_set_count
        @side_set_opt = side_set_opt
        @side_set_pindirs = side_set_pindirs
        @defines = defines
        @public_labels = public_labels
        @set_count = 0
        @out_count = 0
        @in_count = 0
        @jmp_input = -1
        @fifo = :txrx
      end

      def length = @instructions.size

      # Side-set bit count for the state machine (includes the opt bit; 2nd argument of sm_config_set_sideset)
      def side_set_bits = @side_set_count + (@side_set_opt ? 1 : 0)

      # Emit Ruby for the on-device runtime layer (PIO::Program in lib/pico/pio/program.rb).
      # Assembly is done on the host and only the resulting numbers go to the microcontroller (bare-full Integer is 32-bit,
      # so ns x Hz arithmetic cannot be done on the device)
      def to_ruby(const)
        raise "constant name #{const} must start with an uppercase letter" unless const.match?(/\A[A-Z][A-Z0-9_]*\z/)
        b = ->(v) { v ? "true" : "false" }
        n = ->(v) { v.nil? ? "nil" : v.to_s }
        words = @instructions.each_slice(8).map { |sl| "    " + sl.map { |w| format("0x%04x", w) }.join(", ") }.join(",\n")
        s = +"#{const} = Pico::PIO::Program.new(\n"
        s << "  #{@name.to_s.inspect},\n"
        s << "  [\n#{words}\n  ],\n"
        rows = [["#{@origin}, #{@wrap_target}, #{@wrap},", "origin, wrap_target, wrap"],
                ["#{@side_set_count}, #{b.(@side_set_opt)}, #{b.(@side_set_pindirs)},", "side-set: bits, opt, pindirs"],
                ["#{n.(@out_shift_right)}, #{n.(@pull_threshold)}, #{b.(@autopull)},", "OSR: shift right, pull threshold, autopull"],
                ["#{n.(@in_shift_right)}, #{n.(@push_threshold)}, #{b.(@autopush)},", "ISR: shift right, push threshold, autopush"],
                ["#{@set_count}, #{@out_count}, #{@in_count}, #{@jmp_input},", "pins: SET, OUT, IN counts, JMP input"],
                ["#{n.(@clock_hz)}, #{@pio_version}#{@fifo == :txrx ? '' : ','}", "PIO clock (Hz), pio_version"]]
        ms = !@mov_status.nil?
        cd = !@clock_div.nil?
        rows[-1][0] += "," if @fifo == :txrx && (ms || cd)
        rows << [":#{@fifo}#{ms || cd ? ',' : ''}", "FIFO mode"] if @fifo != :txrx || ms || cd
        if ms || cd
          sel = ms ? { "STATUS_TX_LESSTHAN" => ":txfifo", "STATUS_RX_LESSTHAN" => ":rxfifo", "STATUS_IRQ_SET" => ":irq" }[@mov_status[0]] : ":none"
          rows << ["#{sel}, #{ms ? @mov_status[1] : 0}#{cd ? ',' : ''}", "mov_status: source, n"]
          rows << ["#{@clock_div[0]}, #{@clock_div[1]}", "clock_div: int, frac / 256"] if cd
        end
        w = rows.map { |r| r[0].size }.max
        rows.each { |r| s << "  #{r[0].ljust(w)}  # #{r[1]}\n" }
        s << ")\n"
        s
      end

      def to_hex = @instructions.map { |w| format("%04x", w) }.join("\n") + "\n"

      def to_c
        n = @name
        s = +""
        s << "#define #{n}_wrap_target #{@wrap_target}\n"
        s << "#define #{n}_wrap #{@wrap}\n"
        s << "#define #{n}_pio_version #{@pio_version}\n\n"
        @public_labels.each { |l| s << "#define #{n}_offset_#{l[0]} #{l[1]}u\n" }
        s << "\n" unless @public_labels.empty?
        @defines.each { |d| s << "#define #{n}_#{d[0]} #{d[1]}\n" }
        s << "\n" unless @defines.empty?
        s << "static const uint16_t #{n}_program_instructions[] = {\n"
        @instructions.each_with_index do |w, i|
          s << "            //     .wrap_target\n" if i == @wrap_target
          s << format("    0x%04x, // %2d\n", w, i)
          s << "            //     .wrap\n" if i == @wrap
        end
        s << "};\n\n"
        s << "static const struct pio_program #{n}_program = {\n"
        s << "    .instructions = #{n}_program_instructions,\n"
        s << "    .length = #{length},\n"
        s << "    .origin = #{@origin},\n"
        s << "    .pio_version = #{n}_pio_version,\n"
        s << "};\n\n"
        s << "static inline pio_sm_config #{n}_program_get_default_config(uint offset) {\n"
        s << "    pio_sm_config c = pio_get_default_sm_config();\n"
        s << "    sm_config_set_wrap(&c, offset + #{n}_wrap_target, offset + #{n}_wrap);\n"
        c01 = ->(v) { v ? 1 : 0 }
        unless @in_decl.nil?
          s << "    sm_config_set_in_pin_count(&c, #{@in_decl[0]});\n"
          s << "    sm_config_set_in_shift(&c, #{c01.(@in_decl[1])}, #{c01.(@in_decl[2])}, #{@in_decl[3]});\n"
        end
        unless @out_decl.nil?
          s << "    sm_config_set_out_pin_count(&c, #{@out_decl[0]});\n"
          s << "    sm_config_set_out_shift(&c, #{c01.(@out_decl[1])}, #{c01.(@out_decl[2])}, #{@out_decl[3]});\n"
        end
        s << "    sm_config_set_set_pin_count(&c, #{@set_decl});\n" unless @set_decl.nil?
        if @side_set_count > 0 || @side_set_opt
          s << "    sm_config_set_sideset(&c, #{side_set_bits}, #{@side_set_opt}, #{@side_set_pindirs});\n"
        end
        unless @pull_threshold.nil? || !@out_decl.nil?
          s << "    sm_config_set_out_shift(&c, #{@out_shift_right}, #{@autopull ? true : false}, #{@pull_threshold});\n"
        end
        unless @push_threshold.nil? || !@in_decl.nil?
          s << "    sm_config_set_in_shift(&c, #{@in_shift_right}, #{@autopush ? true : false}, #{@push_threshold});\n"
        end
        s << "    sm_config_set_mov_status(&c, #{@mov_status[0]}, #{@mov_status[1]});\n" unless @mov_status.nil?
        s << "    sm_config_set_fifo_join(&c, PIO_FIFO_JOIN_#{FIFO_MODES[@fifo]});\n" unless @fifo == :txrx
        s << "    sm_config_set_clkdiv_int_frac(&c, #{@clock_div[0]}, #{@clock_div[1]});\n" unless @clock_div.nil?
        s << "    return c;\n"
        s << "}\n"
        s
      end
    end

    # Inside the PIO.asm block (instance_eval)
    class Assembler
      def initialize(name, side_set, side_set_opt, side_set_pindirs, origin, pio_version, fifo = :txrx)
        raise AsmError, "fifo must be one of #{FIFO_MODES.keys.join(', ')}" unless FIFO_MODES.key?(fifo)
        if pio_version == 0 && (fifo == :txput || fifo == :txget || fifo == :putget)
          raise AsmError, "fifo: :#{fifo} requires pio_version: 1 (RP2350)"
        end
        @fifo = fifo
        raise AsmError, "side_set must be 0..5" unless side_set.between?(0, 5)
        raise AsmError, "side_set opt allows at most 4 bits" if side_set_opt && side_set > 4
        raise AsmError, "pio_version must be 0 (RP2040) or 1 (RP2350)" unless pio_version == 0 || pio_version == 1
        @name = name.to_s
        raise AsmError, "not a valid C identifier: #{@name}" unless @name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        @side_set = side_set
        @side_set_opt = side_set_opt
        @side_set_pindirs = side_set_pindirs
        @origin = origin
        @pio_version = pio_version
        @words = []                         # instruction words (without side/delay)
        @sides = []                         # side values (nil if none)
        @delays = []
        @targets = []                       # jmp targets (label name or number); nil if none
        @labels = {}
        @public_labels = []
        @defines = []
        @wrap_target = nil
        @wrap = nil
        @in_decl = nil
        @out_decl = nil
        @set_decl = nil
        @mov_status = nil
        @clock_div = nil
      end

      # ---- State machine settings (pioasm's .in / .out / .set / .mov_status / .clock_div). They go into the C
      # header's get_default_config; the shift settings and pin counts also reach the runtime's Program
      def shift_decl(what, count, dir, auto, threshold)
        raise AsmError, "#{what} pin count must be 1..32" unless count.between?(1, 32)
        raise AsmError, "#{what} shift direction must be :left or :right" unless dir == :left || dir == :right
        raise AsmError, "#{what} threshold must be 1..32" unless threshold.between?(1, 32)
        [count, dir == :right, auto, threshold]
      end

      # in_pins 32, :left, auto: true, threshold: 24 (.in 32 left auto 24). pio_version 0 has no IN pin count: 32 only
      def in_pins(count, dir = :right, auto: false, threshold: 32)
        raise AsmError, "in_pins given twice" unless @in_decl.nil?
        raise AsmError, "in pin count must be 32 for pio_version 0" if @pio_version == 0 && count != 32
        @in_decl = shift_decl("in", count, dir, auto, threshold)
      end

      def out_pins(count, dir = :right, auto: false, threshold: 32)
        raise AsmError, "out_pins given twice" unless @out_decl.nil?
        @out_decl = shift_decl("out", count, dir, auto, threshold)
      end

      def set_pins(count)
        raise AsmError, "set_pins given twice" unless @set_decl.nil?
        raise AsmError, "set pin count must be 1..5" unless count.between?(1, 5)
        @set_decl = count
      end

      # mov_status :txfifo, 3 (STATUS is all ones while the TX FIFO holds fewer than 3) / :rxfifo, n /
      # :irq, n (while IRQ flag n is set; pio: :prev / :next with pio_version 1)
      def mov_status(kind, n, pio: nil)
        raise AsmError, "mov_status given twice" unless @mov_status.nil?
        if kind == :irq
          raise AsmError, "mov_status irq needs pio_version: 1 (RP2350)" if @pio_version < 1
          raise AsmError, "mov_status irq index must be 0..7" unless n.between?(0, 7)
          raise AsmError, "mov_status pio: must be :prev or :next" unless pio.nil? || pio == :prev || pio == :next
          @mov_status = ["STATUS_IRQ_SET", n | (pio == :prev ? 8 : (pio == :next ? 16 : 0))]
        elsif kind == :txfifo || kind == :rxfifo
          raise AsmError, "mov_status pio: is only for :irq" unless pio.nil?
          raise AsmError, "mov_status level must be 0..#{@pio_version >= 1 ? 31 : 15}" unless n.between?(0, @pio_version >= 1 ? 31 : 15)
          @mov_status = [kind == :txfifo ? "STATUS_TX_LESSTHAN" : "STATUS_RX_LESSTHAN", n]
        else
          raise AsmError, "mov_status takes :txfifo, :rxfifo or :irq"
        end
      end

      # clock_div 2.5: clkdiv = int + frac / 256, frac rounded down as pioasm does. 1 is the default and leaves nothing
      def clock_div(v)
        raise AsmError, "clock_div given twice" unless @clock_div_given.nil?
        raise AsmError, "clock_div must be 1..65536" unless v >= 1 && v <= 65536
        @clock_div_given = true
        int = v.floor
        frac = ((v - int) * 256).floor
        @clock_div = [int, frac] unless int == 1 && frac == 0
      end

      # Max delay: the 5 delay/side-set bits minus those used by side-set
      def max_delay = (1 << (5 - @side_set - (@side_set_opt ? 1 : 0))) - 1

      # ---- Directives (the ones starting with . in pioasm) ----
      def label(name, public: false)
        raise AsmError, "label #{name} defined twice" if @labels.key?(name)
        @labels[name] = @words.size
        @public_labels << [name, @words.size] if public
        name
      end

      def wrap_target
        raise AsmError, "wrap_target specified twice" if @wrap_target
        @wrap_target = @words.size
      end

      def wrap
        raise AsmError, "wrap specified twice" if @wrap
        raise AsmError, "no instruction before wrap" if @words.empty?
        @wrap = @words.size - 1
      end

      # .define. Returns the value, so it can also be stored in a Ruby variable. If public, emits a #define in the C output
      def define(name, value, public: false)
        @defines << [name, value] if public
        value
      end

      # ---- Instructions ----
      def jmp(*args, side: nil, delay: 0)
        if args.size == 1
          cond = :always
          target = args[0]
        elsif args.size == 2
          cond, target = args
        else
          raise AsmError, "jmp takes jmp(target) or jmp(condition, target)"
        end
        c = JMP_CONDITIONS[cond] or raise AsmError, "unknown jmp condition #{cond.inspect} (#{JMP_CONDITIONS.keys.join(', ')})"
        emit(0x0000 | (c << 5), side, delay, target)
      end

      # rxfifo(:y): the register Y selects; rxfifo(n): register n (0-3)
      def rxfifo(index)
        raise AsmError, "rxfifo requires pio_version: 1 (RP2350)" if @pio_version < 1
        raise AsmError, "rxfifo index must be :y or 0..3" unless index == :y || (index.is_a?(Integer) && index.between?(0, 3))
        RxFifoEntry.new(index)
      end

      # pio: :prev / :next: the flag of the previous / next PIO block (pio_version 1)
      def irq_block(pio, rel)
        return rel ? 0x10 : 0 if pio.nil?
        raise AsmError, "irq pio: must be :prev or :next" unless IRQ_BLOCKS.key?(pio)
        raise AsmError, "irq pio: :#{pio} requires pio_version: 1 (RP2350)" if @pio_version < 1
        raise AsmError, "irq cannot be both rel and #{pio}" if rel
        IRQ_BLOCKS[pio]
      end

      def wait(polarity, source, index, rel: false, pio: nil, side: nil, delay: 0)
        raise AsmError, "wait polarity must be 0 or 1" unless polarity == 0 || polarity == 1
        src = WAIT_SOURCES[source] || (@pio_version >= 1 && WAIT_SOURCES_V1[source])
        raise AsmError, "wait source :jmppin requires pio_version: 1 (RP2350)" if !src && source == :jmppin
        raise AsmError, "invalid wait source #{source.inspect}" unless src
        if source == :irq
          raise AsmError, "wait irq index must be 0..7" unless index.between?(0, 7)
          index |= irq_block(pio, rel)
        elsif source == :jmppin
          raise AsmError, "wait jmppin offset must be 0..3" unless index.between?(0, 3)
        else
          raise AsmError, "rel is only valid for wait irq" if rel
          raise AsmError, "pio: is only valid for wait irq" unless pio.nil?
          raise AsmError, "wait #{source} index must be 0..31" unless index.between?(0, 31)
        end
        emit(0x2000 | (polarity << 7) | (src << 5) | index, side, delay)
      end

      def in_(source, bits, side: nil, delay: 0)
        s = IN_SOURCES[source] or raise AsmError, "invalid in source #{source.inspect}"
        emit(0x4000 | (s << 5) | bit_count(bits, "in"), side, delay)
      end

      def out(dest, bits, side: nil, delay: 0)
        d = OUT_DESTS[dest] or raise AsmError, "invalid out destination #{dest.inspect}"
        emit(0x6000 | (d << 5) | bit_count(bits, "out"), side, delay)
      end

      def push(iffull: false, block: true, side: nil, delay: 0)
        emit(0x8000 | (iffull ? 0x40 : 0) | (block ? 0x20 : 0), side, delay)
      end

      def pull(ifempty: false, block: true, side: nil, delay: 0)
        emit(0x8080 | (ifempty ? 0x40 : 0) | (block ? 0x20 : 0), side, delay)
      end

      def mov(dest, source, op: :none, side: nil, delay: 0)
        if dest.is_a?(RxFifoEntry) || source.is_a?(RxFifoEntry)
          raise AsmError, "mov with rxfifo takes no op" unless op == :none
          if dest.is_a?(RxFifoEntry)
            raise AsmError, "mov rxfifo[] takes only isr as its source" unless source == :isr
            raise AsmError, "mov rxfifo[], isr needs fifo: :txput or :putget" unless @fifo == :txput || @fifo == :putget
            return emit(0x8010 | dest.code, side, delay)
          end
          raise AsmError, "mov from rxfifo[] goes only to osr" unless dest == :osr
          raise AsmError, "mov osr, rxfifo[] needs fifo: :txget or :putget" unless @fifo == :txget || @fifo == :putget
          return emit(0x8090 | source.code, side, delay)
        end
        d = MOV_DESTS[dest] || (@pio_version >= 1 && MOV_DESTS_V1[dest])
        raise AsmError, "mov destination :pindirs requires pio_version: 1 (RP2350)" if !d && dest == :pindirs
        raise AsmError, "invalid mov destination #{dest.inspect}" unless d
        s = MOV_SOURCES[source] or raise AsmError, "invalid mov source #{source.inspect}"
        o = MOV_OPS[op] or raise AsmError, "mov op must be none / invert / reverse"
        emit(0xA000 | (d << 5) | (o << 3) | s, side, delay)
      end

      # irq(0) / irq(:wait, 0) / irq(:clear, 2, rel: true)
      def irq(*args, rel: false, pio: nil, side: nil, delay: 0)
        if args.size == 1
          mode = :set
          index = args[0]
        elsif args.size == 2
          mode, index = args
        else
          raise AsmError, "irq takes irq(index) or irq(:set/:nowait/:wait/:clear, index)"
        end
        m = IRQ_MODES[mode] or raise AsmError, "unknown irq mode #{mode.inspect}"
        raise AsmError, "irq index must be 0..7" unless index.between?(0, 7)
        emit(0xC000 | (m << 5) | index | irq_block(pio, rel), side, delay)
      end

      def set(dest, value, side: nil, delay: 0)
        d = SET_DESTS[dest] or raise AsmError, "invalid set destination #{dest.inspect}"
        raise AsmError, "set value must be 0..31" unless value.between?(0, 31)
        emit(0xE000 | (d << 5) | value, side, delay)
      end

      def nop(side: nil, delay: 0) = mov(:y, :y, side: side, delay: delay)

      # ---- Assembly ----
      def bit_count(bits, what)
        raise AsmError, "#{what} bit count must be 1..32" unless bits.between?(1, 32)
        bits & 31                           # 32 is encoded as 0
      end

      def emit(word, side, delay, target = nil)
        raise AsmError, "#{@name}: more than #{INSTRUCTION_MEMORY} instructions" if @words.size >= INSTRUCTION_MEMORY
        raise AsmError, "#{@name}: instruction #{@words.size}: delay #{delay} exceeds max #{max_delay} (side-set uses delay bits)" unless delay.between?(0, max_delay)
        if side.nil?
          raise AsmError, "#{@name}: instruction #{@words.size} has no side (required on every instruction unless side_set is opt)" if @side_set > 0 && !@side_set_opt
        else
          raise AsmError, "#{@name}: side given but no side_set" if @side_set == 0
          raise AsmError, "#{@name}: side value #{side} does not fit in #{@side_set} bits" unless side.between?(0, (1 << @side_set) - 1)
        end
        @words << word
        @sides << side
        @delays << delay
        @targets << target
        word
      end

      def finish
        raise AsmError, "#{@name}: no instructions" if @words.empty?
        code = []
        @words.each_with_index do |w, i|
          t = @targets[i]
          unless t.nil?
            addr = t.is_a?(Integer) ? t : @labels[t]
            raise AsmError, "#{@name}: undefined label #{t.inspect}" if addr.nil?
            raise AsmError, "#{@name}: jmp target #{addr} is outside the program" unless addr.between?(0, @words.size - 1)
            w |= addr
          end
          sd = @delays[i] << 8
          s = @sides[i]
          unless s.nil?
            if @side_set_opt
              sd |= 0x1000 | (s << (12 - @side_set))
            else
              sd |= s << (13 - @side_set)
            end
          end
          code << (w | sd)
        end
        wt = @wrap_target || 0
        wr = @wrap || @words.size - 1
        a = Assembled.new(@name, code, wt, wr, @origin.nil? ? -1 : @origin, @pio_version,
                          @side_set, @side_set_opt, @side_set_pindirs, @defines, @public_labels)
        a.fifo = @fifo
        a.in_decl = @in_decl
        a.out_decl = @out_decl
        a.set_decl = @set_decl
        a.mov_status = @mov_status
        a.clock_div = @clock_div
        unless @in_decl.nil?                   # the same settings where the time layer keeps them, for Program
          a.in_count = @in_decl[0]
          a.in_shift_right = @in_decl[1]
          a.autopush = @in_decl[2]
          a.push_threshold = @in_decl[3]
        end
        unless @out_decl.nil?
          a.out_count = @out_decl[0]
          a.out_shift_right = @out_decl[1]
          a.autopull = @out_decl[2]
          a.pull_threshold = @out_decl[3]
        end
        a.set_count = @set_decl unless @set_decl.nil?
        a
      end
    end

    def self.asm(name, side_set: 0, side_set_opt: false, side_set_pindirs: false, origin: nil, pio_version: 0,
                 fifo: :txrx, &block)
      a = Assembler.new(name, side_set, side_set_opt, side_set_pindirs, origin, pio_version, fifo)
      a.instance_eval(&block)
      a.finish
    end
  end
end
