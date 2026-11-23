# Time layer extensions on an RP2040 Pico under bare-full, using only GPIO 25 (the LED) and PIO0. Prints PASS / FAIL.
#   side-set:     WS2812 with the data pin on side-set gives the same High / Low counts as the SET-pin version
#   wait + irq:   the CPU drives GPIO 25; a program waiting on it raises IRQ flag 0 on rises and flag 1 on falls
#   in + autopush: one SM makes 4 cycles High / 4 Low on GPIO 25, another samples it every 2 cycles into bytes
#   irq wait:     a program raises flag 1 and waits; after the CPU clears it, a 20-cycle side-set pulse follows
#   irq set:      flag 2 every 10 ms (program built for 100 kHz)
#   repeat:       3 pulses of 5 / 10 cycles, then 40 Low, counted by SAMPLE_HIGH / SAMPLE_LOW
#   pick:         flag 1 every 10 ms while the CPU holds GPIO 25 high, every 30 ms while low
#   bit.branch:   Manchester on GPIO 25, counted by SAMPLE_HIGH / SAMPLE_LOW
#   din.branch:   flag 0 every 10 ms while the CPU holds GPIO 25 high, flag 1 while low
#   inbox.preset: a PWM whose Low comes from the ISR (StateMachine#load_isr) and High from the TX FIFO
#   inbox.next:   out pins with autopull on GPIO 25
#   nested repeat: 2 groups of 3 pulses on GPIO 25
#   two inputs:   branches on GPIO 25 (JMP pin) and GPIO 26 (through the OSR), if GPIO 26 floats
#   directives:   mov_status and clock_div of an instruction-layer program
#   OUT pin:      SPI transmit with MOSI on GPIO 25 and SCK on GPIO 4 (only if GPIO 4 floats; otherwise skipped)
# These three set up their SMs with Program#init_sm
# Programs are assembled on the host by tools/export_selftest.rb (selftest_programs.rb)
require_relative "../../lib/pico"
require_relative "../../lib/pico/pio/runtime"
require_relative "selftest_programs"

SYS_HZ = 12_000_000
PIN = SELFTEST_PIN

$fail = 0
def check(what, ok)
  puts "#{ok ? 'PASS' : 'FAIL'} #{what}"
  $fail += 1 unless ok
end

def wait_rx(sm, n)
  i = 0
  while sm.rx_level < n
    i += 1
    return false if i > 200_000
  end
  true
end

def wait_flag(pio, n)
  i = 0
  until pio.interrupt_get(n)
    i += 1
    return false if i > 200_000
  end
  true
end

# nothing attached to the pin: it follows the pull-up and the pull-down
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

# median of 5 intervals between flags: a GC pause in the polling loop can stretch or shrink one of them
def median_interval(pio, t, flag)
  wait_flag(pio, flag)
  pio.interrupt_clear(flag)
  ts = []
  6.times do
    wait_flag(pio, flag)
    ts << t.time_us_31
    pio.interrupt_clear(flag)
  end
  d = []
  5.times { |i| d << ts[i + 1] - ts[i] }
  d.sort[2]
end

pico = Pico.rp2040
bus = pico.bus
t = pico.timer
g = pico.gpio

