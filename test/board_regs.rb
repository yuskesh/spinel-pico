# Check the register values the board drivers (lib/pico/*) write, using a bus that just records writes.
# Expected values were computed by hand from the RP2040 datasheet bit positions (noted per check)
require_relative "../lib/pico/gpio"
require_relative "../lib/pico/clocks"
require_relative "../lib/pico/timer"
require_relative "../lib/pico/uart"
require_relative "../lib/pico/flash"
require_relative "../lib/pico/pwm"
require_relative "../lib/pico/adc"
require_relative "../lib/pico/spi"
require_relative "../lib/pico/i2c"
require_relative "../lib/pico/dma"
require_relative "fake_bus"

SIO = -0x3000_0000                     # 0xd0000000 as a signed 32-bit Integer
PAD25 = 0x4001_c000 + 4 + 4 * 25       # PADS_BANK0 GPIO25 (datasheet 2.19.6.3)
CTRL25 = 0x4001_4000 + 4 + 8 * 25      # IO_BANK0 GPIO25_CTRL (2.19.6.1)

# ---- GPIO
bus = FakeBus.new
bus.write32(PAD25, 0xd6)               # pad reset value 0x56, plus OD set to see it cleared
gpio = Pico::GPIO.new(bus, Pico::RP2040)
gpio.init(25)
expect("init: SIO GPIO_OE_CLR (0x028) = bit 25", bus.writes_to(SIO + 0x28).last, 1 << 25)
expect("init: SIO GPIO_OUT_CLR (0x018) = bit 25", bus.writes_to(SIO + 0x18).last, 1 << 25)
expect("init: pad OD cleared, IE kept", bus.mem[PAD25], 0x56)
expect("init: GPIO25_CTRL FUNCSEL = 5 (SIO)", bus.mem[CTRL25], 5)
gpio.set_dir(25, true)
expect("set_dir out: GPIO_OE_SET (0x024)", bus.writes_to(SIO + 0x24).last, 1 << 25)
gpio.put(25, true)
expect("put true: GPIO_OUT_SET (0x014)", bus.writes_to(SIO + 0x14).last, 1 << 25)
gpio.xor_mask(1 << 25)
expect("xor_mask: GPIO_OUT_XOR (0x01c)", bus.writes_to(SIO + 0x1c).last, 1 << 25)
bus.write32(SIO + 0x10, 0b0100)        # GPIO_OUT currently has GPIO 2 high
gpio.put_masked(0b1100, 0b1000)        # GPIO 2 -> 0, GPIO 3 -> 1
expect("put_masked: XOR of the bits that change", bus.writes_to(SIO + 0x1c).last, 0b1100)
bus.write32(SIO + 0x04, 1 << 25)
expect("get(25) reads GPIO_IN (0x004)", gpio.get(25) ? 1 : 0, 1)
expect("get(24)", gpio.get(24) ? 1 : 0, 0)

gpio.pull_up(25)
expect("pull_up: PUE set, PDE cleared", bus.mem[PAD25], 0x5a)
expect("is_pulled_up?", gpio.is_pulled_up?(25) ? 1 : 0, 1)
gpio.set_drive_strength(25, 12)
expect("drive 12 mA: DRIVE = 3", bus.mem[PAD25], 0x7a)
expect("get_drive_strength", gpio.get_drive_strength(25), 12)
gpio.set_slew_rate(25, true)
expect("slew fast: SLEWFAST set", bus.mem[PAD25], 0x7b)
gpio.set_input_hysteresis_enabled(25, false)
expect("hysteresis off: SCHMITT cleared", bus.mem[PAD25], 0x79)
gpio.set_input_enabled(25, false)
expect("input off: IE cleared", bus.mem[PAD25], 0x39)
gpio.disable_pulls(25)
expect("disable_pulls", bus.mem[PAD25], 0x31)
gpio.set_function(0, :uart)
expect("GPIO0_CTRL FUNCSEL = 2 (UART)", bus.mem[0x4001_4004], 2)
expect("get_function(0)", gpio.get_function(0), 2)
raises("GPIO 30 does not exist on RP2040") { gpio.put(30, true) }
raises("drive strength 5 mA") { gpio.set_drive_strength(25, 5) }
raises("unknown function") { gpio.set_function(25, :pio2) }

# ---- Clocks. The model answers the status registers the way the hardware would
CLOCKS = 0x4000_8000
PLL_SYS = 0x4002_8000
PLL_USB = 0x4002_c000

