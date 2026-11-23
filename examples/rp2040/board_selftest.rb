# Board driver selftest on an RP2040 Pico under bare-full: each check prints PASS or FAIL, and the program exits 1
# if any check failed. Run with tools/rp2040_selftest.sh board. Uses the on-board LED pin (GPIO 25), and GPIO 4 and 5 for I2C only if nothing is attached to them
# and the UART0 console; nothing needs to be wired.
require_relative "../../lib/pico"
require_relative "selftest_programs"

$fails = 0
def check(what, ok)
  puts "#{ok ? 'PASS' : 'FAIL'} #{what}"
  $fails += 1 unless ok
end

pico = Pico.rp2040

# ---- GPIO
g = pico.gpio
led = 25
g.init(led)
check("GPIO25 function is SIO (5)", g.get_function(led) == 5)
g.set_dir(led, true)
check("GPIO25 is an output", g.is_dir_out?(led))
g.put(led, true)
check("GPIO25 driven high reads high", g.get(led))
g.put(led, false)
check("GPIO25 driven low reads low", !g.get(led))
g.xor_mask(1 << led)
check("xor_mask flips GPIO25 to high", g.get(led) && g.get_out_level(led))
g.put(led, false)
g.set_dir(led, false)
g.pull_down(led)
check("GPIO25 as input with pull-down reads low", !g.get(led))
check("pad reads back pull-down only", g.is_pulled_down?(led) && !g.is_pulled_up?(led))
g.set_drive_strength(led, 8)
check("drive strength reads back 8 mA", g.get_drive_strength(led) == 8)
g.set_drive_strength(led, 4)

# ---- Timer: checked against SysTick
t = pico.timer
t.busy_wait_us_32(1000)                     # the same call once to warm the flash cache (a cold miss costs ~30 us at 12 MHz)
a = t.time_us_31
t.busy_wait_us_32(1000)
d = t.us_since(a)
# Never short. How far over depends on how long one time round the loop takes, and at clk_sys 12 MHz (flash read at
# 3 MHz) that depends on where the loop and the functions it calls land in flash: the same code measured 1047 us in
# one build and 1282 us in another, both after a warm-up, while a small program measured 1033 us. So the bound here
# is loose; the 125 MHz check under Clocks below is the tight one
check("busy_wait_us_32(1000) took #{d} us at clk_sys 12 MHz", d >= 1000 && d < 1500)
6.times do                                  # blink the LED: 6 x 50 ms
  g.xor_mask(1 << led)
  t.busy_wait_ms(50)
end

# SysTick counts core (clk_sys) cycles and the timer counts XOSC microseconds, so cycles per microsecond over the
# same span is clk_sys in MHz. SysTick is 24 bits and wraps every 2^24 cycles: the 100 ms span stays under 2^24 cycles
# up to 167 MHz. Read the raw registers: an allocation in between could run the GC.
# Older bare-full builds run SysTick for clock_gettime (with its wrap interrupt); newer ones use the TIMER and leave
# SysTick off. Start it only if it is off, so a running one keeps its interrupt
SYST_CSR = -0x1FFF_1FF0                     # 0xE000E010 as a signed 32-bit Integer
SYST_RVR = -0x1FFF_1FEC                     # 0xE000E014
SYST_CVR = -0x1FFF_1FE8                     # 0xE000E018
if (pico.bus.read32(SYST_CSR) & 1) == 0
  pico.bus.write32(SYST_RVR, 0xFF_FFFF)
  pico.bus.write32(SYST_CVR, 0)
  pico.bus.write32(SYST_CSR, 5)             # enable, core clock, no interrupt
end
def span(bus, t, ms)
  c0 = bus.read32(SYST_CVR)
  a = t.time_us_31
  t.busy_wait_ms(ms)
  c1 = bus.read32(SYST_CVR)
  us = t.us_since(a)
  [(c0 - c1) & 0xFF_FFFF, us]
end

# Two spans, subtracted, so the fixed cost of reading the two counters cancels out
def core_khz(bus, t)
  short = span(bus, t, 20)
  long = span(bus, t, 100)
  cyc = long[0] - short[0]
  us = long[1] - short[1]
  cyc / us * 1000 + (cyc % us) * 1000 / us
end
# median of 3: a GC pause between a counter read and the timer read shifts one measurement
def core_khz3(bus, t)
  ks = []
  3.times { ks << core_khz(bus, t) }
  ks.sort[1]
end
core_khz(pico.bus, t)                       # once to warm the flash cache (a cold miss costs ~30 us at 12 MHz)
k = core_khz3(pico.bus, t)
check("SysTick cycles per timer microsecond: #{k} kHz (clk_sys 12 MHz)", (k - 12_000).abs <= 15)

# ---- Clocks: the frequency counter measures independently of the register settings
def near(khz, want) = (khz - want).abs <= want / 1000 + 2