# ---- side-set: High / Low widths of WS2812 (SET pin) and WS2812 (side-set pin), counted by SAMPLE_HIGH / SAMPLE_LOW
# at clkdiv 8 (High counts cycles x 4, Low counts cycles x 4 - 1)
def ws_counts(bus, prog, side)
  pio = Pico::PIO::Block.new(bus, Pico::RP2040, 0)
  pio.reset!
  pio.gpio_init(PIN)
  w = pio.add_program(prog)
  h = pio.add_program(SAMPLE_HIGH)
  l = pio.add_program(SAMPLE_LOW)
  c = prog.default_config(w)
  side ? c.set_sideset_pins(PIN) : c.set_set_pins(PIN, 1)
  c.set_clkdiv_int_frac(8, 0)
  ws = pio.sm(0)
  ws.init(w, c)
  ws.set_consecutive_pindirs(PIN, 1, true)
  hs = pio.sm(1)
  ch = SAMPLE_HIGH.default_config(h)
  ch.set_jmp_pin(PIN)
  ch.set_fifo_join(:rx)
  hs.init(h, ch)
  ls = pio.sm(2)
  cl = SAMPLE_LOW.default_config(l)
  cl.set_jmp_pin(PIN)
  cl.set_fifo_join(:rx)
  ls.init(l, cl)
  ws.put_hl(0xA5C3, 0x0000)
  ws.put(0x3C000000)
  pio.enable_in_sync([ws, hs, ls])
  out = []
  if wait_rx(hs, 8) && wait_rx(ls, 8)
    8.times { out << hs.get }
    8.times { out << ls.get }
  end
  pio.reset!
  out
end

set_c = ws_counts(bus, WS2812_12MHZ, false)
side_c = ws_counts(bus, WS2812_SIDE_12MHZ, true)
puts "  SET pin   High #{set_c.first(8).inspect} Low #{set_c.drop(8).inspect}"
puts "  side-set  High #{side_c.first(8).inspect} Low #{side_c.drop(8).inspect}"
check("side-set WS2812 has the same High / Low counts as the SET-pin version (16 values)", set_c.size == 16 && side_c == set_c)

pio = Pico::PIO::Block.new(bus, Pico::RP2040, 0)

# ---- wait + irq set: GPIO 25 driven by the CPU (SIO), read by the program as its IN pin
pio.reset!
g.init(PIN)
g.set_dir(PIN, true)
g.put(PIN, false)
o = pio.add_program(EDGE_IRQ)
c = EDGE_IRQ.default_config(o)
c.set_in_pins(PIN)
sm = pio.sm(0)
sm.init(o, c)
pio.interrupt_clear_mask(0xFF)
sm.set_enabled(true)
t.busy_wait_us_32(50)
quiet = pio.irq_flags == 0
g.put(PIN, true)
t.busy_wait_us_32(50)
rise = pio.irq_flags == 1
pio.interrupt_clear(0)
g.put(PIN, false)
t.busy_wait_us_32(50)
fall = pio.irq_flags == 2
pio.interrupt_clear(1)
g.put(PIN, true)
t.busy_wait_us_32(50)
again = pio.irq_flags == 1
g.put(PIN, false)
check("wait_high / wait_low: flag 0 on the rise, flag 1 on the fall, none while the pin is still (#{quiet} #{rise} #{fall} #{again})",
      quiet && rise && fall && again)
pio.reset!

# ---- in + autopush: GEN8 on GPIO 25 (SM0), SAMPLE2 reads it (SM1), started together
pio.reset!
pio.gpio_init(PIN)
og = pio.add_program(GEN8)
os = pio.add_program(SAMPLE2)
cg = GEN8.default_config(og)
cg.set_set_pins(PIN, 1)
gen = pio.sm(0)
gen.init(og, cg)
gen.set_consecutive_pindirs(PIN, 1, true)
cs = SAMPLE2.default_config(os)
cs.set_in_pins(PIN)
cs.set_fifo_join(:rx)
smp = pio.sm(1)
smp.init(os, cs)
pio.enable_in_sync([gen, smp])
bytes = []
if wait_rx(smp, 8)
  8.times { bytes << smp.get }
end
pio.reset!
rot = [0xCC, 0x99, 0x33, 0x66]
puts "  sampled #{bytes.map { |b| format('0x%02x', b) }.join(' ')}"
check("sample + autopush(8): every byte is the same rotation of 11001100 (4 High / 4 Low sampled every 2 cycles)",
      bytes.size == 8 && rot.include?(bytes[0]) && bytes.uniq.size == 1)