class ClockModel < FakeBus
  def read32(a)
    return 0x1FF_FFFF if a == 0x4000_c008                                    # RESET_DONE: all out of reset
    return ((@mem[CLOCKS + 0x3c] || 0) & 1) == 0 ? 1 : 2 if a == CLOCKS + 0x44   # CLK_SYS_SELECTED follows SRC
    return -0x8000_0000 | (@mem[a] || 0) if a == PLL_SYS || a == PLL_USB      # CS: LOCK (bit 31) always set
    return (@mem[a] || 0) | 0x100 if a == 0x4004_c000                         # ADC CS: READY
    return 0x10 if a == CLOCKS + 0x98                                         # FC0_STATUS: DONE
    return 125_000 << 5 if a == CLOCKS + 0x9c                                 # FC0_RESULT: 125000 kHz
    super(a)
  end
end

bus = ClockModel.new
bus.write32(CLOCKS + 0x30, 2)          # bare-full: clk_ref from XOSC, divider 1
bus.write32(CLOCKS + 0x34, 1 << 8)
bus.write32(CLOCKS + 0x40, 1 << 8)     # clk_sys = clk_ref
bus.write32(CLOCKS + 0x48, 0x800)      # clk_peri enabled from clk_sys
bus.write32(PLL_SYS + 4, 0x2d)         # PLLs powered down
bus.write32(PLL_USB + 4, 0x2d)
clocks = Pico::Clocks.new(bus, Pico::RP2040)
expect("bare-full start: clk_sys", clocks.get_hz(:sys), 12_000_000)
expect("bare-full start: clk_peri", clocks.get_hz(:peri), 12_000_000)
expect("bare-full start: pll_sys (powered down)", clocks.get_hz(:pll_sys), 0)
f = clocks.check_sys_clock_khz(125_000)
expect("125 MHz: VCO 1500 MHz", f[0], 1_500_000_000)
expect("125 MHz: postdiv1 6, postdiv2 2", f[1] * 10 + f[2], 62)
f = clocks.check_sys_clock_khz(133_000)
expect("133 MHz: VCO 1596 MHz / 6 / 2", f[0] / 1_000_000 * 100 + f[1] * 10 + f[2], 159662)
f = clocks.check_sys_clock_khz(48_000)
expect("48 MHz: VCO 1440 MHz / 6 / 5", f[0] / 1_000_000 * 100 + f[1] * 10 + f[2], 144065)
expect("12.345 MHz: no PLL setting", clocks.check_sys_clock_khz(12_345).size, 0)
raises("200 MHz is above the limit") { clocks.check_sys_clock_khz(200_000) }
raises("12.345 MHz cannot be made") { clocks.set_sys_clock_khz(12_345) }

clocks.set_sys_clock_khz(125_000)
expect("RESETS: pll_sys (bit 12) reset then released", bus.writes_to(0x4000_c000).size, 2)
expect("PLL_SYS CS: REFDIV 1", bus.mem[PLL_SYS], 1)
expect("PLL_SYS FBDIV_INT 125", bus.mem[PLL_SYS + 8], 125)
expect("PLL_SYS PRIM: POSTDIV1 6, POSTDIV2 2", bus.mem[PLL_SYS + 0xc], (6 << 16) | (2 << 12))
expect("PLL_SYS PWR: PD, VCOPD, POSTDIVPD cleared", bus.mem[PLL_SYS + 4], 0x04)
expect("CLK_SYS_CTRL: AUXSRC pll_sys, SRC aux", bus.mem[CLOCKS + 0x3c], 1)
expect("CLK_SYS_DIV: 1", bus.mem[CLOCKS + 0x40], 1 << 8)
expect("CLK_PERI_CTRL: moved to XOSC (AUXSRC 4), enabled", bus.mem[CLOCKS + 0x48], 0x880)
expect("clk_sys", clocks.get_hz(:sys), 125_000_000)
expect("clk_peri stays at 12 MHz", clocks.get_hz(:peri), 12_000_000)
expect("frequency counter result", clocks.frequency_count_khz(:sys), 125_000)
expect("FC0_REF_KHZ = clk_ref in kHz", bus.mem[CLOCKS + 0x80], 12_000)
expect("FC0_SRC 9 (clk_sys) was used", bus.writes_to(CLOCKS + 0x94)[0], 9)
expect("2.5 divider", Pico::Clocks.divide(125_000_000, 2, 128), 50_000_000)
clocks.set_sys_clock_from_ref
expect("back to clk_ref: clk_sys", clocks.get_hz(:sys), 12_000_000)
expect("PLL powered down again", bus.mem[PLL_SYS + 4], 0x2d)