c = pico.clocks
check("start: clk_sys reads 12 MHz", c.get_hz(:sys) == 12_000_000)
k = c.frequency_count_khz(:sys)
check("start: frequency counter clk_sys #{k} kHz", near(k, 12_000))
[125_000, 48_000, 133_000].each do |khz|
  c.set_sys_clock_khz(khz)
  hz = c.get_hz(:sys)
  ks = c.frequency_count_khz(:sys)
  kp = c.frequency_count_khz(:pll_sys)
  kr = c.frequency_count_khz(:peri)
  check("#{khz} kHz: clk_sys reads #{hz}Hz", hz == khz * 1000)
  check("#{khz} kHz: counter clk_sys #{ks} kHz, pll_sys #{kp} kHz", near(ks, khz) && near(kp, khz))
  check("#{khz} kHz: clk_peri stays at 12 MHz (counter #{kr} kHz)", near(kr, 12_000) && c.get_hz(:peri) == 12_000_000)
  core_khz(pico.bus, t)
  k = core_khz3(pico.bus, t)
  check("#{khz} kHz: SysTick cycles per timer microsecond #{k} kHz", (k - khz).abs <= khz / 1000 + 2)
  if khz == 125_000
    t.busy_wait_us_32(1000)                 # warm up
    a = t.time_us_31
    t.busy_wait_us_32(1000)
    d = t.us_since(a)
    check("125000 kHz: busy_wait_us_32(1000) took #{d} us", d >= 1000 && d <= 1030)
  end
end
c.set_sys_clock_from_ref
k = c.frequency_count_khz(:sys)
check("back on clk_ref: clk_sys #{c.get_hz(:sys)}Hz, counter #{k} kHz", c.get_hz(:sys) == 12_000_000 && near(k, 12_000))

# ---- UART: UART1 in internal loopback (no pins), then UART0 (the console) re-initialised by the driver
u = pico.uart(1)
baud = u.init(115_200)
check("UART1 init(115200) gives #{baud} baud", baud == 115_107)
u.set_loopback(true)
t.busy_wait_us_32(200)                      # let a break that was being received finish (one character is 87 us)
dropped = u.drain_rx
puts "  (dropped #{dropped} byte(s) received from the unrouted RX before loopback)"
sent = [0x55, 0x00, 0xFF, 0x0A, 0x41]
sent.each { |b| u.putc_raw(b) }
got = []
sent.size.times { got << u.getc_timeout(t, 10_000) }
check("UART1 loopback returns #{got.inspect}", got == sent)
check("UART1 RX FIFO empty afterwards", !u.is_readable?)
c.set_sys_clock_khz(125_000)
u.set_baudrate(115_200)
u.putc_raw(0x3C)
r = u.getc_timeout(t, 10_000)
check("UART1 loopback at clk_sys 125 MHz returns #{r}", r == 0x3C)
u.deinit
u0 = pico.uart(0)
baud = u0.init(115_200)
u0.puts("(this line was sent by Pico::UART on UART0)")
check("UART0 re-initialised at #{baud} baud; the console still works", baud == 115_107)
c.set_sys_clock_from_ref

# ---- Flash: XIP reads, then erase / program / read back in the last sector (never used by the program)
fl = pico.flash
puts "  program image ends at flash offset #{fl.image_end_offset}; first free sector at #{fl.first_free_offset}"
check("XIP read: vector table initial SP is 0x20042000", fl.read_u32(0x100) == 0x2004_2000)
last = fl.size - Pico::Flash::SECTOR_SIZE
pattern = []
256.times { |i| pattern << ((i * 7 + 3) & 0xFF) }
pattern2 = []
256.times { |i| pattern2 << (255 - i) }
[12_000, 125_000].each do |khz|
  if khz == 12_000
    c.set_sys_clock_from_ref
  else
    c.set_sys_clock_khz(khz)
  end
  fl.range_erase(last, Pico::Flash::SECTOR_SIZE)
  check("#{khz} kHz: erased sector reads all 0xFF", fl.read(last, 512).all? { |b| b == 0xFF })
  fl.range_program(last, pattern)
  check("#{khz} kHz: programmed page reads back", fl.read(last, 256) == pattern)
  fl.range_program(last + 256, pattern2)
  check("#{khz} kHz: second page reads back, first unchanged",
        fl.read(last + 256, 256) == pattern2 && fl.read(last, 256) == pattern)
  fl.range_erase(last, Pico::Flash::SECTOR_SIZE)
  check("#{khz} kHz: erased again", fl.read(last, 512).all? { |b| b == 0xFF })
end
c.set_sys_clock_from_ref
begin
  fl.range_erase(0, Pico::Flash::SECTOR_SIZE)
  check("erasing the program's own flash is refused", false)
rescue => e
  check("erasing the program's own flash is refused (#{e.message})", true)
end

