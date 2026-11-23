# Clocks and the system PLL (names follow pico-sdk's hardware_clocks and hardware_pll). RP2040 only for now.
# Clocks are symbols: :ref, :sys, :peri (generators) and :xosc, :pll_sys, :pll_usb (sources).
#
# Frequencies are worked out from the registers each time (get_hz), not remembered, so separate Clocks objects
# always agree. The crystal is chip.xosc_hz (12 MHz on the Pico). The ring oscillator and the GPIN inputs have no
# known frequency; get_hz returns 0 for clocks that run from them (measure them with frequency_count_khz).
#
# bare-full starts with clk_ref = clk_sys = XOSC (12 MHz) and clk_peri = clk_sys. Changing clk_sys moves clk_peri to
# XOSC first so the UART console keeps its baud rate. Note that bare-full's clock_gettime (Process.clock_gettime,
# sleep) counts SysTick at a fixed 12 MHz, so it runs fast after clk_sys changes; use Pico::Timer for time instead.
require_relative "chip"
require_relative "resets"

module Pico
  class Clocks
    # CLOCKS registers (RP2040 datasheet 2.15.7)
    CLK_REF_CTRL = 0x30
    CLK_REF_DIV = 0x34
    CLK_REF_SELECTED = 0x38
    CLK_SYS_CTRL = 0x3c
    CLK_SYS_DIV = 0x40
    CLK_SYS_SELECTED = 0x44
    CLK_PERI_CTRL = 0x48
    CLK_PERI_SELECTED = 0x50
    FC0_REF_KHZ = 0x80
    FC0_MIN_KHZ = 0x84
    FC0_MAX_KHZ = 0x88
    FC0_INTERVAL = 0x90
    FC0_SRC = 0x94
    FC0_STATUS = 0x98
    FC0_RESULT = 0x9c
    CTRL_ENABLE = 1 << 11
    CTRL_AUXSRC = 7 << 5
    FC0_STATUS_DONE = 1 << 4
    FC0_STATUS_RUNNING = 1 << 8

    # PLL registers (2.18.4)
    PLL_CS = 0x0
    PLL_PWR = 0x4
    PLL_FBDIV_INT = 0x8
    PLL_PRIM = 0xc
    PLL_CS_BYPASS = 1 << 8
    PLL_PWR_PD = 1 << 0
    PLL_PWR_POSTDIVPD = 1 << 3
    PLL_PWR_VCOPD = 1 << 5
    PLL_PWR_ALL = 0x2d               # reset value: everything powered down

    # Limits (2.18.2; pico-sdk PICO_PLL_VCO_MIN/MAX_FREQ_HZ) and the highest clk_sys at the default core voltage
    VCO_MIN_HZ = 750_000_000
    VCO_MAX_HZ = 1_600_000_000

    # UART registers used to wait for the transmitters to go idle before a clock switch
    UART_FR = 0x18
    UART_CR = 0x30
    UART_FR_BUSY = 1 << 3

    def initialize(bus, chip)
      @bus = bus
      @chip = chip
      @resets = Resets.new(bus, chip)
    end

    def reg(off) = @chip.clocks_base + off

    # a frequency counter register given by its RP2040 offset (the block sits at Chip#fc0_ref_khz)
    def fc0(off) = reg(@chip.fc0_ref_khz + off - FC0_REF_KHZ)

    # ---- frequencies
    def get_hz(clk)
      case clk
      when :xosc then @chip.xosc_hz
      when :pll_sys then pll_hz(@chip.pll_sys_base)
      when :pll_usb then pll_hz(@chip.pll_usb_base)
      when :ref then ref_hz
      when :sys then sys_hz
      when :peri then peri_hz
      when :usb then usb_adc_hz(@chip.clk_usb_ctrl, @chip.clk_usb_ctrl + 4)
      when :adc then usb_adc_hz(@chip.clk_adc_ctrl, @chip.clk_adc_ctrl + 4)
      else raise "unknown clock #{clk}"
      end
    end

    def ref_hz
      ctrl = @bus.read32(reg(CLK_REF_CTRL))
      src = case ctrl & 3
            when 2 then @chip.xosc_hz
            when 1 then ((ctrl >> 5) & 3) == 0 ? pll_hz(@chip.pll_usb_base) : 0
            else 0                                   # ring oscillator: frequency not known
            end
      div = (@bus.read32(reg(CLK_REF_DIV)) >> 8) & 3
      src / (div == 0 ? 4 : div)
    end

    def sys_hz
      ctrl = @bus.read32(reg(CLK_SYS_CTRL))
      src = (ctrl & 1) == 0 ? ref_hz : aux_hz((ctrl >> 5) & 7, [:pll_sys, :pll_usb, :rosc, :xosc, :gpin, :gpin])
      div = @bus.read32(reg(CLK_SYS_DIV))
      int = (div >> 8) & 0xFF_FFFF
      Clocks.divide(src, int == 0 ? 1 << 24 : int, div & 0xFF)
    end

    def peri_hz
      ctrl = @bus.read32(reg(CLK_PERI_CTRL))
      return 0 if (ctrl & CTRL_ENABLE) == 0
      aux_hz((ctrl >> 5) & 7, [:sys, :pll_sys, :pll_usb, :rosc, :xosc, :gpin, :gpin])
    end

    def usb_adc_hz(ctrl_off, div_off)
      ctrl = @bus.read32(reg(ctrl_off))
      return 0 if (ctrl & CTRL_ENABLE) == 0
      src = aux_hz((ctrl >> 5) & 7, [:pll_usb, :pll_sys, :rosc, :xosc, :gpin, :gpin])
      div = (@bus.read32(reg(div_off)) >> 8) & 3
      src / (div == 0 ? 4 : div)
    end

    def aux_hz(code, table)
      return 0 if code >= table.size
      src = table[code]
      return 0 if src == :rosc || src == :gpin
      get_hz(src)
    end

    def pll_hz(base)
      return 0 if (@bus.read32(base + PLL_PWR) & PLL_PWR_PD) != 0
      cs = @bus.read32(base + PLL_CS)
      return 0 if (cs & 0x3f) == 0                             # REFDIV 0 is undefined: treat as not running
      ref = @chip.xosc_hz / (cs & 0x3f)
      return ref if (cs & PLL_CS_BYPASS) != 0
      fbdiv = @bus.read32(base + PLL_FBDIV_INT) & 0xfff
      raise "PLL VCO #{ref}Hz x #{fbdiv} does not fit in 32 bits" if fbdiv > 0x7FFF_FFFF / ref
      prim = @bus.read32(base + PLL_PRIM)
      ref * fbdiv / (((prim >> 16) & 7) * ((prim >> 12) & 7))
    end

    # src / (int + frac/256), rounded down, without overflowing 32 bits
    def self.divide(src, int, frac)
      return src / int if frac == 0
      d = int * 256 + frac
      raise "divider #{int} + #{frac}/256 is too large" if int >= 1 << 22
      q = src / d
      r = src % d
      8.times do
        q <<= 1
        r <<= 1
        if r >= d
          r -= d
          q += 1
        end
      end
      q
    end

    # Measure a clock with the frequency counter, in kHz (pico-sdk's frequency_count_khz). Independent of the
    # register settings, so it checks them. src: :pll_sys, :pll_usb, :rosc, :xosc, :ref, :sys, :peri, :usb, :adc, :rtc
    def frequency_count_khz(src)
      code = case src
             when :pll_sys then 1
             when :pll_usb then 2
             when :rosc then 3
             when :xosc then 5
             when :ref then 8
             when :sys then 9
             when :peri then 10
             when :usb then 11
             when :adc then 12
             when :rtc then @chip.rp2040? ? 13 : -1
             else raise "frequency counter cannot measure #{src}"
             end
      raise "#{@chip.name} has no #{src} clock" if code < 0
      while (@bus.read32(fc0(FC0_STATUS)) & FC0_STATUS_RUNNING) != 0
      end
      @bus.write32(fc0(FC0_REF_KHZ), ref_hz / 1000)
      @bus.write32(fc0(FC0_INTERVAL), 10)
      @bus.write32(fc0(FC0_MIN_KHZ), 0)
      @bus.write32(fc0(FC0_MAX_KHZ), 0x1FF_FFFF)
      @bus.write32(fc0(FC0_SRC), code)
      n = 0
      while (@bus.read32(fc0(FC0_STATUS)) & FC0_STATUS_DONE) == 0
        n += 1
        raise "frequency counter did not finish (is #{src} running?)" if n > 1_000_000
      end
      khz = (@bus.read32(fc0(FC0_RESULT)) >> 5) & 0x1FF_FFFF
      @bus.write32(fc0(FC0_SRC), 0)
      khz
    end

    # ---- the system clock
    # Find PLL settings for clk_sys = khz kHz: [vco_hz, postdiv1, postdiv2], or [] if there are none
    # (pico-sdk's check_sys_clock_khz: highest VCO first, then the largest postdiv1)
    def check_sys_clock_khz(khz)
      raise "clk_sys #{khz} kHz is above #{@chip.sys_max_hz / 1000} kHz (needs a higher core voltage)" if khz > @chip.sys_max_hz / 1000
      hz = khz * 1000
      ref = @chip.xosc_hz
      fbdiv = VCO_MAX_HZ / ref
      while fbdiv >= 16
        vco = fbdiv * ref
        if vco >= VCO_MIN_HZ
          pd1 = 7
          while pd1 >= 1
            pd2 = pd1
            while pd2 >= 1
              d = pd1 * pd2
              return [vco, pd1, pd2] if vco % d == 0 && vco / d == hz
              pd2 -= 1
            end
            pd1 -= 1
          end
        end
        fbdiv -= 1
      end
      []
    end

    # Run clk_sys from the system PLL at khz kHz (pico-sdk's set_sys_clock_khz with required = true)
    def set_sys_clock_khz(khz)
      found = check_sys_clock_khz(khz)
      raise "clk_sys #{khz} kHz cannot be made from #{@chip.xosc_hz / 1000} kHz with the PLL" if found.empty?
      set_sys_clock_pll(found[0], found[1], found[2])
    end

    # Run clk_sys from the system PLL at vco_hz / (postdiv1 * postdiv2) (pico-sdk's set_sys_clock_pll)
    def set_sys_clock_pll(vco_hz, postdiv1, postdiv2)
      out = vco_hz / (postdiv1 * postdiv2)
      raise "clk_sys #{out}Hz is above #{@chip.sys_max_hz}Hz" if out > @chip.sys_max_hz
      keep_peri_on_xosc
      sys_from_ref
      pll_init(:sys, 1, vco_hz, postdiv1, postdiv2)
      @bus.write32(reg(CLK_SYS_DIV), 1 << 8)
      @bus.write_masked(reg(CLK_SYS_CTRL), 0, CTRL_AUXSRC)     # AUXSRC 0: pll_sys
      @bus.set_bits(reg(CLK_SYS_CTRL), 1)                      # SRC 1: aux (glitchless)
      wait_selected(CLK_SYS_SELECTED, 2)
    end

    # Run clk_sys straight from clk_ref (the crystal under bare-full) and power the system PLL down
    def set_sys_clock_from_ref
      keep_peri_on_xosc
      sys_from_ref
      @bus.write32(reg(CLK_SYS_DIV), 1 << 8)
      pll_deinit(:sys)
    end

    def sys_from_ref
      @bus.clear_bits(reg(CLK_SYS_CTRL), 1)
      wait_selected(CLK_SYS_SELECTED, 1)
    end

    # clk_peri source: :sys, :pll_sys, :pll_usb or :xosc. clk_peri has no glitchless switch, so it is stopped
    # while the source changes, after the UARTs have finished sending
    def set_peri_source(src)
      code = case src
             when :sys then 0
             when :pll_sys then 1
             when :pll_usb then 2
             when :xosc then 4
             else raise "clk_peri cannot run from #{src}"
             end
      wait_uarts_idle
      @bus.clear_bits(reg(CLK_PERI_CTRL), CTRL_ENABLE)
      3.times { @bus.read32(reg(CLK_PERI_CTRL)) }              # a few cycles of the old clock to stop cleanly
      @bus.write_masked(reg(CLK_PERI_CTRL), code << 5, CTRL_AUXSRC)
      @bus.set_bits(reg(CLK_PERI_CTRL), CTRL_ENABLE)
    end

    # The fixed 48 MHz clocks: run the USB PLL at 1440 MHz / 6 / 5 (as pico-sdk does) and clk_usb and clk_adc from it.
    # Does nothing for a clock that already runs at 48 MHz. clk: :usb or :adc (both share the PLL)
    USB_ADC_HZ = 48_000_000

    def init_48mhz(clk)
      return if get_hz(clk) == USB_ADC_HZ
      pll_init(:usb, 1, 1_440_000_000, 6, 5) unless get_hz(:pll_usb) == USB_ADC_HZ
      ctrl = clk == :usb ? @chip.clk_usb_ctrl : @chip.clk_adc_ctrl
      div = ctrl + 4
      @bus.clear_bits(reg(ctrl), CTRL_ENABLE)
      3.times { @bus.read32(reg(ctrl)) }
      @bus.write32(reg(div), 1 << 8)
      @bus.write_masked(reg(ctrl), 0, CTRL_AUXSRC)             # AUXSRC 0: pll_usb
      @bus.set_bits(reg(ctrl), CTRL_ENABLE)
    end

    def keep_peri_on_xosc
      ctrl = @bus.read32(reg(CLK_PERI_CTRL))
      set_peri_source(:xosc) if (ctrl & CTRL_ENABLE) != 0 && (ctrl & CTRL_AUXSRC) == 0
    end

    def wait_uarts_idle
      done = @bus.read32(@chip.resets_base + RESETS_DONE)
      @chip.uart_bases.each_with_index do |base, i|
        next if (done & (1 << @chip.reset_bit(i == 0 ? :uart0 : :uart1))) == 0   # in reset: do not touch
        next if (@bus.read32(base + UART_CR) & 1) == 0                            # not enabled
        while (@bus.read32(base + UART_FR) & UART_FR_BUSY) != 0
        end
      end
    end

    def wait_selected(off, want)
      n = 0
      while @bus.read32(reg(off)) != want
        n += 1
        raise "clock switch did not complete" if n > 1_000_000
      end
    end

    # ---- PLLs (pico-sdk's pll_init / pll_deinit). pll: :sys or :usb
    def pll_base(pll) = pll == :usb ? @chip.pll_usb_base : @chip.pll_sys_base

    def pll_init(pll, refdiv, vco_hz, postdiv1, postdiv2)
      ref = @chip.xosc_hz / refdiv
      raise "VCO #{vco_hz}Hz is outside #{VCO_MIN_HZ}-#{VCO_MAX_HZ}Hz" unless vco_hz.between?(VCO_MIN_HZ, VCO_MAX_HZ)
      raise "VCO #{vco_hz}Hz is not a multiple of the #{ref}Hz reference" unless vco_hz % ref == 0
      fbdiv = vco_hz / ref
      raise "feedback divider #{fbdiv} is outside 16-320" unless fbdiv.between?(16, 320)
      raise "post dividers must be 1-7" unless postdiv1.between?(1, 7) && postdiv2.between?(1, 7)
      base = pll_base(pll)
      name = pll == :usb ? :pll_usb : :pll_sys
      @resets.reset_unreset_block_wait([name])
      @bus.write32(base + PLL_CS, refdiv)
      @bus.write32(base + PLL_FBDIV_INT, fbdiv)
      @bus.clear_bits(base + PLL_PWR, PLL_PWR_PD | PLL_PWR_VCOPD)
      n = 0
      while @bus.read32(base + PLL_CS) >= 0                    # LOCK is bit 31: reads as a negative Integer
        n += 1
        raise "PLL did not lock" if n > 1_000_000
      end
      @bus.write32(base + PLL_PRIM, (postdiv1 << 16) | (postdiv2 << 12))
      @bus.clear_bits(base + PLL_PWR, PLL_PWR_POSTDIVPD)
    end

    def pll_deinit(pll) = @bus.write32(pll_base(pll) + PLL_PWR, PLL_PWR_ALL)
  end
end