# ---- irq wait: HANDSHAKE20 raises flag 1 and waits; the ready pulse (side-set, GPIO 25) is counted by SAMPLE_HIGH
pio.reset!
pio.gpio_init(PIN)
oh = pio.add_program(HANDSHAKE20)
oc = pio.add_program(SAMPLE_HIGH)
c = HANDSHAKE20.default_config(oh)
c.set_sideset_pins(PIN)
c.set_clkdiv_int_frac(8, 0)
hs = pio.sm(0)
hs.init(oh, c)
hs.set_consecutive_pindirs(PIN, 1, true)
cc = SAMPLE_HIGH.default_config(oc)
cc.set_jmp_pin(PIN)
counter = pio.sm(1)
counter.init(oc, cc)
pio.interrupt_clear_mask(0xFF)
pio.enable_in_sync([hs, counter])
raised = wait_flag(pio, 1)
t.busy_wait_us_32(200)
held = pio.interrupt_get(1) && counter.rx_level == 0         # still waiting: no pulse yet
pio.interrupt_clear(1)
got = wait_rx(counter, 1) ? counter.get : -1
again = wait_flag(pio, 1)
pio.interrupt_clear(1)
got2 = wait_rx(counter, 1) ? counter.get : -1
pio.reset!
want = 20 * 4                                               # clkdiv 8, counted every 2 sys cycles: cycles x 4
puts "  pulse counts #{got} #{got2} (#{want})"
check("set_and_wait: flag 1 raised (#{raised}), held with no pulse (#{held}); after each clear a 20-cycle pulse",
      raised && held && again && got == want && got2 == want)

# ---- irq set every 10 ms: time 10 flags
pio.reset!
ot = pio.add_program(IRQ_TICK_10MS)
c = IRQ_TICK_10MS.default_config(ot)
c.set_clkdiv_for(SYS_HZ, IRQ_TICK_10MS.clock_hz)
tk = pio.sm(0)
tk.init(ot, c)
pio.interrupt_clear_mask(0xFF)
tk.set_enabled(true)
d = median_interval(pio, t, 2)
pio.reset!
check("irq(2).set every 10 ms: flags every #{d} us (10000) (median of 5)", (d - 10_000).abs <= 50)

# ---- High / Low counts of GPIO 25 at clkdiv 8 for a program set up with init_sm (High = cycles x 4, Low = cycles x 4 - 1)
def counts(pio, prog, set_base, side_base, out_base, words, n, isr = -1)
  pio.reset!
  w = pio.add_program(prog)
  h = pio.add_program(SAMPLE_HIGH)
  l = pio.add_program(SAMPLE_LOW)
  sm = pio.sm(0)
  prog.init_sm(sm, w, set_base, side_base, out_base, -1, SYS_HZ)
  sm.set_clkdiv_int_frac(8, 0)
  hs = pio.sm(1)
  ch = SAMPLE_HIGH.default_config(h)
  ch.set_jmp_pin(PIN)
  ch.set_fifo_join(:rx)
  hs.init(h, ch)
  ls = pio.sm(2)
  cl = SAMPLE_LOW.default_config(l)
  cl.set_jmp_pin(PIN)
  cl.set_fifo_join(:rx)
  ls.init(l, cl)
  sm.load_isr(isr) if isr >= 0                       # inbox.preset, before the words (it goes through the TX FIFO)
  words.each { |hl| sm.put_hl(hl[0], hl[1]) }        # halves: a word with bit 31 set does not fit an Integer
  pio.enable_in_sync([sm, hs, ls])
  out = []
  if wait_rx(hs, n) && wait_rx(ls, n)
    n.times { out << hs.get }
    n.times { out << ls.get }
  end
  pio.reset!
  out
end