# ---- PWM on the LED pin (slice 4, channel B), widths measured by two PIO state machines (programs from
# selftest_programs.rb). The samplers count one per 2 cycles: High count = cycles / 2, Low count = cycles / 2 - 1
pw = pico.pwm
slice = pw.gpio_to_slice_num(led)
pw.init(slice, false)
pw.set_wrap(slice, 99)                      # period 100 counts
pw.set_gpio_level(led, 30)                  # high for 30 of them
pw.set_clkdiv_int_frac(slice, 8, 0)         # 1 count = 8 cycles: high 240, low 560 cycles
g.set_function(led, :pwm)
pio = pico.pio(0)
pio.reset!
h = pio.add_program(SAMPLE_HIGH)
l = pio.add_program(SAMPLE_LOW)
# (one call per SM: an Array mixing Integers and Programs would make Spinel use its polymorphic value type)
def start_sampler(pio, n, off, prog, pin)
  cfg = prog.default_config(off)
  cfg.set_jmp_pin(pin)
  cfg.set_fifo_join(:rx)
  pio.sm(n).init(off, cfg)
end
start_sampler(pio, 1, h, SAMPLE_HIGH, led)
start_sampler(pio, 2, l, SAMPLE_LOW, led)
pw.set_enabled(slice, true)
pio.enable_in_sync([pio.sm(1), pio.sm(2)])
highs = []
lows = []
4.times { highs << pio.sm(1).get }
4.times { lows << pio.sm(2).get }
check("PWM high 240 cycles: counts #{highs.inspect}", highs.all? { |x| (x - 120).abs <= 1 })
check("PWM low 560 cycles: counts #{lows.inspect}", lows.all? { |x| (x - 279).abs <= 1 })
check("PWM counter runs below the wrap", pw.get_counter(slice) <= 99)
pw.clear_irq(slice)
t.busy_wait_us_32(200)
check("PWM wrap flag set again after clearing", (pw.get_irq_status_mask & (1 << slice)) != 0)
pio.reset!
pw.set_enabled(slice, false)
g.init(led)

# ---- PIO IRQ flags, interrupt sources, FIFO debug flags and pins, with instructions given to SM 3 by exec
# while it runs a two-instruction loop (nop; jmp back) slowly (clkdiv 1000), so that a stop shows as a pc that no
# longer moves
LOOP2 = Pico::PIO::Program.new("loop2", [0xa042, 0x0000], -1, 0, 1, 0, false, false, nil, nil, false, nil, nil, false, 0, 0, 0, -1, nil, 0)
def pc_moves?(sm, t)
  first = sm.get_pc
  8.times do
    t.busy_wait_us_32(50)
    return true if sm.get_pc != first
  end
  false
end
pio = pico.pio(0)
pio.reset!
off = pio.add_program(LOOP2)
s3 = pio.sm(3)
cfg = LOOP2.default_config(off)
cfg.set_clkdiv_int_frac(1000, 0)
s3.init(off, cfg)
s3.set_enabled(true)
check("PIO SM3 runs its loop (pc moves, at #{s3.get_pc}, offset #{off})", pc_moves?(s3, t))
pio.interrupt_force(5)
check("PIO IRQ flag 5 set by interrupt_force", pio.interrupt_get(5))
pio.interrupt_clear(5)
check("PIO IRQ flag 5 cleared by interrupt_clear", !pio.interrupt_get(5))
pio.set_irq0_source_enabled(Pico::PIO::PIS_INTERRUPT0 + 2, true)
s3.exec(Pico::PIO::Encode.irq_wait(false, 2))        # irq wait 2: sets flag 2, then waits until it is cleared
t.busy_wait_us_32(20)
check("PIO irq wait 2 by exec: flag 2 set and the SM stops", pio.interrupt_get(2) && !pc_moves?(s3, t))
# The datasheet says an exec'd instruction that stalls shows in EXECCTRL EXEC_STALLED; on an RP2040 Pico it does for
# wait, not for irq wait (exec_wait_blocking therefore does not wait for an irq wait)
check("PIO irq wait 2 by exec: EXEC_STALLED reads 0 (RP2040 behaviour)", !s3.is_exec_stalled?)
check("PIO flag 2 shows in INTR (0x#{pio.intr.to_s(16)}) and IRQ0 INTS (0x#{pio.ints(0).to_s(16)})",
      (pio.intr & 0x400) != 0 && (pio.ints(0) & 0x400) != 0)
check("PIO IRQ1 INTS does not show the flag (not enabled there)", (pio.ints(1) & 0x400) == 0)
pio.interrupt_clear(2)
t.busy_wait_us_32(20)
check("PIO clearing flag 2 releases the SM", !pio.interrupt_get(2) && pc_moves?(s3, t))
pio.set_irq0_source_enabled(Pico::PIO::PIS_INTERRUPT0 + 2, false)
s3.exec(Pico::PIO::Encode.wait_irq(true, false, 6))  # wait 1 irq 6
t.busy_wait_us_32(10)
stalled = s3.is_exec_stalled?
pio.interrupt_force(6)
t.busy_wait_us_32(10)
check("PIO wait 1 irq 6 stalls (EXEC_STALLED) until the CPU sets flag 6, then clears it",
      stalled && !s3.is_exec_stalled? && !pio.interrupt_get(6) && pc_moves?(s3, t))