# ---- Timer (same model bus; clk_ref is 12 MHz)
bus.write32(0x4000_c000, 1 << 21)      # TIMER in reset, as bare-full leaves it
timer = Pico::Timer.new(bus, Pico::RP2040)
expect("TIMER (bit 21) released", bus.mem[0x4000_c000] & (1 << 21), 0)
expect("WATCHDOG TICK: 12 cycles, ENABLE", bus.mem[0x4005_802c], 12 | (1 << 9))
bus.fix(0x4005_4028, 0x10)             # TIMERAWL just after the 31-bit wrap
expect("us_since across the 31-bit wrap", timer.us_since(0x7FFF_FFF0), 0x20)
bus.fix(0x4005_4028, -0x7FFF_FFF0)     # 0x80000010: bit 31 set (reads negative on bare-full)
expect("time_us_31 drops bit 31", timer.time_us_31, 0x10)
raises("negative wait") { timer.busy_wait_us_32(-1) }

# ---- UART (clk_peri is XOSC, 12 MHz)
UART1 = 0x4003_8000
uart = Pico::UART.new(bus, Pico::RP2040, 1)
expect("init(115200) returns the actual rate", uart.init(115_200), 115_107)
expect("RESETS: uart1 (bit 23) reset then released", bus.writes_to(0x4000_c000).last(2).map { |v| v & (1 << 23) }.sum, 1 << 23)
expect("UARTIBRD 6 (12 MHz / 16 / 115200 = 6.51)", bus.mem[UART1 + 0x24], 6)
expect("UARTFBRD 33 (0.51 x 64)", bus.mem[UART1 + 0x28], 33)
expect("UARTLCR_H: 8 bits, FIFOs on", bus.mem[UART1 + 0x2c], 0x70)
expect("UARTCR: UARTEN, TXE, RXE", bus.mem[UART1 + 0x30], 0x301)
expect("9600 baud is exact at 12 MHz", uart.set_baudrate(9600), 9600)
expect("9600: IBRD 78, FBRD 8", bus.mem[UART1 + 0x24] * 100 + bus.mem[UART1 + 0x28], 7808)
expect("UARTCR restored after the change", bus.mem[UART1 + 0x30], 0x301)
uart.set_format(7, 2, :even)
expect("7E2: WLEN 2, STP2, PEN, EPS, FEN kept", bus.mem[UART1 + 0x2c], 0x5e)
uart.set_loopback(true)
expect("loopback: LBE set", bus.mem[UART1 + 0x30], 0x381)
uart.putc_raw(0x1A5)
expect("putc_raw sends the low 8 bits", bus.mem[UART1], 0xA5)
raises("9 data bits") { uart.set_format(9, 1, :none) }
raises("UART 2 does not exist") { Pico::UART.new(bus, Pico::RP2040, 2) }

# ---- Flash, with a ROM stand-in that records what it was asked to do
class FakeROM
  attr_reader :calls
  def initialize
    @calls = []
  end
  def erase(offset, count) = @calls << "erase #{offset.to_s(16)} #{count}"
  def program_page(offset, bytes) = @calls << "program #{offset.to_s(16)} #{bytes.size} first #{bytes[0]} last #{bytes[-1]}"
  def image_end = 0x1005_c470
end

rom = FakeROM.new
flash = Pico::Flash.new(bus, Pico::RP2040, rom)
expect("first free offset: image end rounded up to a sector", flash.first_free_offset, 0x5_d000)
bus.write32(0x1000_0100, 0x2004_2000)
bus.write32(0x1000_0104, 0x1000_01f7)
expect("read_u32 through XIP", flash.read_u32(0x100), 0x2004_2000)
expect("read gives bytes, little-endian", flash.read(0x102, 4).inject(0) { |a, b| a * 256 + b }, 0x0420_f701)
flash.range_erase(0x1F_F000, 4096)
data = []
512.times { |i| data << (i & 0xFF) }
data[256] = 0xAA
flash.range_program(0x1F_F000, data)
expect("ROM calls: one erase, then one call per 256-byte page", rom.calls.size, 3)
puts "  #{rom.calls.join(' / ')}"
expect("second page starts at the right byte", rom.calls[2] == "program 1ff100 256 first 170 last 255" ? 1 : 0, 1)
raises("erase inside the program image") { flash.range_erase(0x5_c000, 4096) }
raises("erase not sector-aligned") { flash.range_erase(0x1F_F100, 4096) }
raises("erase past the end of flash") { flash.range_erase(0x1F_F000, 8192) }
raises("program not page-aligned") { flash.range_program(0x1F_F010, data) }
raises("program a partial page") { flash.range_program(0x1F_F000, [1, 2, 3]) }
raises("program a value that is not a byte") { flash.range_program(0x1F_F000, data.map { |b| b == 0xAA ? 256 : b }) }
expect("refused calls reached the ROM", rom.calls.size, 3)