c3 = counts(pio, BURST3, PIN, -1, -1, [[0, 0]].first(0), 8)
puts "  repeat  High #{c3.first(8).inspect} Low #{c3.drop(8).inspect}"
lows = c3.drop(8)
k = lows.index(159) || 0
pattern = lows.drop(k).first(6)
check("repeat(3): every pulse 5 cycles (20), Low 10, 10, 40 cycles (39, 39, 159) in turn",
      c3.size == 16 && c3.first(8).uniq == [20] && pattern == [159, 39, 39, 159, 39, 39].first(pattern.size) && pattern.size >= 4)

# ---- pick: GPIO 25 driven by the CPU is the JMP pin
pio.reset!
g.init(PIN)
g.set_dir(PIN, true)
g.put(PIN, true)
op = pio.add_program(PICK_TICK)
pk = pio.sm(0)
PICK_TICK.init_sm(pk, op, -1, -1, -1, PIN, SYS_HZ)
pio.interrupt_clear_mask(0xFF)
pk.set_enabled(true)
hi = median_interval(pio, t, 1)
g.put(PIN, false)
lo = median_interval(pio, t, 1)
pio.reset!
check("pick: flags every #{hi} us with the pin high (10000), #{lo} us low (30000) (median of 5)", (hi - 10_000).abs <= 50 && (lo - 30_000).abs <= 50)

# ---- bit.branch: Manchester of 0xA5 on GPIO 25, 4-cycle halves: L H H L L H H L H L L H H L L H
cm = counts(pio, MANCHESTER12, PIN, -1, -1, [[0xA500, 0]], 4)
puts "  branch  High #{cm.first(4).inspect} Low #{cm.drop(4).inspect}"
check("bit.branch: Manchester 0xA5 gives High 8, 8, 4, 8 cycles (32, 32, 16, 32) and Low 8, 4, 8, 8 (31, 15, 31, 31)",
      cm == [32, 32, 16, 32, 31, 15, 31, 31])

# ---- din.branch: GPIO 25 driven by the CPU; only the path's flag is raised
pio.reset!
g.init(PIN)
g.set_dir(PIN, true)
g.put(PIN, true)
og = pio.add_program(GATE_TICK)
gs = pio.sm(0)
GATE_TICK.init_sm(gs, og, -1, -1, -1, PIN, SYS_HZ)
pio.interrupt_clear_mask(0xFF)
gs.set_enabled(true)
hi = median_interval(pio, t, 0)
hi_other = pio.interrupt_get(1)
g.put(PIN, false)
wait_flag(pio, 1)
pio.interrupt_clear_mask(0xFF)
lo = median_interval(pio, t, 1)
lo_other = pio.interrupt_get(0)
pio.reset!
check("din.branch: flag 0 every #{hi} us while high (10000), flag 1 every #{lo} us while low; the other flag stays down (#{!hi_other} #{!lo_other})",
      (hi - 10_000).abs <= 50 && (lo - 10_000).abs <= 50 && !hi_other && !lo_other)

# ---- inbox.preset: ISR 30 (Low 35 cycles), received 10 (High 13 cycles)
cp = counts(pio, PRESET_PWM12, PIN, -1, -1, [[0, 10]], 3, 30)
puts "  preset  High #{cp.first(3).inspect} Low #{cp.drop(3).inspect}"
check("inbox.preset: High 13 cycles (52) from the received 10, Low 35 cycles (139) from the ISR's 30", cp == [52, 52, 52, 139, 139, 139])

# ---- inbox.next + write (out pins with autopull) on GPIO 25: word 0xB40F0000, MSB first, 4 cycles per bit
cn = counts(pio, OUT_NEXT12, -1, -1, PIN, [[0xB40F, 0]], 3)
puts "  next    High #{cn.first(3).inspect} Low #{cn.drop(3).inspect}"
check("write(inbox.next(1)): High 4, 8, 4 cycles (16, 32, 16) and Low 4, 4, 24 (15, 15, 95)", cn == [16, 32, 16, 15, 15, 95])