pio.interrupt_force(1)
s3.exec_wait_blocking(Pico::PIO::Encode.wait_irq(true, false, 1))
check("PIO exec_wait_blocking returns once wait 1 irq 1 has finished", !s3.is_exec_stalled? && !pio.interrupt_get(1))

# FIFO debug flags with SM 3 stopped: a fifth word into the 4-deep TX FIFO overflows, reading the empty RX FIFO
# underflows; drain_tx_fifo empties the TX FIFO
s3.set_enabled(false)
pio.clear_fdebug(-1)
5.times { |i| pico.bus.write32(pio.base + 0x010 + 4 * 3, i) }
check("PIO TX FIFO full after 4 words, overflow flag for SM3 (fdebug 0x#{pio.fdebug.to_s(16)})",
      s3.tx_full? && (pio.fdebug & (1 << 19)) != 0)
s3.drain_tx_fifo
check("PIO drain_tx_fifo empties it", s3.tx_empty? && s3.tx_level == 0)
pico.bus.read32(pio.base + 0x020 + 4 * 3)
check("PIO reading the empty RX FIFO sets the underflow flag", (pio.fdebug & (1 << 11)) != 0)
pio.clear_fdebug(-1)
check("PIO clear_fdebug clears the flags", pio.fdebug == 0)

# Pins: drive the LED pin from SM 3 with set_pindirs_with_mask / set_pins_with_mask / set_pins
pio.gpio_init(led)
s3.set_pindirs_with_mask(1 << led, 1 << led)
s3.set_pins_with_mask(1 << led, 1 << led)
high = g.get(led)
s3.set_pins_with_mask(0, 1 << led)
low = !g.get(led)
s3.set_pins(1 << led)
high2 = g.get(led)
s3.set_pins(0)
check("PIO set_pins_with_mask / set_pins drive GPIO 25 high, low, high, low", high && low && high2 && !g.get(led))
s3.set_pindirs_with_mask(0, 1 << led)
pio.reset!
g.init(led)

# ---- ADC: temperature sensor and VSYS / 3 on GPIO 29; clk_adc measured by the frequency counter
ad = pico.adc
begin
  ad.init
  check("ADC init at clk_sys 12 MHz is refused", false)
rescue => e
  check("ADC init at clk_sys 12 MHz is refused (#{e.message})", true)
end
c.set_sys_clock_khz(125_000)                # the ADC registers need clk_sys >= clk_adc (48 MHz)
ad.init
k = c.frequency_count_khz(:adc)
check("clk_adc 48 MHz from the USB PLL: counter #{k} kHz", near(k, 48_000))
ad.set_temp_sensor_enabled(true)
ad.select_input(4)
raw = ad.read
tc = Pico::ADC.temp_c10(raw)
check("temperature sensor: raw #{raw} = #{tc / 10}.#{tc % 10} C", tc.between?(50, 500))
ad.gpio_init(29)
ad.select_input(3)
raw = ad.read
vsys = Pico::ADC.to_mv(raw) * 3
check("VSYS / 3 on GPIO 29: raw #{raw} = VSYS #{vsys} mV", vsys.between?(1800, 5500))
check("ADC input 3 is selected", ad.get_selected_input == 3)
c.set_sys_clock_from_ref

# ---- SPI: SPI0 in internal loopback (no pins); the time for 10 bytes at 10 kHz checks the divider
sp = pico.spi(0)
rate = sp.init(1_000_000)
check("SPI0 init(1 MHz) gives #{rate} Hz", rate == 1_000_000)
sp.set_loopback(true)
back = sp.write_read_blocking([0x00, 0xA5, 0xFF, 0x3C])
check("SPI0 loopback returns #{back.inspect}", back == [0x00, 0xA5, 0xFF, 0x3C])
sp.set_format(16, 1, 1)
back = sp.write_read_blocking([0x1234, 0xBEEF])
check("SPI0 16-bit frames, mode 3: #{back.inspect}", back == [0x1234, 0xBEEF])
# The bit rate: in mode 3 (CPHA 1) frames follow each other with no gap as long as the TX FIFO is never empty, and
# write_blocking keeps it topped up (a byte takes 800 us at 10 kHz). The software around the transfer costs hundreds
# of us at clk_sys 12 MHz (code runs from flash read at 3 MHz), so time 32 bytes at 5 kHz and at 10 kHz with clk_sys
# 125 MHz (clk_peri stays 12 MHz) and compare: 256 bits x (200 - 100 us) = 25600 us. What is left is the delay in
# noticing the last frame, up to one time round the loop at each rate
sp.set_format(8, 1, 1)
c.set_sys_clock_khz(125_000)
# Shortest of 3 transfers (a GC pause can land in one)
def time_32_bytes(sp, t, baud)
  sp.set_baudrate(baud)
  frames = []
  32.times { |i| frames << i }
  best = 1_000_000
  3.times do
    a = t.time_us_31
    sp.write_blocking(frames)
    d = t.us_since(a)
    best = d if d < best
  end
  best