# ---- PWM (datasheet 4.5.3: slice n at 0x40050000 + 0x14 n)
pwm = Pico::PWM.new(bus, Pico::RP2040)
S4 = 0x4005_0000 + 4 * 0x14
expect("GPIO 25 is slice 4", pwm.gpio_to_slice_num(25), 4)
expect("GPIO 25 is channel B", pwm.gpio_to_channel(25), 1)
pwm.init(4, false)
expect("init: TOP 0xffff", bus.mem[S4 + 0x10], 0xffff)
expect("init: DIV 1.0 (INT at bit 4)", bus.mem[S4 + 4], 0x10)
expect("init: not started", bus.mem[S4], 0)
pwm.set_wrap(4, 99)
pwm.set_gpio_level(25, 30)
expect("level of B in CC bits 31:16", bus.mem[S4 + 0xc], 30 << 16)
pwm.set_chan_level(4, 0, 7)
expect("level of A keeps B", bus.mem[S4 + 0xc], (30 << 16) | 7)
pwm.set_chan_level(4, 1, 0x9000)
expect("B level with bit 31 set (written as halves)", bus.mem[S4 + 0xc], 0x9000_0007)
pwm.set_clkdiv_int_frac(4, 8, 3)
expect("DIV 8 + 3/16", bus.mem[S4 + 4], 0x83)
pwm.set_enabled(4, true)
pwm.set_phase_correct(4, true)
pwm.set_clkdiv_mode(4, :b_rising)
pwm.set_output_polarity(4, true, false)
expect("CSR: EN, PH_CORRECT, A_INV, DIVMODE 2", bus.mem[S4], 0x27)
raises("level 70000") { pwm.set_gpio_level(25, 70_000) }
raises("clkdiv 0") { pwm.set_clkdiv_int_frac(4, 0, 0) }

# ---- ADC (needs clk_adc = 48 MHz from the USB PLL)
adc = Pico::ADC.new(bus, Pico::RP2040)
raises("ADC with clk_sys 12 MHz") { adc.init }
clocks.set_sys_clock_khz(48_000)
adc.init
expect("USB PLL: FBDIV 120 (1440 MHz / 12 MHz)", bus.mem[PLL_USB + 8], 120)
expect("USB PLL: POSTDIV1 6, POSTDIV2 5", bus.mem[PLL_USB + 0xc], (6 << 16) | (5 << 12))
expect("CLK_ADC_CTRL: pll_usb, enabled", bus.mem[CLOCKS + 0x60], 0x800)
expect("clk_adc", Pico::Clocks.new(bus, Pico::RP2040).get_hz(:adc), 48_000_000)
expect("ADC CS: EN", bus.mem[0x4004_c000], 1)
clocks.set_sys_clock_from_ref
adc.select_input(4)
adc.set_temp_sensor_enabled(true)
expect("ADC CS: AINSEL 4, TS_EN, EN", bus.mem[0x4004_c000], (4 << 12) | 3)
bus.fix(0x4004_c004, 800)
expect("read: START_ONCE then RESULT", adc.read, 800)
expect("raw 800 = 644 mV", Pico::ADC.to_mv(800), 644)
expect("raw 800 = 30.6 C (tenths)", Pico::ADC.temp_c10(800), 306)
bus.write32(0x4001_c000 + 4 + 4 * 29, 0x5e)   # GPIO29 pad: IE, pull-up, pull-down set
adc.gpio_init(29)
expect("GPIO29 for ADC: no function (0x1f)", bus.mem[0x4001_4000 + 4 + 8 * 29], 0x1f)
expect("GPIO29 pad: input and pulls off", bus.mem[0x4001_c000 + 4 + 4 * 29] & 0x4c, 0)
raises("GPIO 25 is not an ADC pin") { adc.gpio_init(25) }

