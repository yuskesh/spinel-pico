# PWM slices (names follow pico-sdk's hardware_pwm without the pwm_ prefix). Each slice has a counter that runs from 0
# to the wrap value (TOP) and two outputs, A and B: GPIO 2n and 2n+1 (mod 16) are slice n's A and B.
# Route a pin with gpio.set_function(pin, :pwm). Levels and wrap are 16-bit; the clock is clk_sys / (int + frac/16).
# Interrupt flags can be polled (get_irq_status_mask); there is no interrupt handling yet.
# Writes to a block in reset are ignored: init releases the PWM block if it is in reset.
require_relative "chip"
require_relative "resets"

module Pico
  class PWM
    CSR = 0x00
    DIV = 0x04
    CTR = 0x08
    CC = 0x0c
    TOP = 0x10
    STRIDE = 0x14
    EN = 0xa0
    INTR = 0xa4
    INTE = 0xa8
    CSR_EN = 1 << 0
    CSR_PH_CORRECT = 1 << 1
    CSR_A_INV = 1 << 2
    CSR_B_INV = 1 << 3
    CSR_DIVMODE = 3 << 4

    def initialize(bus, chip)
      @bus = bus
      @chip = chip
    end

    def gpio_to_slice_num(gpio)
      @chip.check_gpio(gpio)
      (gpio >> 1) & (@chip.num_pwm_slices - 1)
    end

    def gpio_to_channel(gpio) = gpio & 1                # 0 = A, 1 = B

    def reg(slice, off)
      raise "PWM slice must be 0-#{@chip.num_pwm_slices - 1}" unless slice.between?(0, @chip.num_pwm_slices - 1)
      @chip.pwm_base + STRIDE * slice + off
    end

    # pico-sdk's pwm_init with pwm_get_default_config: free-running, trailing-edge, divider 1, wrap 0xffff,
    # both levels 0, counter 0. Starts the slice if start is true
    def init(slice, start)
      resets = Resets.new(@bus, @chip)
      resets.unreset_block_wait([:pwm]) if resets.in_reset?(:pwm)
      @bus.write32(reg(slice, CSR), 0)
      @bus.write32(reg(slice, CTR), 0)
      @bus.write32(reg(slice, CC), 0)
      @bus.write32(reg(slice, TOP), 0xffff)
      @bus.write32(reg(slice, DIV), 1 << 4)
      @bus.set_bits(reg(slice, CSR), CSR_EN) if start
    end

    def set_wrap(slice, wrap)
      check16(wrap, "wrap")
      @bus.write32(reg(slice, TOP), wrap)
    end

    # channel: 0 (A) or 1 (B). The output is high while the counter is below level
    def set_chan_level(slice, channel, level)
      check16(level, "level")
      cc = @bus.read32(reg(slice, CC))
      if channel == 0
        @bus.write32_hl(reg(slice, CC), (cc >> 16) & 0xffff, level)
      else
        @bus.write32_hl(reg(slice, CC), level, cc & 0xffff)
      end
    end

    def set_both_levels(slice, level_a, level_b)
      check16(level_a, "level")
      check16(level_b, "level")
      @bus.write32_hl(reg(slice, CC), level_b, level_a)
    end

    def set_gpio_level(gpio, level) = set_chan_level(gpio_to_slice_num(gpio), gpio_to_channel(gpio), level)

    # Divider int + frac/16, int 1-255 (pico-sdk's pwm_set_clkdiv_int_frac)
    def set_clkdiv_int_frac(slice, int, frac)
      raise "PWM clkdiv must be 1-255 + 0-15/16" unless int.between?(1, 255) && frac.between?(0, 15)
      @bus.write32(reg(slice, DIV), (int << 4) | frac)
    end

    def set_phase_correct(slice, on) = @bus.write_masked(reg(slice, CSR), on ? CSR_PH_CORRECT : 0, CSR_PH_CORRECT)

    def set_output_polarity(slice, invert_a, invert_b)
      v = (invert_a ? CSR_A_INV : 0) | (invert_b ? CSR_B_INV : 0)
      @bus.write_masked(reg(slice, CSR), v, CSR_A_INV | CSR_B_INV)
    end

    # :free (count every cycle), :b_high (count while input B is high), :b_rising, :b_falling (count edges on B)
    def set_clkdiv_mode(slice, mode)
      code = case mode
             when :free then 0
             when :b_high then 1
             when :b_rising then 2
             when :b_falling then 3
             else raise "PWM clkdiv mode must be :free, :b_high, :b_rising or :b_falling"
             end
      @bus.write_masked(reg(slice, CSR), code << 4, CSR_DIVMODE)
    end

    def set_enabled(slice, on) = @bus.write_masked(reg(slice, CSR), on ? CSR_EN : 0, CSR_EN)

    # Start or stop several slices on the same cycle (bit n = slice n)
    def set_mask_enabled(mask) = @bus.write32(@chip.pwm_base + @chip.pwm_en, mask)

    def get_counter(slice) = @bus.read32(reg(slice, CTR)) & 0xffff

    def set_counter(slice, count)
      check16(count, "counter")
      @bus.write32(reg(slice, CTR), count)
    end

    def advance_count(slice) = @bus.set_bits(reg(slice, CSR), 1 << 7)
    def retard_count(slice) = @bus.set_bits(reg(slice, CSR), 1 << 6)

    # Wrap flags: set when a slice's counter wraps (polled; write 1 to clear)
    def get_irq_status_mask = @bus.read32(@chip.pwm_base + @chip.pwm_intr) & ((1 << @chip.num_pwm_slices) - 1)
    def clear_irq(slice) = @bus.write32(@chip.pwm_base + @chip.pwm_intr, 1 << slice)

    def set_irq_enabled(slice, on)
      if on
        @bus.set_bits(@chip.pwm_base + @chip.pwm_inte, 1 << slice)
      else
        @bus.clear_bits(@chip.pwm_base + @chip.pwm_inte, 1 << slice)
      end
    end

    def check16(v, what)
      raise "PWM #{what} must be 0-65535 (got #{v})" unless v.between?(0, 0xffff)
    end
  end
end