end
time_32_bytes(sp, t, 10_000)                # warm up
d5 = time_32_bytes(sp, t, 5_000)
d10 = time_32_bytes(sp, t, 10_000)
check("32 bytes: #{d5} us at 5 kHz, #{d10} us at 10 kHz, difference #{d5 - d10} us (25600)", (d5 - d10 - 25_600).abs <= 300)
c.set_sys_clock_from_ref
sp.deinit

# ---- DMA: memory to memory, ring, chain, paced by a DMA timer, SPI0 loopback, sniffer, abort (clk_sys 12 MHz)
dma = pico.dma
src = Pico::RAMBuffer.new(1024, 64)          # aligned for the ring below
dst = Pico::RAMBuffer.new(1024, 64)
256.times { |i| src.write32(4 * i, i * 1000 + 7) }
ca = dma.claim_unused_channel(true)
cb = dma.claim_unused_channel(true)
cha = dma.channel(ca)
chb = dma.channel(cb)
def same_words?(a, b, n)
  n.times { |i| return false if a.read32(4 * i) != b.read32(4 * i) }
  true
end
def clear_buf(b, n) = n.times { |i| b.write32(4 * i, 0) }

cf = dma.get_default_config(ca)
cf.set_write_increment(true)
cf.set_sniff_enable(true)
cha.set_irq0_enabled(true)
dma.sniffer_enable(ca, :sum, false)
dma.sniffer_set_data_accumulator(0)
cha.configure(cf, dst.addr, src.addr, 256, true)
cha.wait_for_finish_blocking
sum = 0
256.times { |i| sum += i * 1000 + 7 }
check("DMA copies 256 words memory to memory (left #{cha.get_trans_count})", same_words?(src, dst, 256) && cha.get_trans_count == 0)
check("DMA sniffer sum #{dma.sniffer_get_data_accumulator} (#{sum})", dma.sniffer_get_data_accumulator == sum)
check("DMA completion flag in INTS0 (0x#{dma.irqn_get_status(0).to_s(16)})", cha.get_irq0_status)
cha.acknowledge_irq0
check("DMA acknowledge_irq0 clears it", !cha.get_irq0_status)
cha.set_irq0_enabled(false)
dma.sniffer_enable(ca, :xor, false)
dma.sniffer_set_data_accumulator(0)
cha.configure(cf, dst.addr, src.addr, 256, true)
cha.wait_for_finish_blocking
# :xor is a reduction to one bit: 1 if the data hold an odd number of 1 bits
x = 0
256.times { |i| x ^= i * 1000 + 7 }
parity = 0
32.times { |i| parity ^= (x >> i) & 1 }
check("DMA sniffer xor (parity of all bits) #{dma.sniffer_get_data_accumulator} (#{parity})", dma.sniffer_get_data_accumulator == parity)
dma.sniffer_disable

# bytes, and bswap on words
clear_buf(dst, 4)
cf = dma.get_default_config(ca)
cf.set_write_increment(true)
cf.set_transfer_data_size(1)
src.write32(0, 0x04030201)
cha.configure(cf, dst.addr + 1, src.addr, 3, true)
cha.wait_for_finish_blocking
check("DMA 3 bytes to an odd address: word 0x#{dst.read32(0).to_s(16)} (0x03020100)", dst.read32(0) == 0x03020100)
cf = dma.get_default_config(ca)
cf.set_write_increment(true)
cf.set_bswap(true)
cha.configure(cf, dst.addr, src.addr, 1, true)
cha.wait_for_finish_blocking
check("DMA bswap: 0x04030201 arrives as 0x#{dst.read32(0).to_s(16)}", dst.read32(0) == 0x01020304)
src.write32(0, 7)

# read ring of 16 bytes (4 words, the buffer is aligned) over 12 transfers
clear_buf(dst, 12)
cf = dma.get_default_config(ca)
cf.set_write_increment(true)
cf.set_ring(false, 4)
cha.configure(cf, dst.addr, src.addr, 12, true)
cha.wait_for_finish_blocking
ring_ok = true
12.times { |i| ring_ok = false if dst.read32(4 * i) != src.read32(4 * (i % 4)) }
check("DMA read ring of 4 words repeats them over 12 transfers", ring_ok)

# chain: A copies words 0-7, then starts B, which copies words 8-15
clear_buf(dst, 16)
cf = dma.get_default_config(ca)
cf.set_write_increment(true)
cf.set_chain_to(cb)
cfb = dma.get_default_config(cb)
cfb.set_write_increment(true)
chb.configure(cfb, dst.addr + 32, src.addr + 32, 8, false)
cha.configure(cf, dst.addr, src.addr, 8, true)
chb.wait_for_finish_blocking
cha.wait_for_finish_blocking
check("DMA chain: B ran after A (16 words copied)", same_words?(src, dst, 16))