# ---- SPI (clk_peri 12 MHz). A bus that returns what was written last models internal loopback
SPI0 = 0x4003_c000
bus.fix(SPI0 + 0xc, 0x6)               # SSPSR: TNF, RNE
spi = Pico::SPI.new(bus, Pico::RP2040, 0)
expect("init(1 MHz) returns the actual rate", spi.init(1_000_000), 1_000_000)
expect("SSPCPSR 2", bus.mem[SPI0 + 0x10], 2)
expect("SSPCR0: SCR 5, 8-bit frames", bus.mem[SPI0], 0x507)
expect("SSPCR1: SSE", bus.mem[SPI0 + 4], 2)
expect("3 MHz: SCR 1", spi.set_baudrate(3_000_000) * 0 + (bus.mem[SPI0] >> 8), 1)
expect("10 kHz: prescale 6, SCR 199", spi.set_baudrate(10_000) + bus.mem[SPI0 + 0x10] * 1000 + (bus.mem[SPI0] >> 8), 10_000 + 6000 + 199)
expect("get_baudrate", spi.get_baudrate, 10_000)
spi.set_format(16, 1, 1)
expect("16 bits, CPOL 1, CPHA 1", bus.mem[SPI0] & 0xff, 0xcf)
expect("write_read_blocking", spi.write_read_blocking([0x1234, 0xBEEF]).inject(0) { |a, b| a * 65_536 + b }, 0x1234_BEEF)
raises("SPI 2 does not exist") { Pico::SPI.new(bus, Pico::RP2040, 2) }

# ---- GPIO overrides
gpio = Pico::GPIO.new(bus, Pico::RP2040)
gpio.set_function(4, :i2c)
gpio.set_oeover(4, :disable)
gpio.set_inover(4, :high)
expect("GPIO4 CTRL: I2C, OE disabled, input high", bus.mem[0x4001_4024], 0x32003)
gpio.set_inover(4, :normal)
expect("GPIO4 CTRL: input override back to normal", bus.mem[0x4001_4024], 0x2003)
raises("OE override :low") { gpio.set_oeover(4, :low) }

# ---- I2C (clk_sys 12 MHz). The model reports TX empty and STOP detected at once, one byte waiting in the RX FIFO
I2C0 = 0x4004_4000
bus.fix(I2C0 + 0x34, 0x210)            # IC_RAW_INTR_STAT: STOP_DET, TX_EMPTY
bus.fix(I2C0 + 0x78, 1)                # IC_RXFLR
i2c = Pico::I2C.new(bus, Pico::RP2040, 0)
expect("init(100 kHz) returns the actual rate", i2c.init(100_000), 100_000)
expect("IC_CON: fast, controller, target off, restart, TX_EMPTY_CTRL", bus.mem[I2C0], 0x165)
expect("SCL high count 48 (period 120 x 2/5)", bus.mem[I2C0 + 0x1c], 48)
expect("SCL low count 72 (period 120 x 3/5)", bus.mem[I2C0 + 0x20], 72)
expect("spike length 72 / 16 = 4", bus.mem[I2C0 + 0xa0], 4)
expect("SDA hold 12 MHz x 3 / 10 MHz + 1 = 4", bus.mem[I2C0 + 0x7c], 4)
expect("IC_ENABLE back on", bus.mem[I2C0 + 0x6c], 1)
expect("400 kHz: actual rate", i2c.set_baudrate(400_000), 400_000)
expect("400 kHz: counts 12 / 18", bus.mem[I2C0 + 0x1c] * 100 + bus.mem[I2C0 + 0x20], 1218)
expect("write 2 bytes returns 2", i2c.write_blocking(0x3c, [0x01, 0x02], true), 2)
expect("IC_TAR 0x3c", bus.mem[I2C0 + 4], 0x3c)
expect("data commands: plain byte, then no STOP (nostop)", bus.writes_to(I2C0 + 0x10).last(2).inject(0) { |a, b| a * 4096 + b }, (0x001 * 4096) + 0x002)
dst = []
expect("read after nostop: 1 byte", i2c.read_blocking(0x3c, dst, 1, false), 1)
expect("read command: RESTART, STOP, READ", bus.writes_to(I2C0 + 0x10).last, 0x700)
bus.fix(I2C0 + 0x80, 1)                # IC_TX_ABRT_SOURCE: address not acknowledged
expect("no device: ERROR_GENERIC", i2c.write_blocking(0x50, [0], false), Pico::I2C::ERROR_GENERIC)
expect("abort reason kept", i2c.last_abort_reason, 1)
raises("reserved address 0x78") { i2c.write_blocking(0x78, [0], false) }
raises("I2C at 1 Hz (SCL counts over 16 bits)") { i2c.set_baudrate(1) }

