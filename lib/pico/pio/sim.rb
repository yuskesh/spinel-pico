# Runs one PIO SM (state machine 0) instruction by instruction (for verification). Takes a PIO::Assembled and records the
# times the SET pin and the side-set pins change
#   Supported: jmp (all conditions; pin reads input bit jmp_pin:), pull (block/noblock; ifempty ignored), out (x/y/null/isr, autopull), mov (x/y/isr/osr/null,
#         op none/invert), set (pins: all 5 SET pins, x, y; pindirs ignored), nop, wrap, delay, stalling on pull block with an empty FIFO,
#         side-set (opt too; applied at the start of the instruction, also when it stalls), wait pin / irq, in (pins/x/y/null,
#         autopush), push (block/iffull; the RX FIFO never fills), irq set/wait/clear
#   Inputs: inputs: [[time, bits], ...] sets the IN pins (bit 0 = IN base) from that cycle on (0 before the first entry).
#         irq_clears: [[time, n], ...] clears IRQ flag n at that cycle, as the CPU or another SM would
#   OUT pin 0 changes from mov pins / out pins are recorded in out_edges
#   Not supported (raises if encountered): wait gpio, out pc/exec, mov pc/exec/status
module Pico
  module PIO
    class Sim
      MASK = 0xFFFFFFFF
      class Unsupported < StandardError; end

      attr_reader :out_writes, :edges, :time, :side_edges, :set_edges, :out_edges, :rx, :irq_log

      def initialize(code, fifo: [], inputs: [], irq_clears: [], jmp_pin: -1, isr: 0)
        @code = code
        @fifo = fifo.dup
        @fifo.each { |v| raise ArgumentError, "FIFO value #{v} is not a uint32" unless v.between?(0, MASK) }
        @right = code.out_shift_right.nil? ? true : code.out_shift_right   # SM default is shift right
        @threshold = code.pull_threshold || 32
        @pc = 0
        @x = 0
        @y = 0
        @osr = 0
        @out_writes = []                    # [time, value] for each out pins, n
        @isr = isr                          # what the CPU loaded before the start (StateMachine#load_isr)
        @shift_count = 32                   # OSR is empty at startup
        @pin = 0
        @time = 0
        @edges = []
        @inputs = inputs
        @jmp_pin = jmp_pin                  # bit of inputs that jmp pin reads
        @out_pin = 0
        @out_edges = []                     # [time, level] of OUT pin 0 (mov pins / out pins)
        @irq_clears = irq_clears
        @in_right = code.in_shift_right.nil? ? true : code.in_shift_right
        @push_threshold = code.push_threshold || 32
        @in_count = 0
        @rx = []
        @irq_flags = 0
        @irq_log = []                       # [time, flag] for each irq set
        @irq_waiting = false
        @set_pins = 0
        @set_edges = []                     # [time, SET pin index, level] (edges holds SET pin 0 alone)
        @sides = 0
        @side_edges = []                    # [time, side pin index, level]
        sb = code.side_set_bits
        @delay_mask = (1 << (5 - sb)) - 1
        @side_shift = 5 - sb
        @side_bits = code.side_set_count
        @side_opt = code.side_set_opt
      end

      # IN pins at the current cycle
      def in_pins
        v = 0
        @inputs.each { |e| v = e[1] if e[0] <= @time }
        v
      end

      def apply_irq_clears
        @irq_clears.each { |e| @irq_flags &= ~(1 << e[1]) if e[0] == @time }
      end

      def stall
        @time += 1
        apply_irq_clears
      end

      def apply_side(field)
        return if @side_bits == 0
        v = field >> @side_shift
        if @side_opt
          return if ((v >> @side_bits) & 1) == 0
          v &= (1 << @side_bits) - 1
        end
        @side_bits.times do |i|
          b = (v >> i) & 1
          @side_edges << [@time, i, b] if b != ((@sides >> i) & 1)
        end
        @sides = v
      end

      # [High length, following Low length] pairs of side-set pin i
      def side_pulses(i) = pulses_of(@side_edges, i)

      # the same for SET pin i
      def set_pulses(i) = pulses_of(@set_edges, i)

      def pulses_of(edges, i)
        e = edges.select { |x| x[1] == i }
        r = []
        e.each_cons(3) { |a, b, c| r << [b[0] - a[0], c[0] - b[0]] if a[2] == 1 }
        r
      end

      def run(cycles)
        while @time < cycles
          step
        end
        self
      end

      def step
        w = @code.instructions[@pc]
        field = (w >> 8) & 0x1F
        apply_side(field)
        delay = field & @delay_mask
        op = w >> 13
        arg = (w >> 5) & 7
        low = w & 0x1F
        jumped = nil
        case op
        when 0
          take = case arg
                 when 0 then true
                 when 1 then @x == 0
                 when 2 then r = @x != 0; @x = (@x - 1) & MASK; r
                 when 3 then @y == 0
                 when 4 then r = @y != 0; @y = (@y - 1) & MASK; r
                 when 5 then @x != @y
                 when 7 then @shift_count < @threshold
                 else
                   raise Unsupported, "#{@pc}: jmp pin without jmp_pin:" if @jmp_pin < 0
                   ((in_pins >> @jmp_pin) & 1) == 1
                 end
          jumped = low if take
        when 1
          src = arg & 3
          pol = (w >> 7) & 1
          case src
          when 1
            unless ((in_pins >> low) & 1) == pol
              stall
              return
            end
          when 2
            f = low & 7
            unless ((@irq_flags >> f) & 1) == pol
              stall
              return
            end
            @irq_flags &= ~(1 << f) if pol == 1
          else raise Unsupported, "#{@pc}: wait source #{src}"
          end
        when 2
          n = low == 0 ? 32 : low
          v = case arg
              when 0 then in_pins
              when 1 then @x
              when 2 then @y
              when 3 then 0
              else raise Unsupported, "#{@pc}: in source #{arg}"
              end
          v &= n == 32 ? MASK : (1 << n) - 1
          if @in_right
            @isr = n == 32 ? v : ((@isr >> n) | (v << (32 - n))) & MASK
          else
            @isr = n == 32 ? v : ((@isr << n) | v) & MASK
          end
          @in_count = [@in_count + n, 32].min
          if @code.autopush && @in_count >= @push_threshold
            @rx << @isr
            @isr = 0
            @in_count = 0
          end
        when 3
          n = low == 0 ? 32 : low
          if @code.autopull && @shift_count >= @threshold
            if @fifo.empty?                    # autopull: if OSR is empty and the FIFO is empty too, stall on out
              stall
              return
            end
            @osr = @fifo.shift
            @shift_count = 0
          end
          v = shift_out(n)
          case arg
          when 0
            @out_writes << [@time, v & (n == 32 ? MASK : (1 << n) - 1)]
            write_out(v)
          when 1 then @x = v
          when 2 then @y = v
          when 3 then nil
          when 6 then @isr = v
          else raise Unsupported, "#{@pc}: out destination #{arg}"
          end
        when 4
          if (w & 0x80) == 0
            if (w & 0x40) == 0 || @in_count >= @push_threshold   # iffull: only when the threshold is reached
              @rx << @isr
              @isr = 0
              @in_count = 0
            end
          elsif @fifo.empty?
            if (w & 0x20) != 0                 # block: stall until a word arrives (no delay applied either)
              stall
              return
            end
            @osr = @x                          # noblock: copy X
            @shift_count = 0
          else
            @osr = @fifo.shift
            @shift_count = 0
          end
        when 5
          src = low & 7
          mop = (low >> 3) & 3
          v = case src
              when 0 then in_pins
              when 1 then @x
              when 2 then @y
              when 3 then 0
              when 6 then @isr
              when 7 then @osr
              else raise Unsupported, "#{@pc}: mov source #{src}"
              end
          v = (~v) & MASK if mop == 1
          raise Unsupported, "#{@pc}: mov reverse" if mop == 2
          case arg
          when 0 then write_out(v)
          when 1 then @x = v
          when 2 then @y = v
          when 6 then @isr = v
          when 7 then @osr = v; @shift_count = 0
          else raise Unsupported, "#{@pc}: mov destination #{arg}"
          end
        when 7
          case arg
          when 0
            5.times do |i|
              b = (low >> i) & 1
              @set_edges << [@time, i, b] if b != ((@set_pins >> i) & 1)
            end
            @set_pins = low
            v = low & 1
            @edges << [@time, v] if v != @pin
            @pin = v
          when 1 then @x = low
          when 2 then @y = low
          when 4 then nil
          else raise Unsupported, "#{@pc}: set destination #{arg}"
          end
        when 6
          f = low & 7
          if (w & 0x40) != 0
            @irq_flags &= ~(1 << f)
          else
            unless @irq_waiting
              @irq_flags |= 1 << f
              @irq_log << [@time, f]
              @irq_waiting = (w & 0x20) != 0
            end
            if @irq_waiting
              if ((@irq_flags >> f) & 1) == 1
                stall
                return
              end
              @irq_waiting = false
            end
          end
        else
          raise Unsupported, "#{@pc}: instruction kind #{op}"
        end
        delay.times do
          @time += 1
          apply_irq_clears
        end
        @time += 1
        apply_irq_clears
        advance(jumped)
      end

      def write_out(v)
        b = v & 1
        @out_edges << [@time, b] if b != @out_pin
        @out_pin = b
      end

      # [High length, following Low length] pairs of OUT pin 0
      def out_pulses
        r = []
        @out_edges.each_cons(3) { |a, b, c| r << [b[0] - a[0], c[0] - b[0]] if a[1] == 1 }
        r
      end

      def advance(jumped)
        if jumped
          @pc = jumped
        elsif @pc == @code.wrap
          @pc = @code.wrap_target
        else
          @pc += 1
        end
      end

      def shift_out(n)
        if @right
          v = n == 32 ? @osr : @osr & ((1 << n) - 1)
          @osr = n == 32 ? 0 : @osr >> n
        else
          v = n == 32 ? @osr : @osr >> (32 - n)
          @osr = n == 32 ? 0 : (@osr << n) & MASK
        end
        @shift_count = [@shift_count + n, 32].min
        v
      end

      # pairs of [High length, following Low length], in order
      def pulses
        r = []
        @edges.each_cons(3) { |a, b, c| r << [b[0] - a[0], c[0] - b[0]] if a[1] == 1 }
        r
      end
    end
  end
end