# paced by DMA timer 0 at 12 MHz x 1 / 1200 = 10 kHz. configure is done first without starting (at clk_sys 12 MHz
# it takes about 0.5 ms warm, several ms the first time); noticing the finish costs up to one polling loop (about
# 100 us here) whatever the count, so 1000 transfers take 900 x 100 us = 90000 us longer than 100. The writes all go
# to one word
cf = dma.get_default_config(ca)
cf.set_dreq(dma.get_timer_dreq(0))
dma.timer_set_fraction(0, 1, 1200)
def time_paced(cha, cf, dst, src, n, t)
  cha.configure(cf, dst.addr, src.addr, n, false)
  a = t.time_us_31
  cha.start
  cha.wait_for_finish_blocking
  t.us_since(a)
end
time_paced(cha, cf, dst, src, 10, t)        # warm up
# the shortest of 3 each: a GC pause or a slow pass of the polling loop only ever adds time
def paced_min(cha, cf, dst, src, n, t)
  best = time_paced(cha, cf, dst, src, n, t)
  2.times do
    v = time_paced(cha, cf, dst, src, n, t)
    best = v if v < best
  end
  best
end
p100 = paced_min(cha, cf, dst, src, 100, t)
p1000 = paced_min(cha, cf, dst, src, 1000, t)
check("DMA paced at 10 kHz: 100 transfers #{p100} us, 1000 transfers #{p1000} us (shortest of 3), difference #{p1000 - p100} us (90000)",
      (p1000 - p100 - 90_000).abs <= 300)

# abort a paced transfer early (1 kHz, 1000 transfers). After an abort TRANS_COUNT reads 0, so the progress is taken
# from the write address
cf.set_write_increment(true)
dma.timer_set_fraction(0, 1, 12_000)
cha.set_irq0_enabled(true)
cha.configure(cf, dst.addr, src.addr, 1000, false)
cha.start
t.busy_wait_ms(20)
cha.abort
done = (cha.get_write_addr - dst.addr) / 4
t.busy_wait_ms(10)
check("DMA abort stops a running channel after #{done} of 1000 transfers, no completion flag",
      !cha.is_busy? && done > 10 && done < 100 && (cha.get_write_addr - dst.addr) / 4 == done && !cha.get_irq0_status)
cha.set_irq0_enabled(false)

# SPI0 internal loopback through DMA: TX channel paced by spi0_tx, RX channel by spi0_rx, 64 bytes at 1 MHz
sp = pico.spi(0)
sp.init(1_000_000)
sp.set_loopback(true)
64.times { |i| src.write8(i, (i * 37 + 11) & 0xFF) }
clear_buf(dst, 16)
dr = sp.dr_addr
tx = dma.get_default_config(ca)
tx.set_transfer_data_size(1)
tx.set_dreq(Pico::RP2040.dreq(:spi0_tx))
rx = dma.get_default_config(cb)
rx.set_transfer_data_size(1)
rx.set_read_increment(false)
rx.set_write_increment(true)
rx.set_dreq(Pico::RP2040.dreq(:spi0_rx))
chb.configure(rx, dst.addr, dr, 64, true)
cha.configure(tx, dr, src.addr, 64, true)
chb.wait_for_finish_blocking
spi_ok = true
64.times { |i| spi_ok = false if dst.read8(i) != src.read8(i) }
check("DMA through SPI0 loopback: 64 bytes sent and received unchanged", spi_ok)
sp.deinit

# UART1 internal loopback through DMA: 16 bytes at 115200 baud, paced by uart1_tx / uart1_rx
u = pico.uart(1)
u.init(115_200)
u.set_loopback(true)
t.busy_wait_us_32(200)
u.drain_rx
clear_buf(dst, 16)
tx = dma.get_default_config(ca)
tx.set_transfer_data_size(1)
tx.set_dreq(Pico::RP2040.dreq(:uart1_tx))
rx = dma.get_default_config(cb)
rx.set_transfer_data_size(1)
rx.set_read_increment(false)
rx.set_write_increment(true)
rx.set_dreq(Pico::RP2040.dreq(:uart1_rx))
chb.configure(rx, dst.addr, u.dr_addr, 16, true)
cha.configure(tx, u.dr_addr, src.addr, 16, true)
chb.wait_for_finish_blocking
uart_ok = true
16.times { |i| uart_ok = false if dst.read8(i) != src.read8(i) }
check("DMA through UART1 loopback: 16 bytes sent and received unchanged", uart_ok)
u.deinit
dma.channel_unclaim(ca)
dma.channel_unclaim(cb)
src.free
dst.free

# ---- interrupts: timer alarm with WFI, timeout, a source left asserted, software pending, DMA completion, GPIO edges
irq_t = Pico::RP2040.irq(:timer_irq_0)
t.alarm_acknowledge(0)
t.alarm_set_irq_enabled(0, true)
Pico::IRQ.set_enabled(irq_t, true)
n0 = Pico::IRQ.count(irq_t)
best = 1_000_000
3.times do
  a = t.time_us_31
  t.alarm_set_target(0, a + 3000)               # a is far from 2^31 here: the program started seconds ago
  Pico::IRQ.wait_for_interrupt
  w = t.us_since(a)
  best = w if w < best && Pico::IRQ.fired?(irq_t)
  t.alarm_acknowledge(0)
  Pico::IRQ.acknowledge(irq_t)