# ---- DMA
DMA0 = 0x5000_0000
bus.fix(0x4000_c008, 0x1FF_FFFF)       # RESET_DONE
dma = Pico::DMA.new(bus, Pico::RP2040)
expect("claim_unused_channel: 0", dma.claim_unused_channel(true), 0)
expect("claim_unused_channel: 1", dma.claim_unused_channel(true), 1)
dma.channel_unclaim(0)
expect("after unclaim 0: 0 again", dma.claim_unused_channel(true), 0)
raises("claiming a claimed channel") { dma.channel_claim(1) }
11.times { dma.claim_unused_channel(false) if dma.claim_unused_channel(false) < 0 }
expect("all 12 claimed: -1", dma.claim_unused_channel(false), -1)
raises("required with none free") { dma.claim_unused_channel(true) }
cfg = dma.get_default_config(3)
expect("default CTRL: EN, 32-bit, read incr, chain to 3, DREQ force", cfg.ctrl_value(Pico::RP2040.dma_ctrl), 1 | (2 << 2) | (1 << 4) | (3 << 11) | (63 << 15))
cfg.set_transfer_data_size(1)
cfg.set_write_increment(true)
cfg.set_read_increment(false)
cfg.set_dreq(Pico::RP2040.dreq(:spi0_tx))
cfg.set_chain_to(5)
cfg.set_ring(true, 4)
cfg.set_bswap(true)
cfg.set_irq_quiet(true)
cfg.set_high_priority(true)
cfg.set_sniff_enable(true)
expect("CTRL with every field", cfg.ctrl_value(Pico::RP2040.dma_ctrl), 1 | 2 | (0 << 2) | (1 << 5) | (4 << 6) | (1 << 10) | (5 << 11) | (16 << 15) | (1 << 21) | (1 << 22) | (1 << 23))
raises("transfer size 3") { cfg.set_transfer_data_size(3) }
ch = dma.channel(3)
ch.configure(dma.get_default_config(3), 0x2000_1000, 0x2000_0000, 64, false)
CH3 = DMA0 + 3 * 0x40
expect("READ_ADDR", bus.mem[CH3], 0x2000_0000)
expect("WRITE_ADDR", bus.mem[CH3 + 4], 0x2000_1000)
expect("TRANS_COUNT", bus.mem[CH3 + 8], 64)
expect("CTRL written through AL1_CTRL (no trigger)", bus.mem[CH3 + 0x10], dma.get_default_config(3).ctrl_value(Pico::RP2040.dma_ctrl))
ch.configure(dma.get_default_config(3), 0x2000_1000, 0x2000_0000, 64, true)
expect("trigger: CTRL_TRIG", bus.mem[CH3 + 0x0c], dma.get_default_config(3).ctrl_value(Pico::RP2040.dma_ctrl))
ch.set_read_addr(0x2000_0040, true)
expect("set_read_addr trigger: AL3_READ_ADDR_TRIG", bus.mem[CH3 + 0x3c], 0x2000_0040)
ch.start
expect("start: MULTI_CHAN_TRIGGER bit 3", bus.mem[DMA0 + 0x430], 8)
dma.timer_set_fraction(1, 1, 1200)
expect("TIMER1: X 1, Y 1200", bus.mem[DMA0 + 0x424], (1 << 16) | 1200)
expect("timer 2's DREQ", dma.get_timer_dreq(2), 61)
raises("timer fraction above 1") { dma.timer_set_fraction(0, 3, 2) }
dma.sniffer_enable(3, :sum, true)
expect("SNIFF_CTRL: EN, channel 3, sum", bus.mem[DMA0 + 0x434], 1 | (3 << 1) | (0xf << 5))
ch.set_irq0_enabled(true)
ch.set_irq1_enabled(true)
ch.abort
expect("abort: CHAN_ABORT bit 3", bus.mem[DMA0 + 0x444], 8)
expect("abort: spurious flag cleared in INTS0 and INTS1", bus.writes_to(DMA0 + 0x40c).last * 16 + bus.writes_to(DMA0 + 0x41c).last, 8 * 16 + 8)
expect("abort: interrupt enables restored", (bus.mem[DMA0 + 0x404] & 8) + (bus.mem[DMA0 + 0x414] & 8), 16)
raises("DMA channel 12") { dma.channel(12) }

