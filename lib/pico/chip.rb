# Port data: per-chip addresses and numbers. The procedures (GPIO, Resets, PIO, ...) are chip-independent and read
# everything chip-specific from here.
# Values from pico-sdk 2.3.1 src/<chip>/hardware_regs/include/hardware/regs (addressmap.h, resets.h, io_bank0.h,
# sio.h, pads_bank0.h), checked against the RP2040 datasheet (sections 2.3.1.2, 2.14, 2.19)
module Pico
  # Register offsets that are the same on RP2040 and RP2350
  XOR_ALIAS = 0x1000               # atomic XOR alias: flips the written bits (APB/AHB peripherals, not SIO)
  SET_ALIAS = 0x2000               # atomic set alias: sets the written bits
  CLR_ALIAS = 0x3000               # atomic clear alias: clears the written bits
  RESETS_RESET = 0x0
  RESETS_DONE = 0x8

  class Chip
    attr_accessor :name, :num_gpio, :pio_version, :xosc_hz,
                  :resets_base, :io_bank0_base, :pads_bank0_base, :sio_base, :clocks_base, :xosc_base,
                  :pll_sys_base, :pll_usb_base, :watchdog_base, :timer_base, :xip_base, :flash_size,
                  :uart_bases, :pio_bases, :spi_bases, :i2c_bases, :pwm_base, :num_pwm_slices, :adc_base, :adc_first_gpio,
                  :adc_temp_channel, :dma_base, :num_dma_channels, :dreqs, :irqs,
                  :reset_bits, :funcsel,
                  :sio_gpio_in, :sio_gpio_out, :sio_out_set, :sio_out_clr, :sio_out_xor,
                  :sio_gpio_oe, :sio_oe_set, :sio_oe_clr, :sio_oe_xor,
                  :pads_iso, :gpio_intr0, :gpio_proc0_inte0, :gpio_proc0_ints0,
                  :tick_base, :tick_ctrl, :tick_enable, :tick_running, :timer_intr, :timer_inte,
                  :dma_ctrl, :timer_reset, :pwm_en, :pwm_intr, :pwm_inte, :pio_intr, :pio_irq0_inte, :pio_irq_sources,
                  :gpio_outover_lsb, :gpio_oeover_lsb, :clk_usb_ctrl, :clk_adc_ctrl, :fc0_ref_khz, :sys_max_hz,
                  :dma_timer0, :dma_multi_chan_trigger, :dma_sniff_ctrl, :dma_chan_abort, :adc_ainsel, :adc_rrobin,
                  :usbctrl_dpram_base, :usbctrl_regs_base, :pio_status_sel_lsb, :pio_status_n_max

    def initialize(name)
      @name = name
    end

    def rp2040? = @name == "RP2040"

    # RESETS bit for a block name (:pio0, :uart1, ...)
    def reset_bit(block)
      bit = @reset_bits[block]
      raise "#{@name} has no reset bit for #{block}" if bit.nil?
      bit
    end

    def reset_mask(blocks)
      m = 0
      blocks.each { |b| m |= 1 << reset_bit(b) }
      m
    end

    # GPIOn_CTRL FUNCSEL for a function name (:sio, :uart, :pio0, ...)
    def function_number(fn)
      n = @funcsel[fn]
      raise "#{@name} has no GPIO function #{fn}" if n.nil?
      n
    end

    # DMA DREQ number for a pacing signal (:pio0_tx0, :spi0_rx, :uart1_tx, :pwm_wrap3, :adc, :dma_timer0, :force, ...)
    def dreq(name)
      n = @dreqs[name]
      raise "#{@name} has no DREQ #{name}" if n.nil?
      n
    end

    # Interrupt number (:timer_irq_0, :pwm_irq_wrap, :pio0_irq_0, :dma_irq_0, :io_irq_bank0, :uart1_irq, ...)
    def irq(name)
      n = @irqs[name]
      raise "#{@name} has no interrupt #{name}" if n.nil?
      n
    end

    def check_gpio(pin)
      raise "#{@name} GPIO must be 0-#{@num_gpio - 1}" unless pin.between?(0, @num_gpio - 1)
    end

    def self.rp2040
      c = Chip.new("RP2040")
      c.num_gpio = 30
      c.pio_version = 0
      c.xosc_hz = 12_000_000                  # the Pico's crystal
      c.resets_base = 0x4000_c000
      c.io_bank0_base = 0x4001_4000
      c.pads_bank0_base = 0x4001_c000
      c.sio_base = -0x3000_0000                # 0xd0000000 as a signed 32-bit Integer (bare-full Integers are 32-bit)
      c.clocks_base = 0x4000_8000
      c.xosc_base = 0x4002_4000
      c.pll_sys_base = 0x4002_8000
      c.pll_usb_base = 0x4002_c000
      c.watchdog_base = 0x4005_8000
      c.timer_base = 0x4005_4000
      c.xip_base = 0x1000_0000
      c.flash_size = 2 * 1024 * 1024          # the Pico's W25Q16
      c.uart_bases = [0x4003_4000, 0x4003_8000]
      c.pio_bases = [0x5020_0000, 0x5030_0000]
      c.spi_bases = [0x4003_c000, 0x4004_0000]
      c.i2c_bases = [0x4004_4000, 0x4004_8000]
      c.pwm_base = 0x4005_0000
      c.num_pwm_slices = 8
      c.adc_base = 0x4004_c000
      c.adc_first_gpio = 26                   # ADC inputs 0-3 are GPIO 26-29
      c.adc_temp_channel = 4                  # the on-chip temperature sensor
      c.dma_base = 0x5000_0000
      c.num_dma_channels = 12
      c.dreqs = { pio0_tx0: 0, pio0_tx1: 1, pio0_tx2: 2, pio0_tx3: 3, pio0_rx0: 4, pio0_rx1: 5, pio0_rx2: 6, pio0_rx3: 7,
                  pio1_tx0: 8, pio1_tx1: 9, pio1_tx2: 10, pio1_tx3: 11, pio1_rx0: 12, pio1_rx1: 13, pio1_rx2: 14,
                  pio1_rx3: 15, spi0_tx: 16, spi0_rx: 17, spi1_tx: 18, spi1_rx: 19, uart0_tx: 20, uart0_rx: 21,
                  uart1_tx: 22, uart1_rx: 23, pwm_wrap0: 24, pwm_wrap1: 25, pwm_wrap2: 26, pwm_wrap3: 27,
                  pwm_wrap4: 28, pwm_wrap5: 29, pwm_wrap6: 30, pwm_wrap7: 31, i2c0_tx: 32, i2c0_rx: 33, i2c1_tx: 34,
                  i2c1_rx: 35, adc: 36, xip_stream: 37, xip_ssitx: 38, xip_ssirx: 39,
                  dma_timer0: 59, dma_timer1: 60, dma_timer2: 61, dma_timer3: 62, force: 63 }   # dreq.h
      c.irqs = { timer_irq_0: 0, timer_irq_1: 1, timer_irq_2: 2, timer_irq_3: 3, pwm_irq_wrap: 4, usbctrl_irq: 5,
                 xip_irq: 6, pio0_irq_0: 7, pio0_irq_1: 8, pio1_irq_0: 9, pio1_irq_1: 10, dma_irq_0: 11, dma_irq_1: 12,
                 io_irq_bank0: 13, io_irq_qspi: 14, sio_irq_proc0: 15, sio_irq_proc1: 16, clocks_irq: 17,
                 spi0_irq: 18, spi1_irq: 19, uart0_irq: 20, uart1_irq: 21, adc_irq_fifo: 22, i2c0_irq: 23,
                 i2c1_irq: 24, rtc_irq: 25 }                                          # intctrl.h
      c.reset_bits = { adc: 0, busctrl: 1, dma: 2, i2c0: 3, i2c1: 4, io_bank0: 5, io_qspi: 6, jtag: 7,
                       pads_bank0: 8, pads_qspi: 9, pio0: 10, pio1: 11, pll_sys: 12, pll_usb: 13, pwm: 14,
                       rtc: 15, spi0: 16, spi1: 17, syscfg: 18, sysinfo: 19, tbman: 20, timer: 21,
                       uart0: 22, uart1: 23, usbctrl: 24 }
      c.funcsel = { xip: 0, spi: 1, uart: 2, i2c: 3, pwm: 4, sio: 5, pio0: 6, pio1: 7, gpck: 8, usb: 9,
                    null: 0x1f }
      c.sio_gpio_in = 0x004
      c.sio_gpio_out = 0x010
      c.sio_out_set = 0x014
      c.sio_out_clr = 0x018
      c.sio_out_xor = 0x01c
      c.sio_gpio_oe = 0x020
      c.sio_oe_set = 0x024
      c.sio_oe_clr = 0x028
      c.sio_oe_xor = 0x02c
      c.pads_iso = false                      # RP2350 pads have an isolation latch (bit 8); RP2040 pads do not
      c.gpio_intr0 = 0x0f0                    # IO_BANK0 interrupt registers (offsets)
      c.gpio_proc0_inte0 = 0x100
      c.gpio_proc0_ints0 = 0x120
      c.tick_base = c.watchdog_base           # the 1 us tick for the TIMER: WATCHDOG_TICK (cycles and enable in one register)
      c.tick_ctrl = 0x2c
      c.tick_enable = 1 << 9
      c.tick_running = 1 << 10
      c.timer_reset = :timer
      c.timer_intr = 0x34
      c.timer_inte = 0x38
      # DMA CTRL field positions (LSB)
      c.dma_ctrl = { en: 0, high_priority: 1, data_size: 2, incr_read: 4, incr_write: 5, ring_size: 6, ring_sel: 10,
                     chain_to: 11, treq_sel: 15, irq_quiet: 21, bswap: 22, sniff_en: 23, busy: 24 }
      c.pwm_en = 0xa0
      c.pwm_intr = 0xa4
      c.pwm_inte = 0xa8
      c.pio_intr = 0x128
      c.pio_irq0_inte = 0x12c
      c.pio_irq_sources = 12                  # INTR bits: RX not empty x4, TX not full x4, IRQ flags 0-3
      c.gpio_outover_lsb = 8                  # GPIOn_CTRL fields
      c.gpio_oeover_lsb = 12
      c.clk_usb_ctrl = 0x54                   # CLOCKS (each DIV is 4 after its CTRL; FC0 registers follow FC0_REF_KHZ)
      c.clk_adc_ctrl = 0x60
      c.fc0_ref_khz = 0x80
      c.sys_max_hz = 133_000_000
      c.dma_timer0 = 0x420                    # DMA registers after the channels (SNIFF_DATA is 4 after SNIFF_CTRL)
      c.dma_multi_chan_trigger = 0x430
      c.dma_sniff_ctrl = 0x434
      c.dma_chan_abort = 0x444
      c.adc_ainsel = 7 << 12                  # ADC CS fields
      c.adc_rrobin = 0x1f << 16
      c.usbctrl_dpram_base = 0x5010_0000
      c.usbctrl_regs_base = 0x5011_0000
      c.pio_status_sel_lsb = 4                # EXECCTRL STATUS_SEL (1 bit: TX / RX level), STATUS_N below it
      c.pio_status_n_max = 15
      c
    end

    # RP2350A (30 GPIOs, as on the Pico 2), Arm cores. Values from pico-sdk 2.3.1 src/rp2350 hardware_regs, checked by
    # tools/regs_check.sh. Nothing here has run on an RP2350 yet: bare-full has no RP2350 chip family
    def self.rp2350
      c = Chip.new("RP2350")
      c.num_gpio = 30
      c.pio_version = 1
      c.xosc_hz = 12_000_000                  # the Pico 2's crystal
      c.resets_base = 0x4002_0000
      c.io_bank0_base = 0x4002_8000
      c.pads_bank0_base = 0x4003_8000
      c.sio_base = -0x3000_0000                # 0xd0000000
      c.clocks_base = 0x4001_0000
      c.xosc_base = 0x4004_8000
      c.pll_sys_base = 0x4005_0000
      c.pll_usb_base = 0x4005_8000
      c.watchdog_base = 0x400d_8000
      c.timer_base = 0x400b_0000              # TIMER0
      c.xip_base = 0x1000_0000
      c.flash_size = 4 * 1024 * 1024          # the Pico 2's W25Q32
      c.uart_bases = [0x4007_0000, 0x4007_8000]
      c.pio_bases = [0x5020_0000, 0x5030_0000, 0x5040_0000]
      c.spi_bases = [0x4008_0000, 0x4008_8000]
      c.i2c_bases = [0x4009_0000, 0x4009_8000]
      c.pwm_base = 0x400a_8000
      c.num_pwm_slices = 12
      c.adc_base = 0x400a_0000
      c.adc_first_gpio = 26
      c.adc_temp_channel = 4
      c.dma_base = 0x5000_0000
      c.num_dma_channels = 16
      c.dreqs = { pio0_tx0: 0, pio0_tx1: 1, pio0_tx2: 2, pio0_tx3: 3, pio0_rx0: 4, pio0_rx1: 5, pio0_rx2: 6, pio0_rx3: 7,
                  pio1_tx0: 8, pio1_tx1: 9, pio1_tx2: 10, pio1_tx3: 11, pio1_rx0: 12, pio1_rx1: 13, pio1_rx2: 14,
                  pio1_rx3: 15, pio2_tx0: 16, pio2_tx1: 17, pio2_tx2: 18, pio2_tx3: 19, pio2_rx0: 20, pio2_rx1: 21,
                  pio2_rx2: 22, pio2_rx3: 23, spi0_tx: 24, spi0_rx: 25, spi1_tx: 26, spi1_rx: 27, uart0_tx: 28,
                  uart0_rx: 29, uart1_tx: 30, uart1_rx: 31, pwm_wrap0: 32, pwm_wrap1: 33, pwm_wrap2: 34, pwm_wrap3: 35,
                  pwm_wrap4: 36, pwm_wrap5: 37, pwm_wrap6: 38, pwm_wrap7: 39, pwm_wrap8: 40, pwm_wrap9: 41,
                  pwm_wrap10: 42, pwm_wrap11: 43, i2c0_tx: 44, i2c0_rx: 45, i2c1_tx: 46, i2c1_rx: 47, adc: 48,
                  xip_stream: 49, xip_qmitx: 50, xip_qmirx: 51, hstx: 52, coresight: 53, sha256: 54,
                  dma_timer0: 59, dma_timer1: 60, dma_timer2: 61, dma_timer3: 62, force: 63 }
      c.irqs = { timer0_irq_0: 0, timer0_irq_1: 1, timer0_irq_2: 2, timer0_irq_3: 3, timer1_irq_0: 4, timer1_irq_1: 5,
                 timer1_irq_2: 6, timer1_irq_3: 7, pwm_irq_wrap_0: 8, pwm_irq_wrap_1: 9, dma_irq_0: 10, dma_irq_1: 11,
                 dma_irq_2: 12, dma_irq_3: 13, usbctrl_irq: 14, pio0_irq_0: 15, pio0_irq_1: 16, pio1_irq_0: 17,
                 pio1_irq_1: 18, pio2_irq_0: 19, pio2_irq_1: 20, io_irq_bank0: 21, io_irq_bank0_ns: 22,
                 io_irq_qspi: 23, io_irq_qspi_ns: 24, sio_irq_fifo: 25, sio_irq_bell: 26, sio_irq_fifo_ns: 27,
                 sio_irq_bell_ns: 28, sio_irq_mtimecmp: 29, clocks_irq: 30, spi0_irq: 31, spi1_irq: 32,
                 uart0_irq: 33, uart1_irq: 34, adc_irq_fifo: 35, i2c0_irq: 36, i2c1_irq: 37, otp_irq: 38,
                 trng_irq: 39, proc0_irq_cti: 40, proc1_irq_cti: 41, pll_sys_irq: 42, pll_usb_irq: 43,
                 powman_irq_pow: 44, powman_irq_timer: 45 }                         # intctrl.h
      c.reset_bits = { adc: 0, busctrl: 1, dma: 2, hstx: 3, i2c0: 4, i2c1: 5, io_bank0: 6, io_qspi: 7, jtag: 8,
                       pads_bank0: 9, pads_qspi: 10, pio0: 11, pio1: 12, pio2: 13, pll_sys: 14, pll_usb: 15,
                       pwm: 16, sha256: 17, spi0: 18, spi1: 19, syscfg: 20, sysinfo: 21, tbman: 22, timer0: 23,
                       timer1: 24, trng: 25, uart0: 26, uart1: 27, usbctrl: 28 }
      c.funcsel = { hstx: 0, spi: 1, uart: 2, i2c: 3, pwm: 4, sio: 5, pio0: 6, pio1: 7, pio2: 8, gpck: 9,
                    xip_cs1: 9, coresight_trace: 9, usb: 10, uart_aux: 11, null: 0x1f }
      c.sio_gpio_in = 0x004
      c.sio_gpio_out = 0x010
      c.sio_out_set = 0x018
      c.sio_out_clr = 0x020
      c.sio_out_xor = 0x028
      c.sio_gpio_oe = 0x030
      c.sio_oe_set = 0x038
      c.sio_oe_clr = 0x040
      c.sio_oe_xor = 0x048
      c.pads_iso = true
      c.gpio_intr0 = 0x230
      c.gpio_proc0_inte0 = 0x248
      c.gpio_proc0_ints0 = 0x278
      c.tick_base = 0x4010_8000               # TICKS block: TIMER0's tick has its own CTRL and CYCLES registers
      c.tick_ctrl = 0x18
      c.tick_enable = 1 << 0
      c.tick_running = 1 << 1
      c.timer_reset = :timer0
      c.timer_intr = 0x3c
      c.timer_inte = 0x40
      c.dma_ctrl = { en: 0, high_priority: 1, data_size: 2, incr_read: 4, incr_write: 6, ring_size: 8, ring_sel: 12,
                     chain_to: 13, treq_sel: 17, irq_quiet: 23, bswap: 24, sniff_en: 25, busy: 26 }
      c.pwm_en = 0xf0
      c.pwm_intr = 0xf4
      c.pwm_inte = 0xf8
      c.pio_intr = 0x16c
      c.pio_irq0_inte = 0x170
      c.pio_irq_sources = 16                  # IRQ flags 0-7
      c.gpio_outover_lsb = 12
      c.gpio_oeover_lsb = 14
      c.clk_usb_ctrl = 0x60
      c.clk_adc_ctrl = 0x6c
      c.fc0_ref_khz = 0x8c
      c.sys_max_hz = 150_000_000
      c.dma_timer0 = 0x440
      c.dma_multi_chan_trigger = 0x450
      c.dma_sniff_ctrl = 0x454
      c.dma_chan_abort = 0x464
      c.adc_ainsel = 0xf << 12
      c.adc_rrobin = 0x1ff << 16
      c.usbctrl_dpram_base = 0x5010_0000
      c.usbctrl_regs_base = 0x5011_0000
      c.pio_status_sel_lsb = 5                # 2 bits: TX level, RX level, IRQ flag
      c.pio_status_n_max = 31
      c
    end
  end

  RP2040 = Chip.rp2040
  RP2350 = Chip.rp2350
end
