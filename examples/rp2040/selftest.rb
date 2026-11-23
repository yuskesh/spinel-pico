# On RP2040 under bare-full, drive WS2812 using the runtime layer (Pico::PIO::Block / StateMachine),
# have two other SMs in the same PIO count the pin's High and Low widths, and print them to the console.
#   SM0: WS2812 (built for 12 MHz). SET pin = GPIO 25
#   SM1: High width, SM2: Low width (clkdiv 1, one count per 2 cycles; RX FIFO joined to 8 deep)
# The first run derives clkdiv from the program's clock (12 MHz / 12 MHz = 1); the second runs slower at clkdiv 8
# to resolve individual cycles (High counts cycles x 4, Low counts cycles x 4 - 1)
require_relative "../../lib/pico/pio/runtime"
require_relative "../../lib/pico/mmio"
require_relative "selftest_programs"

SYS_HZ = 12_000_000          # bare-full's rp2040-pico derives clk_sys from the 12 MHz crystal

def wait_rx(sm, n)
  i = 0
  while sm.rx_level < n
    i += 1
    return false if i > 200_000
  end
  true
end

def run(bus, div)
  pio = Pico::PIO::Block.new(bus, Pico::RP2040, 0)
  pio.reset!
  pio.gpio_init(SELFTEST_PIN)
  w = pio.add_program(WS2812_12MHZ)
  h = pio.add_program(SAMPLE_HIGH)
  l = pio.add_program(SAMPLE_LOW)

  c = WS2812_12MHZ.default_config(w)
  c.set_set_pins(SELFTEST_PIN, 1)
  if div == 0
    c.set_clkdiv_for(SYS_HZ, WS2812_12MHZ.clock_hz)
  else
    c.set_clkdiv_int_frac(div, 0)
  end
  ws = pio.sm(0)
  ws.init(w, c)
  ws.set_consecutive_pindirs(SELFTEST_PIN, 1, true)

  hs = pio.sm(1)
  ch = SAMPLE_HIGH.default_config(h)
  ch.set_jmp_pin(SELFTEST_PIN)
  ch.set_fifo_join(:rx)
  hs.init(h, ch)
  ls = pio.sm(2)
  cl = SAMPLE_LOW.default_config(l)
  cl.set_jmp_pin(SELFTEST_PIN)
  cl.set_fifo_join(:rx)
  ls.init(l, cl)

  ws.put_hl(0xA5C3, 0x0000)  # 0xA5C30000: bit 31 is set, so push it as upper/lower halves
  ws.put(0x3C000000)
  pio.enable_in_sync([ws, hs, ls])
  ok = wait_rx(hs, 8) && wait_rx(ls, 8)
  his = []
  los = []
  8.times { his << hs.get } if ok
  8.times { los << ls.get } if ok
  puts "clkdiv #{c.clkdiv_int} (offset ws #{w} high #{h} low #{l}): #{ok ? 'got 8 each' : 'FIFO did not fill'}"
  puts "  High counts #{his.inspect}"
  puts "  Low counts  #{los.inspect}"
  pio.reset!
end

bus = Pico::MMIOBus.new
run(bus, 0)
run(bus, 8)