# ---- a repeat inside a repeat (X and Y): Low 3, 3, 13, 3, 3, 33 cycles in turn
cg = counts(pio, GROUPS12, PIN, -1, -1, [[0, 0]].first(0), 8)      # 8: what the joined RX FIFO holds
gl = cg.drop(8)
gk = gl.index(131) || 0
gp = gl.drop(gk).first(6)
puts "  nested  High #{cg.first(8).uniq.inspect} Low #{gl.inspect}"
check("repeat in repeat: every pulse 2 cycles (8), Low 3, 3, 13, 3, 3, 33 cycles (11, 11, 51, 11, 11, 131) in turn",
      cg.size == 16 && cg.first(8).uniq == [8] && gp.size >= 3 && gp == [131, 11, 11, 51, 11, 11].first(gp.size) &&
      gl.count(51) >= 1 && gl.count(131) >= 1)

# ---- branches on two inputs: GPIO 25 (the JMP pin) and GPIO 26 (read through the OSR), both driven by the CPU
if floating?(g, t, 26)
  pio.reset!
  g.init(PIN)
  g.set_dir(PIN, true)
  g.init(26)
  g.set_dir(26, true)
  o2 = pio.add_program(GATE_TWO)
  s2 = pio.sm(0)
  GATE_TWO.init_sm(s2, o2, -1, -1, -1, PIN, SYS_HZ)
  s2.set_enabled(true)
  seen = []
  [[true, true], [true, false], [false, true], [false, false]].each do |lv|
    g.put(PIN, lv[0])
    g.put(26, lv[1])
    t.busy_wait_us_32(500)             # a pass in progress ends
    pio.interrupt_clear_mask(0xFF)
    t.busy_wait_ms(2)                  # about 20 passes
    seen << (pio.irq_flags & 7)
  end
  pio.reset!
  g.init(26)
  check("branches on two inputs: flags #{seen.inspect} for en / dir = 1 1, 1 0, 0 1, 0 0 (1, 2, 4, 4)", seen == [1, 2, 4, 4])
else
  puts "SKIP branches on two inputs: GPIO 26 does not float (something is attached)"
end

# ---- mov_status and clock_div from the instruction layer's directives
pio.reset!
os = pio.add_program(STATUS_PROBE)
ss = pio.sm(0)
ss.init(os, STATUS_PROBE.default_config(os))
div = bus.read32(0x5020_00c8)
ss.set_enabled(true)
ss.clear_fifos
t.busy_wait_us_32(200)
empty = ss.get
ss.put(1)                              # the program never pulls: the TX FIFO now holds a word
6.times { ss.get }                     # values pushed before the word went in (the RX FIFO holds 4)
held = ss.get
pio.reset!
check("mov_status :txfifo, 1: STATUS reads #{empty} with the TX FIFO empty (-1), #{held} with a word in it (0); clock_div 2.5: CLKDIV 0x#{div.to_s(16)} (0x28000)",
      empty == -1 && held == 0 && div == 0x28000)

# ---- OUT pin: bytes 0xB4, 0x0F MSB first, 4 cycles per bit; MOSI then holds the last bit (1) while the SM stalls

if floating?(g, t, 4)
  cs = counts(pio, SPI_TX12, -1, 4, PIN, [[0xB400, 0], [0x0F00, 0]], 3)
  # 1 0 11 0 1 000000 1111: High 4, 8, 4 cycles; Low 4, 4, 24
  puts "  OUT pin High #{cs.first(3).inspect} Low #{cs.drop(3).inspect}"
  check("put(bit): MOSI High 4, 8, 4 cycles (16, 32, 16) and Low 4, 4, 24 (15, 15, 95)", cs == [16, 32, 16, 15, 15, 95])
  g.init(4)
else
  puts "SKIP put(bit): GPIO 4 does not float (something is attached)"
end

puts($fail == 0 ? "timed selftest: all passed" : "timed selftest: #{$fail} failed")
exit($fail == 0 ? 0 : 1)
