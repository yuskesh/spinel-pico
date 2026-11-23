# Runtime layer: an assembled program (corresponds to pico-sdk's pio_program plus its default config).
# Built by the Ruby that Assembled#to_ruby emits on the host. Instructions are never reassembled on the microcontroller.
module Pico
  module PIO
    class Program
      attr_reader :name, :instructions, :origin, :wrap_target, :wrap,
                  :side_set_count, :side_set_opt, :side_set_pindirs,
                  :out_shift_right, :pull_threshold, :autopull, :in_shift_right, :push_threshold, :autopush,
                  :set_count, :out_count, :in_count, :jmp_input, :clock_hz, :pio_version, :fifo,
                  :status_sel, :status_n, :div_int, :div_frac

      def initialize(name, instructions, origin, wrap_target, wrap,
                     side_set_count, side_set_opt, side_set_pindirs,
                     out_shift_right, pull_threshold, autopull, in_shift_right, push_threshold, autopush,
                     set_count, out_count, in_count, jmp_input, clock_hz, pio_version, fifo = :txrx,
                     status_sel = :none, status_n = 0, div_int = 0, div_frac = 0)
        @name = name
        @instructions = instructions
        @origin = origin
        @wrap_target = wrap_target
        @wrap = wrap
        @side_set_count = side_set_count
        @side_set_opt = side_set_opt
        @side_set_pindirs = side_set_pindirs
        @out_shift_right = out_shift_right
        @pull_threshold = pull_threshold
        @autopull = autopull
        @in_shift_right = in_shift_right
        @push_threshold = push_threshold
        @autopush = autopush
        @set_count = set_count
        @out_count = out_count
        @in_count = in_count
        @jmp_input = jmp_input
        @clock_hz = clock_hz
        @pio_version = pio_version
        @fifo = fifo                        # :txrx, :tx, :rx; with pio_version 1 also :txput, :txget, :putget
        @status_sel = status_sel            # mov_status: :none, :txfifo, :rxfifo, :irq (pio_version 1), with status_n
        @status_n = status_n
        @div_int = div_int                  # clock_div (0: not given)
        @div_frac = div_frac
      end

      def length = @instructions.size
      def side_set_bits = @side_set_count + (@side_set_opt ? 1 : 0)

      # Corresponds to pico-sdk's <name>_program_get_default_config
      def default_config(offset)
        c = SMConfig.new
        c.set_wrap(offset + @wrap_target, offset + @wrap)
        c.set_sideset(side_set_bits, @side_set_opt, @side_set_pindirs) if side_set_bits > 0
        c.set_out_shift(@out_shift_right, @autopull, @pull_threshold) unless @pull_threshold.nil?
        c.set_in_shift(@in_shift_right, @autopush, @push_threshold) unless @push_threshold.nil?
        c.set_fifo_join(@fifo) unless @fifo == :txrx
        c.set_mov_status(@status_sel, @status_n) unless @status_sel == :none
        c.set_clkdiv_int_frac(@div_int, @div_frac) if @div_int > 0
        c
      end

      # Set up state machine sm for this program at offset, as the program_init functions in pico-examples do: the
      # default config, the pins of each role the program declares (pass -1 for a role it does not use), the GPIO
      # functions and pin directions of its outputs, and the clkdiv for its PIO clock from clk_sys in Hz. The SM is left
      # stopped (start it with set_enabled or Block#enable_in_sync). Returns the config
      def init_sm(sm, offset, set_base, side_base, out_base, in_base, sys_hz)
        c = default_config(offset)
        blk = sm.block
        if @set_count > 0
          c.set_set_pins(set_base, @set_count)
          @set_count.times { |i| blk.gpio_init(set_base + i) }
        end
        if @side_set_count > 0
          c.set_sideset_pins(side_base)
          @side_set_count.times { |i| blk.gpio_init(side_base + i) }
        end
        if @out_count > 0
          c.set_out_pins(out_base, @out_count)
          @out_count.times { |i| blk.gpio_init(out_base + i) }
        end
        c.set_in_pins(in_base) if @in_count > 0
        c.set_jmp_pin(in_base + @jmp_input) if @jmp_input >= 0
        c.set_clkdiv_for(sys_hz, @clock_hz) unless @clock_hz.nil?
        sm.init(offset, c)
        sm.set_consecutive_pindirs(set_base, @set_count, true) if @set_count > 0
        sm.set_consecutive_pindirs(side_base, @side_set_count, true) if @side_set_count > 0
        sm.set_consecutive_pindirs(out_base, @out_count, true) if @out_count > 0
        c
      end
    end

    # SM configuration (pico-sdk's pio_sm_config and sm_config_set_*). Only holds values; StateMachine#init writes them
    class SMConfig
      attr_reader :wrap_bottom, :wrap_top, :side_bits, :side_opt, :side_pindirs,
                  :out_right, :autopull, :pull_thresh, :in_right, :autopush, :push_thresh,
                  :clkdiv_int, :clkdiv_frac, :out_base, :out_count, :set_base, :set_count,
                  :in_base, :sideset_base, :jmp_pin, :fifo_join, :status_sel, :status_n

      def initialize
        @wrap_bottom = 0
        @wrap_top = 31
        @side_bits = 0
        @side_opt = false
        @side_pindirs = false
        @out_right = true            # SM default is shift right
        @autopull = false
        @pull_thresh = 32
        @in_right = true
        @autopush = false
        @push_thresh = 32
        @clkdiv_int = 1
        @clkdiv_frac = 0
        @out_base = 0
        @out_count = 0
        @set_base = 0
        @set_count = 0              # pico-sdk defaults (all pin settings 0)
        @in_base = 0
        @sideset_base = 0
        @jmp_pin = 0
        @fifo_join = :none
        @status_sel = :txfifo
        @status_n = 0
      end

      def set_wrap(bottom, top)
        @wrap_bottom = bottom
        @wrap_top = top
      end

      def set_sideset(bits, opt, pindirs)
        raise "side-set must be 0-5 bits" unless bits.between?(0, 5)
        @side_bits = bits
        @side_opt = opt
        @side_pindirs = pindirs
      end

      def set_out_shift(right, autopull, threshold)
        raise "pull threshold must be 1-32" unless threshold.between?(1, 32)
        @out_right = right
        @autopull = autopull
        @pull_thresh = threshold
      end

      def set_in_shift(right, autopush, threshold)
        raise "push threshold must be 1-32" unless threshold.between?(1, 32)
        @in_right = right
        @autopush = autopush
        @push_thresh = threshold
      end

      def set_out_pins(base, count)
        check_pin(base)
        raise "out pin count must be 0-32" unless count.between?(0, 32)
        @out_base = base
        @out_count = count
      end

      def set_set_pins(base, count)
        check_pin(base)
        raise "set pin count must be 0-5" unless count.between?(0, 5)
        @set_base = base
        @set_count = count
      end

      def set_in_pins(base)
        check_pin(base)
        @in_base = base
      end

      def set_sideset_pins(base)
        check_pin(base)
        @sideset_base = base
      end

      def set_jmp_pin(pin)
        check_pin(pin)
        @jmp_pin = pin
      end

      # :none / :tx (8-deep TX) / :rx (8-deep RX); on RP2350 also :txput / :txget / :putget (the RX FIFO's registers
      # are used by mov rxfifo[] instead; pico-sdk's PIO_FIFO_JOIN_*)
      def set_fifo_join(join)
        unless join == :none || join == :tx || join == :rx || join == :txput || join == :txget || join == :putget
          raise "fifo_join must be :none / :tx / :rx / :txput / :txget / :putget"
        end
        @fifo_join = join
      end

      # What mov x, status reads as all ones (pico-sdk's sm_config_set_mov_status): :txfifo / :rxfifo while that FIFO
      # holds fewer than n words, :irq while IRQ flag n is set (RP2350; n + 8 / + 16 for the previous / next PIO block)
      def set_mov_status(sel, n)
        raise "mov_status must be :txfifo, :rxfifo or :irq" unless sel == :txfifo || sel == :rxfifo || sel == :irq
        raise "mov_status n must be 0-31" unless n.between?(0, 31)
        @status_sel = sel
        @status_n = n
      end

      # clkdiv = int + frac/256. int is 1-65535 (0 means 65536 but is not used)
      def set_clkdiv_int_frac(int, frac)
        raise "clkdiv integer part must be 1-65535" unless int.between?(1, 65535)
        raise "clkdiv fractional part must be 0-255" unless frac.between?(0, 255)
        raise "clkdiv fractional part must be 0 when the integer part is 1" if int == 1 && frac != 0
        @clkdiv_int = int
        @clkdiv_frac = frac
      end

      # Derive the clkdiv that runs the program at the clock it was built for (Program#clock_hz) from clk_sys in Hz.
      # A non-integer ratio makes each cycle's length jitter, so it is allowed only with fractional: true
      def set_clkdiv_for(sys_hz, clock_hz, fractional: false)
        raise "this program has no PIO clock (at the instruction layer, use set_clkdiv_int_frac)" if clock_hz.nil?
        int = sys_hz / clock_hz
        raise "clk_sys #{sys_hz}Hz cannot run at #{clock_hz}Hz (clkdiv must be >= 1)" if int < 1
        r = sys_hz % clock_hz
        frac = 0
        8.times do                   # fractional part one bit at a time (r * 256 may exceed 32 bits)
          r *= 2
          frac *= 2
          if r >= clock_hz
            frac += 1
            r -= clock_hz
          end
        end
        if (frac != 0 || r != 0) && !fractional
          raise "clk_sys #{sys_hz}Hz is not an integer multiple of #{clock_hz}Hz (a fractional clkdiv jitters the cycle length; " \
                "pass fractional: true to allow it)"
        end
        raise "ratio of clk_sys #{sys_hz}Hz to #{clock_hz}Hz is not representable in 1/256 clkdiv steps" if r != 0
        set_clkdiv_int_frac(int, frac)
      end

      def check_pin(p)
        raise "pin must be 0-31 (#{p})" unless p.between?(0, 31)
      end
    end
  end
end
