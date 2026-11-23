# GPIO (names follow pico-sdk's hardware_gpio without the gpio_ prefix: gpio_put -> put).
# Pin functions are symbols: :sio, :uart, :spi, :i2c, :pwm, :pio0, :pio1, :gpck, :usb, :null.
# Only GPIO 0-30: one SIO word, and 1 << 31 does not fit in bare-full's 32-bit Integer (RP2040 and RP2350A have 30 pins;
# RP2350B's GPIO 32-47 would need the GPIO_HI registers).
# Pin values and directions are true/false
require_relative "chip"

module Pico
  class GPIO
    # PADS_BANK0 GPIOn bits (RP2040 datasheet 2.19.6.3)
    PAD_SLEWFAST = 1 << 0
    PAD_SCHMITT = 1 << 1
    PAD_PDE = 1 << 2
    PAD_PUE = 1 << 3
    PAD_DRIVE_LSB = 4
    PAD_DRIVE = 3 << 4
    PAD_IE = 1 << 6
    PAD_OD = 1 << 7
    PAD_ISO = 1 << 8                 # RP2350 only
    CTRL_FUNCSEL = 0x1f
    # OUTOVER / OEOVER positions differ by chip: Chip#gpio_outover_lsb, Chip#gpio_oeover_lsb
    CTRL_INOVER_LSB = 16
    CTRL_IRQOVER_LSB = 28
    # Interrupt events (pico-sdk's GPIO_IRQ_*), 4 bits per pin in IO_BANK0 INTR / PROC0_INTE / PROC0_INTS
    IRQ_LEVEL_LOW = 1
    IRQ_LEVEL_HIGH = 2
    IRQ_EDGE_FALL = 4
    IRQ_EDGE_RISE = 8
    BANK0_INTR0 = 0x0f0
    BANK0_PROC0_INTE0 = 0x100
    BANK0_PROC0_INTS0 = 0x120

    attr_reader :chip

    def initialize(bus, chip)
      @bus = bus
      @chip = chip
    end

    def pad(pin)
      @chip.check_gpio(pin)
      @chip.pads_bank0_base + 4 + 4 * pin
    end

    def ctrl(pin)
      @chip.check_gpio(pin)
      @chip.io_bank0_base + 4 + 8 * pin
    end

    def sio(off) = @chip.sio_base + off

    # Make the pin a plain input driven by software, output value 0 (pico-sdk's gpio_init)
    def init(pin)
      set_dir(pin, false)
      put(pin, false)
      set_function(pin, :sio)
    end

    def deinit(pin) = set_function(pin, :null)

    # Route the pin to a peripheral. Also enables the input and clears output disable, as pico-sdk does
    def set_function(pin, fn)
      n = @chip.function_number(fn)
      @bus.write_masked(pad(pin), PAD_IE, PAD_IE | PAD_OD)
      @bus.write32(ctrl(pin), n)
      @bus.clear_bits(pad(pin), PAD_ISO) if @chip.pads_iso
    end

    def get_function(pin) = @bus.read32(ctrl(pin)) & CTRL_FUNCSEL

    # ---- overrides in GPIOn_CTRL (pico-sdk's gpio_set_outover, ...). set_function clears them, so set them after it.
    # out / in / irq: :normal, :invert, :low, :high. oe: :normal, :invert, :disable, :enable
    def set_outover(pin, v) = set_override(pin, @chip.gpio_outover_lsb, override_code(v, :low, :high))
    def set_oeover(pin, v) = set_override(pin, @chip.gpio_oeover_lsb, override_code(v, :disable, :enable))
    def set_inover(pin, v) = set_override(pin, CTRL_INOVER_LSB, override_code(v, :low, :high))
    def set_irqover(pin, v) = set_override(pin, CTRL_IRQOVER_LSB, override_code(v, :low, :high))

    def set_override(pin, lsb, code) = @bus.write_masked(ctrl(pin), code << lsb, 3 << lsb)

    def override_code(v, two, three)
      return 0 if v == :normal
      return 1 if v == :invert
      return 2 if v == two
      return 3 if v == three
      raise "GPIO override must be :normal, :invert, :#{two} or :#{three} (got #{v})"
    end

    # ---- software-driven pins (SIO). SIO has its own SET/CLR/XOR registers, not the atomic aliases
    def set_dir(pin, out)
      @bus.write32(sio(out ? @chip.sio_oe_set : @chip.sio_oe_clr), 1 << check_sio(pin))
    end

    def is_dir_out?(pin) = (@bus.read32(sio(@chip.sio_gpio_oe)) & (1 << check_sio(pin))) != 0
    def set_dir_out_masked(mask) = @bus.write32(sio(@chip.sio_oe_set), mask)
    def set_dir_in_masked(mask) = @bus.write32(sio(@chip.sio_oe_clr), mask)

    def put(pin, value)
      @bus.write32(sio(value ? @chip.sio_out_set : @chip.sio_out_clr), 1 << check_sio(pin))
    end

    def get(pin) = (get_all & (1 << check_sio(pin))) != 0
    def get_all = @bus.read32(sio(@chip.sio_gpio_in))
    def get_out_level(pin) = (@bus.read32(sio(@chip.sio_gpio_out)) & (1 << check_sio(pin))) != 0
    def set_mask(mask) = @bus.write32(sio(@chip.sio_out_set), mask)
    def clr_mask(mask) = @bus.write32(sio(@chip.sio_out_clr), mask)
    def xor_mask(mask) = @bus.write32(sio(@chip.sio_out_xor), mask)

    # Set the pins in mask to the corresponding bits of value
    def put_masked(mask, value) = @bus.write32(sio(@chip.sio_out_xor), (@bus.read32(sio(@chip.sio_gpio_out)) ^ value) & mask)

    def check_sio(pin)
      @chip.check_gpio(pin)
      raise "GPIO #{pin}: only GPIO 0-30 are supported" if pin > 30
      pin
    end

    # ---- pad settings
    def set_pulls(pin, up, down)
      v = (up ? PAD_PUE : 0) | (down ? PAD_PDE : 0)
      @bus.write_masked(pad(pin), v, PAD_PUE | PAD_PDE)
    end

    def pull_up(pin) = set_pulls(pin, true, false)
    def pull_down(pin) = set_pulls(pin, false, true)
    def disable_pulls(pin) = set_pulls(pin, false, false)
    def is_pulled_up?(pin) = (@bus.read32(pad(pin)) & PAD_PUE) != 0
    def is_pulled_down?(pin) = (@bus.read32(pad(pin)) & PAD_PDE) != 0

    # Drive strength in mA: 2, 4, 8 or 12
    def set_drive_strength(pin, ma)
      code = case ma
             when 2 then 0
             when 4 then 1
             when 8 then 2
             when 12 then 3
             else raise "drive strength must be 2, 4, 8 or 12 mA (got #{ma})"
             end
      @bus.write_masked(pad(pin), code << PAD_DRIVE_LSB, PAD_DRIVE)
    end

    def get_drive_strength(pin)
      code = (@bus.read32(pad(pin)) & PAD_DRIVE) >> PAD_DRIVE_LSB
      code == 3 ? 12 : 2 << code        # 0 -> 2, 1 -> 4, 2 -> 8, 3 -> 12 mA
    end

    def set_slew_rate(pin, fast) = @bus.write_masked(pad(pin), fast ? PAD_SLEWFAST : 0, PAD_SLEWFAST)
    def set_input_enabled(pin, on) = @bus.write_masked(pad(pin), on ? PAD_IE : 0, PAD_IE)
    def set_input_hysteresis_enabled(pin, on) = @bus.write_masked(pad(pin), on ? PAD_SCHMITT : 0, PAD_SCHMITT)

    # ---- interrupts for core 0 (pico-sdk's gpio_set_irq_enabled / gpio_acknowledge_irq / gpio_get_irq_event_mask).
    # events is a mask of IRQ_*; they reach the NVIC as chip.irq(:io_irq_bank0). Edge events stay set until
    # acknowledged; level events follow the pin
    def set_irq_enabled(pin, events, on)
      a, shift = irq_reg(pin, @chip.gpio_proc0_inte0)
      acknowledge_irq(pin, events) if on                       # forget edges from before, as pico-sdk does
      m = irq_bits(events, shift)
      on ? @bus.set_bits(a, m) : @bus.clear_bits(a, m)
    end

    def acknowledge_irq(pin, events)
      a, shift = irq_reg(pin, @chip.gpio_intr0)
      @bus.write32(a, irq_bits(events, shift))
    end

    # Events enabled and present for core 0
    def get_irq_event_mask(pin)
      a, shift = irq_reg(pin, @chip.gpio_proc0_ints0)
      (@bus.read32(a) >> shift) & 0xF
    end

    # Events present, enabled or not (raw INTR)
    def get_raw_irq_event_mask(pin)
      a, shift = irq_reg(pin, @chip.gpio_intr0)
      (@bus.read32(a) >> shift) & 0xF
    end

    # events << shift as a signed 32-bit Integer: for pins 7, 15, 23 the top event bit is bit 31, and 1 << 31 does not
    # fit in bare-full's Integer
    def irq_bits(events, shift)
      v = (events & 7) << shift
      v |= shift == 28 ? -0x8000_0000 : 8 << shift if (events & 8) != 0
      v
    end

    def irq_reg(pin, base)
      @chip.check_gpio(pin)
      [@chip.io_bank0_base + base + 4 * (pin / 8), 4 * (pin % 8)]
    end
  end
end
