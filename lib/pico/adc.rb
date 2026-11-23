# ADC (names follow pico-sdk's hardware_adc without the adc_ prefix). 12-bit, inputs 0-3 = GPIO 26-29,
# input 4 = the on-chip temperature sensor. On the Pico, input 3 (GPIO 29) reads VSYS / 3.
# init also starts the 48 MHz clk_adc from the USB PLL if it is not running (bare-full does not start it).
# clk_sys must be at least as fast as clk_adc: on an RP2040 Pico the ADC registers read 0 and ignore writes while
# clk_sys is 12 MHz and clk_adc 48 MHz, and work at clk_sys 48 or 125 MHz (the datasheet does not state this; compare
# erratum RP2040-E16 for USB). init raises instead of failing silently.
require_relative "chip"
require_relative "resets"
require_relative "clocks"
require_relative "gpio"

module Pico
  class ADC
    CS = 0x00
    RESULT = 0x04
    CS_EN = 1 << 0
    CS_TS_EN = 1 << 1
    CS_START_ONCE = 1 << 2
    CS_READY = 1 << 8
    CS_ERR = 1 << 9
    # AINSEL and RROBIN are wider on RP2350: Chip#adc_ainsel, Chip#adc_rrobin
    VREF_MV = 3300                   # the Pico's ADC_VREF is the 3.3 V rail

    def initialize(bus, chip)
      @bus = bus
      @chip = chip
    end

    def reg(off) = @chip.adc_base + off

    def init
      clocks = Clocks.new(@bus, @chip)
      sys = clocks.get_hz(:sys)
      if sys < Clocks::USB_ADC_HZ
        raise "ADC needs clk_sys >= 48 MHz (clk_adc); clk_sys is #{sys}Hz: call clocks.set_sys_clock_khz(48_000) or faster first"
      end
      clocks.init_48mhz(:adc)
      Resets.new(@bus, @chip).reset_unreset_block_wait([:adc])
      @bus.write32(reg(CS), CS_EN)
      wait_ready
    end

    # Make a pin an analog input: no digital function, no pulls, digital input off (pico-sdk's adc_gpio_init)
    def gpio_init(gpio)
      raise "GPIO #{gpio} has no ADC input (GPIO #{@chip.adc_first_gpio}-#{@chip.adc_first_gpio + 3})" unless gpio.between?(@chip.adc_first_gpio, @chip.adc_first_gpio + 3)
      g = GPIO.new(@bus, @chip)
      g.set_function(gpio, :null)
      g.disable_pulls(gpio)
      g.set_input_enabled(gpio, false)
    end

    def select_input(input)
      raise "ADC input must be 0-#{@chip.adc_temp_channel}" unless input.between?(0, @chip.adc_temp_channel)
      @bus.write_masked(reg(CS), input << 12, @chip.adc_ainsel)
    end

    def get_selected_input = (@bus.read32(reg(CS)) & @chip.adc_ainsel) >> 12
    def set_temp_sensor_enabled(on) = @bus.write_masked(reg(CS), on ? CS_TS_EN : 0, CS_TS_EN)

    # Inputs to cycle through on each conversion, as a bit mask (0 = off)
    def set_round_robin(mask) = @bus.write_masked(reg(CS), (mask << 16) & @chip.adc_rrobin, @chip.adc_rrobin)

    # One conversion on the selected input: 0-4095
    def read
      @bus.set_bits(reg(CS), CS_START_ONCE)
      wait_ready
      @bus.read32(reg(RESULT)) & 0xfff
    end

    def wait_ready
      n = 0
      while (@bus.read32(reg(CS)) & CS_READY) == 0
        n += 1
        raise "ADC did not become ready (is clk_adc running?)" if n > 100_000
      end
    end

    def self.to_mv(raw) = raw * VREF_MV / 4096

    # Temperature sensor reading in tenths of a degree C, from the datasheet formula
    # T = 27 - (V - 0.706) / 0.001721 (in integers: V in 0.1 mV)
    def self.temp_c10(raw)
      v = raw * VREF_MV * 10 / 4096
      270 - (v - 7060) * 100 / 1721
    end
  end
end