# ---- timer alarms
tbus = ClockModel.new
tbus.write32(CLOCKS + 0x30, 2)         # clk_ref from XOSC, divider 1
tbus.write32(CLOCKS + 0x34, 1 << 8)
tbus.fix(0x4005_802c, 0x60c)           # watchdog tick already running at 12
tm = Pico::Timer.new(tbus, Pico::RP2040)
tbus.fix(0x4005_4028, -0x0000_1000)    # TIMERAWL 0xfffff000: the alarm target wraps past 2^32
tm.alarm_set_in_us(2, 0x2000)
expect("alarm_set_in_us wraps: ALARM2 = 0x00001000", tbus.mem[0x4005_4018], 0x1000)
tbus.fix(0x4005_4028, 0x0001_fff0)
tm.alarm_set_in_us(0, 0x20)
expect("alarm_set_in_us carries into the high half: ALARM0 = 0x00020010", tbus.mem[0x4005_4010], 0x2_0010)
tm.alarm_cancel(3)
expect("alarm_cancel(3): ARMED bit 3", tbus.mem[0x4005_4020], 8)
tm.alarm_acknowledge(1)
expect("alarm_acknowledge(1): INTR bit 1", tbus.mem[0x4005_4034], 2)
tm.alarm_set_irq_enabled(2, true)
expect("alarm_set_irq_enabled(2): INTE bit 2", tbus.mem[0x4005_4038], 4)
raises("alarm 4") { tm.alarm_cancel(4) }

# ---- GPIO interrupts
gbus = FakeBus.new
gp = Pico::GPIO.new(gbus, Pico::RP2040)
gp.set_irq_enabled(25, Pico::GPIO::IRQ_EDGE_RISE | Pico::GPIO::IRQ_EDGE_FALL, true)
expect("GPIO25 edges: PROC0_INTE3 bits 6, 7 (pin 25 = 4 x 1)", gbus.mem[0x4001_410c], 0xc << 4)
expect("set_irq_enabled acknowledges old edges first: INTR3", gbus.mem[0x4001_40fc], 0xc << 4)
gp.set_irq_enabled(15, Pico::GPIO::IRQ_EDGE_RISE | Pico::GPIO::IRQ_LEVEL_LOW, true)
expect("GPIO15 (bit 31 used): PROC0_INTE1", gbus.mem[0x4001_4104], 0x9000_0000)
gbus.fix(0x4001_412c, 0x40)
expect("get_irq_event_mask(25)", gp.get_irq_event_mask(25), 4)
expect("chip.irq(:dma_irq_0)", Pico::RP2040.irq(:dma_irq_0), 11)
expect("chip.irq(:io_irq_bank0)", Pico::RP2040.irq(:io_irq_bank0), 13)

# ---- RP2350: the same drivers with the RP2350 table. The addresses and bits are the ones tools/regs_check.sh checks
# against pico-sdk; nothing here has run on an RP2350
R = Pico::RP2350
RCLOCKS = 0x4001_0000
class Clock2350 < FakeBus
  def read32(a)
    return 0x1FFF_FFFF if a == 0x4002_0008                                   # RESET_DONE
    return 0x10 if a == RCLOCKS + 0xa4                                       # FC0_STATUS: DONE
    return 150_000 << 5 if a == RCLOCKS + 0xa8                               # FC0_RESULT: 150000 kHz
    super(a)
  end