end
check("IRQ timer alarm wakes WFI after #{best} us (3000), fired 3 times",
      best >= 3000 && best <= 3300 && Pico::IRQ.count(irq_t) - n0 == 3)   # never early; reading the time after the wake
                                                                          # costs 20-110 us at 12 MHz (flash cache misses)
check("IRQ acknowledge clears fired and switches the line on", !Pico::IRQ.fired?(irq_t) && Pico::IRQ.line_on?(irq_t))
t.alarm_set_in_us(0, 2000)
r1 = Pico::IRQ.wait(irq_t, t, 20_000)
t.alarm_acknowledge(0)
Pico::IRQ.acknowledge(irq_t)
a = t.time_us_31
r2 = Pico::IRQ.wait(irq_t, t, 3000)
w = t.us_since(a)
check("IRQ.wait sees the alarm, and times out after #{w} us when none comes", r1 && !r2 && w >= 3000 && w < 4000)
t.alarm_set_in_us(0, 3000)                     # at clk_sys 12 MHz the call itself takes about 1 ms
t.busy_wait_ms(6)
n1 = Pico::IRQ.count(irq_t)
Pico::IRQ.acknowledge(irq_t)                     # the alarm flag is still set: it fires again at once
n2 = Pico::IRQ.count(irq_t)
t.alarm_acknowledge(0)
Pico::IRQ.acknowledge(irq_t)
n3 = Pico::IRQ.count(irq_t)
check("IRQ with the source left set fires again on acknowledge (#{n2 - n1}), not after it is cleared (#{n3 - n2})",
      n2 - n1 == 1 && n3 == n2 && !Pico::IRQ.fired?(irq_t))
t.alarm_set_irq_enabled(0, false)
Pico::IRQ.set_pending(irq_t)
check("IRQ set_pending fires it by software", Pico::IRQ.fired?(irq_t) && Pico::IRQ.count(irq_t) == n3 + 1)
Pico::IRQ.acknowledge(irq_t)
Pico::IRQ.set_enabled(irq_t, false)
Pico::IRQ.set_priority(irq_t, 0xff)
pr = Pico::IRQ.get_priority(irq_t)
Pico::IRQ.set_priority(irq_t, 0)
check("IRQ priority keeps the top 2 bits (0xff reads 0x#{pr.to_s(16)}); disabled: #{!Pico::IRQ.is_enabled?(irq_t)}",
      pr == 0xc0 && !Pico::IRQ.is_enabled?(irq_t))

# DMA completion on DMA_IRQ_0, sleeping in WFI: 100 transfers paced at 10 kHz take 10 ms
dma = pico.dma
src = Pico::RAMBuffer.new(400, 4)
dst = Pico::RAMBuffer.new(400, 4)
ci = dma.claim_unused_channel(true)
ch = dma.channel(ci)
irq_d = Pico::RP2040.irq(:dma_irq_0)
cf = dma.get_default_config(ci)
cf.set_write_increment(true)
cf.set_dreq(dma.get_timer_dreq(0))
dma.timer_set_fraction(0, 1, 1200)
ch.acknowledge_irq0
ch.set_irq0_enabled(true)
Pico::IRQ.set_enabled(irq_d, true)
ch.configure(cf, dst.addr, src.addr, 100, false)
a = t.time_us_31
ch.start
wakes = 0
until Pico::IRQ.fired?(irq_d)
  Pico::IRQ.wait_for_interrupt
  wakes += 1
end
w = t.us_since(a)
done = !ch.is_busy? && ch.get_irq0_status
ch.acknowledge_irq0
Pico::IRQ.acknowledge(irq_d)
# about 1 ms more than the 100 transfers: starting and noticing the end at clk_sys 12 MHz (as in the DMA checks)
check("IRQ DMA completion wakes WFI after #{w} us (10000 + about 1000), #{wakes} wake(s)",
      done && wakes == 1 && w >= 9900 && w <= 12_000)
ch.set_irq0_enabled(false)
Pico::IRQ.set_enabled(irq_d, false)
dma.channel_unclaim(ci)
src.free
dst.free

# GPIO 25 (the LED) as output: its own pad input sees the edges
irq_g = Pico::RP2040.irq(:io_irq_bank0)
g.init(25)
g.set_dir(25, true)
g.put(25, false)
g.set_irq_enabled(25, Pico::GPIO::IRQ_EDGE_RISE | Pico::GPIO::IRQ_EDGE_FALL, true)
Pico::IRQ.set_enabled(irq_g, true)
quiet = !Pico::IRQ.fired?(irq_g)
g.put(25, true)
t.busy_wait_us_32(10)
rise = Pico::IRQ.fired?(irq_g) && g.get_irq_event_mask(25) == Pico::GPIO::IRQ_EDGE_RISE
g.acknowledge_irq(25, Pico::GPIO::IRQ_EDGE_RISE)
Pico::IRQ.acknowledge(irq_g)
g.put(25, false)
t.busy_wait_us_32(10)
fall = Pico::IRQ.fired?(irq_g) && g.get_irq_event_mask(25) == Pico::GPIO::IRQ_EDGE_FALL
g.acknowledge_irq(25, Pico::GPIO::IRQ_EDGE_FALL)
Pico::IRQ.acknowledge(irq_g)
g.set_irq_enabled(25, Pico::GPIO::IRQ_EDGE_RISE | Pico::GPIO::IRQ_EDGE_FALL, false)
g.put(25, true)
t.busy_wait_us_32(10)
off = !Pico::IRQ.fired?(irq_g) && (g.get_raw_irq_event_mask(25) & Pico::GPIO::IRQ_EDGE_RISE) != 0   # raw has LEVEL_HIGH too
g.acknowledge_irq(25, Pico::GPIO::IRQ_EDGE_RISE)
g.put(25, false)
Pico::IRQ.set_enabled(irq_g, false)
check("IRQ GPIO 25 rising and falling edges reach IO_IRQ_BANK0; none once disabled (raw INTR still records it)",
      quiet && rise && fall && off)

# ---- I2C0 on GPIO 4 (SDA) and 5 (SCL) with the on-chip pull-ups, nothing attached: every address is refused.
# I2C only pulls pins low, and the section runs only if both pins follow the pull-up and the pull-down (nothing drives
# them). clk_sys 125 MHz so the software is fast next to the bus
def floating?(g, t, pin)
  g.init(pin)
  g.pull_up(pin)
  t.busy_wait_us_32(200)
  up = g.get(pin)
  g.pull_down(pin)
  t.busy_wait_us_32(200)
  down = g.get(pin)
  g.disable_pulls(pin)
  up && !down
end

# Shortest of 3 refused writes: [result, us]
def time_nack(i2c, t, baud)
  i2c.init(baud)
  i2c.write_timeout_us(0x3c, [1], false, t, 50_000)          # warm up
  best = 1_000_000
  rc = 0
  3.times do
    a = t.time_us_31
    rc = i2c.write_timeout_us(0x3c, [1, 2], false, t, 50_000)
    d = t.us_since(a)
    best = d if d < best
  end
  [rc, best]
end

if floating?(g, t, 4) && floating?(g, t, 5)
  c.set_sys_clock_khz(125_000)
  i2c = pico.i2c(0)
  [4, 5].each do |pin|
    g.set_function(pin, :i2c)
    g.pull_up(pin)
  end
  r10 = time_nack(i2c, t, 10_000)
  r20 = time_nack(i2c, t, 20_000)
  check("I2C write to 0x3c with nothing attached: ERROR_GENERIC (#{r10[0]}), address not acknowledged (abort 0x#{i2c.last_abort_reason.to_s(16)})",
        r10[0] == Pico::I2C::ERROR_GENERIC && i2c.last_abort_reason == Pico::I2C::ABRT_7B_ADDR_NOACK)
  # The software around the transfer costs about the same at both rates, so the difference is half the bus time at
  # 10 kHz: START, 9 clocks (address and the refused acknowledge), STOP = 9-15 periods of 100 us
  diff = r10[1] - r20[1]
  check("I2C refused address: #{r10[1]} us at 10 kHz, #{r20[1]} us at 20 kHz, bus time at 10 kHz #{diff * 2} us (9-15 periods)",
        diff >= 450 && diff <= 750)
  i2c.init(100_000)
  dst = [9]
  rc = i2c.read_timeout_us(0x3c, dst, 2, false, t, 50_000)
  check("I2C read with nothing attached: ERROR_GENERIC (#{rc}), nothing received", rc == Pico::I2C::ERROR_GENERIC && dst.empty?)
  check("I2C write_blocking (no timeout) returns", i2c.write_blocking(0x3c, [1], false) == Pico::I2C::ERROR_GENERIC)
  g.set_inover(5, :low)                       # SCL held low (as by a stuck target), without driving the pin
  a = t.time_us_31
  rc = i2c.write_timeout_us(0x3c, [1], false, t, 5000)
  d = t.us_since(a)
  check("I2C with SCL held low: ERROR_TIMEOUT (#{rc}) after #{d} us (5000)", rc == Pico::I2C::ERROR_TIMEOUT && d >= 5000 && d < 5500)
  g.set_inover(5, :normal)
  i2c.init(100_000)
  check("I2C works again after init", i2c.write_timeout_us(0x3c, [1], false, t, 50_000) == Pico::I2C::ERROR_GENERIC)
  i2c.deinit
  [4, 5].each do |pin|
    g.deinit(pin)
    g.disable_pulls(pin)
  end
  c.set_sys_clock_from_ref
else
  puts "SKIP I2C: GPIO 4 or 5 is connected to something"
end

puts "board selftest: #{$fails == 0 ? 'all passed' : "#{$fails} failed"}"
exit 1 if $fails > 0