end
rb = Clock2350.new
rb.write32(RCLOCKS + 0x30, 2)          # clk_ref from XOSC, divider 1
rb.write32(RCLOCKS + 0x34, 1 << 8)
rb.write32(RCLOCKS + 0x40, 1 << 8)     # clk_sys = clk_ref
rc = Pico::Clocks.new(rb, R)
expect("RP2350 clk_ref from the 12 MHz crystal", rc.get_hz(:ref), 12_000_000)
expect("RP2350 frequency counter result (FC0 block at 0x8c)", rc.frequency_count_khz(:sys), 150_000)
expect("RP2350 FC0_REF_KHZ at 0x8c", rb.mem[RCLOCKS + 0x8c], 12_000)
expect("RP2350 FC0_SRC at 0xa0 written 9 (clk_sys), then cleared", rb.writes_to(RCLOCKS + 0xa0)[-2], 9)
raises("RP2350 has no clk_rtc to count") { rc.frequency_count_khz(:rtc) }
raises("RP2350 clk_sys above 150 MHz") { rc.check_sys_clock_khz(151_000) }
expect("RP2350 150 MHz: VCO 1500 MHz / 5 / 2", rc.check_sys_clock_khz(150_000)[0], 1_500_000_000)
rt = Pico::Timer.new(rb, R)
expect("RP2350 tick: TICKS TIMER0 CYCLES (0x4010801c) = 12", rb.mem[0x4010_801c], 12)
expect("RP2350 tick: TICKS TIMER0 CTRL (0x40108018) = ENABLE", rb.mem[0x4010_8018], 1)
rb.fix(0x400b_0028, 1000)              # TIMER0 TIMERAWL
rt.alarm_set_in_us(1, 500)
expect("RP2350 ALARM1 at TIMER0 0x14", rb.mem[0x400b_0014], 1500)
rt.alarm_set_irq_enabled(1, true)
expect("RP2350 timer INTE at 0x40", rb.mem[0x400b_0040], 2)
rt.alarm_acknowledge(1)
expect("RP2350 timer INTR at 0x3c", rb.writes_to(0x400b_003c).last, 2)
rg = Pico::GPIO.new(rb, R)
rg.init(25)
expect("RP2350 SIO GPIO_OE_CLR at 0x040", rb.writes_to(SIO + 0x40).last, 1 << 25)
expect("RP2350 GPIO25_CTRL at 0x400280cc = SIO", rb.mem[0x4002_80cc], 5)
rg.set_outover(25, :high)
expect("RP2350 OUTOVER at bit 12", rb.mem[0x4002_80cc], 5 | (3 << 12))
rg.set_irq_enabled(25, Pico::GPIO::IRQ_EDGE_FALL, true)
expect("RP2350 PROC0_INTE3 at 0x254: GPIO 25 edge low", rb.mem[0x4002_8000 + 0x248 + 12], 4 << 4)
expect("RP2350 INTR3 at 0x23c: the event acknowledged first", rb.writes_to(0x4002_8000 + 0x230 + 12).last, 4 << 4)
rd = Pico::DMA.new(rb, R)
cfg = rd.get_default_config(13)
cfg.set_dreq(R.dreq(:pio2_tx0))
cfg.set_write_increment(true)
expect("RP2350 DMA CTRL: EN, 32-bit, read incr (4), write incr (6), chain to 13 (13), TREQ 16 (17)", cfg.ctrl_value(R.dma_ctrl),
       1 | (2 << 2) | (1 << 4) | (1 << 6) | (13 << 13) | (16 << 17))
rd.channel(13).configure(cfg, 0x2000_1000, 0x2000_0000, 8, true)
expect("RP2350 DMA CH13 CTRL_TRIG at 0x34c", rb.mem[0x5000_0000 + 0x40 * 13 + 0x0c], cfg.ctrl_value(R.dma_ctrl))
rd.timer_set_fraction(1, 1, 1200)
expect("RP2350 DMA TIMER1 at 0x444", rb.mem[0x5000_0444], (1 << 16) | 1200)
rd.channel(15).start
expect("RP2350 MULTI_CHAN_TRIGGER at 0x450", rb.mem[0x5000_0450], 1 << 15)
raises("RP2350 DMA transfer count 2^28") { rd.channel(0).set_trans_count(0x1000_0000, false) }
raises("RP2350 DMA channel 16") { rd.channel(16) }
rp = Pico::PWM.new(rb, R)
rp.set_mask_enabled(1 << 11)
expect("RP2350 PWM EN at 0xf0 (12 slices)", rb.mem[0x400a_80f0], 1 << 11)
ra = Pico::ADC.new(rb, R)
rb.write32(0x400a_0000, 0xf000)
expect("RP2350 ADC AINSEL is 4 bits", ra.get_selected_input, 15)
expect("RP2350 chip.irq(:io_irq_bank0)", R.irq(:io_irq_bank0), 21)
expect("RP2350 chip.dreq(:adc)", R.dreq(:adc), 48)

puts($fail == 0 ? "board: all passed" : "board: #{$fail} mismatches")
exit($fail == 0 ? 0 : 1)
