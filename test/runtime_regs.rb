# Check the register values the PIO runtime layer writes, using a bus that just records writes (no microcontroller needed).
# Expected values were computed by hand from the bit positions in RP2040 datasheet section 3.7
require_relative "../lib/pico/pio/runtime"
require_relative "../examples/rp2040/selftest_programs"

require_relative "fake_bus"

bus = FakeBus.new
bus.fix(0x4000c008, 0x1FFFFFF)    # RESET_DONE: all out of reset
bus.fix(0x50200004, 0)            # FSTAT: TX not full, RX not empty
pio = Pico::PIO::Block.new(bus, Pico::RP2040, 0)
pio.reset!
pio.gpio_init(25)
w = pio.add_program(WS2812_12MHZ)
h = pio.add_program(SAMPLE_HIGH)
l = pio.add_program(SAMPLE_LOW)
puts "loaded at: ws2812 #{w}, high #{h}, low #{l}"
expect("offset (ws2812 takes the top 8 words)", w, 24)
expect("offset (high)", h, 17)
expect("offset (low)", l, 10)
expect("GPIO25_CTRL = PIO0", bus.mem[0x4001_40cc], 6)
expect("ws2812 jmp !y targets 4 + 24", bus.mem[0x5020_0048 + 4 * (24 + 2)], 0x0364 + 24)
expect("ws2812 jmp is relocated (0x0000 -> 24)", bus.mem[0x5020_0048 + 4 * (24 + 6)], 24)
expect("set etc. are not relocated", bus.mem[0x5020_0048 + 4 * (24 + 1)], 0xe001)
expect("high jmp x-- targets 4 + 17", bus.mem[0x5020_0048 + 4 * (17 + 3)], 0x0044 + 17)

c = WS2812_12MHZ.default_config(w)
c.set_set_pins(25, 1)
c.set_clkdiv_for(12_000_000, WS2812_12MHZ.clock_hz)
pio.sm(0).init(w, c)
sm0 = 0x5020_00c8
expect("SM0_CLKDIV (12MHz / 12MHz = 1)", bus.mem[sm0], 1 << 16)
expect("SM0_EXECCTRL (wrap 31 -> 24)", bus.mem[sm0 + 4], (31 << 12) | (24 << 7))
expect("SM0_SHIFTCTRL (shift left, autopull, threshold 24)", bus.mem[sm0 + 8], 0x30060000)
expect("SM0_PINCTRL (1 SET pin, GPIO 25)", bus.mem[sm0 + 0x14], (1 << 26) | (25 << 5))
expect("SM0_INSTR (last: jmp 24)", bus.mem[sm0 + 0x10], 24)

c.set_clkdiv_int_frac(8, 0)
pio.sm(0).init(w, c)
expect("SM0_CLKDIV (8)", bus.mem[sm0], 8 << 16)

ch = SAMPLE_HIGH.default_config(h)
ch.set_jmp_pin(25)
ch.set_fifo_join(:rx)
pio.sm(1).init(h, ch)
sm1 = sm0 + 0x18
expect("SM1_EXECCTRL (jmp pin 25, wrap 23 -> 17)", bus.mem[sm1 + 4], (25 << 24) | (23 << 12) | (17 << 7))
expect("SM1_SHIFTCTRL (FJOIN_RX, default shift right)", bus.mem[sm1 + 8], 0x800c0000)

pio.sm(0).set_consecutive_pindirs(25, 1, true)
expect("executed set pindirs, 1", bus.log.select { |e| e[0] == sm0 + 0x10 }.last[1], 0xe081)
expect("SM0_PINCTRL restored", bus.mem[sm0 + 0x14], (1 << 26) | (25 << 5))

pio.enable_in_sync([pio.sm(0), pio.sm(1), pio.sm(2)])
expect("CTRL (enable 3 SMs, clkdiv restart in sync)", bus.mem[0x5020_0000] & 0xF0F, 0x707)

# cases where clkdiv cannot be determined
[[12_000_000, 20_000_000, false], [125_000_000, 20_000_000, false], [125_000_000, 3_000_000, false],
 [125_000_000, 20_000_000, true]].each do |sys, clk, frac|
  cc = Pico::PIO::SMConfig.new
  begin
    cc.set_clkdiv_for(sys, clk, fractional: frac)
    puts "clk_sys #{sys} / #{clk}#{frac ? ' (fractional)' : ''}: clkdiv #{cc.clkdiv_int} + #{cc.clkdiv_frac}/256"
  rescue => e
    puts "raised: #{e.message}"
  end
end

begin
  full = Pico::PIO::Block.new(FakeBus.new, Pico::RP2040, 0)
  4.times { full.add_program(WS2812_12MHZ) }
  full.add_program(SAMPLE_HIGH)
  puts "unexpected pass: loaded with no free instruction memory"
  $fail += 1
rescue => e
  puts "raised: #{e.message}"
end

# ---- IRQ flags, interrupt sources, FDEBUG
PIO0 = 0x5020_0000
pio.interrupt_force(3)
expect("interrupt_force(3) writes IRQ_FORCE", bus.mem[PIO0 + 0x34], 8)
bus.fix(PIO0 + 0x30, 0x0a)
expect("interrupt_get(1)", pio.interrupt_get(1) ? 1 : 0, 1)
expect("interrupt_get(2)", pio.interrupt_get(2) ? 1 : 0, 0)
expect("irq_flags", pio.irq_flags, 0x0a)
pio.interrupt_clear(1)
expect("interrupt_clear(1) writes 1 << 1 to IRQ", bus.writes_to(PIO0 + 0x30).last, 2)
raises("IRQ flag 8") { pio.interrupt_get(8) }
pio.set_irq0_source_enabled(Pico::PIO::PIS_INTERRUPT0 + 2, true)
expect("IRQ0_INTE: flag 2 source (bit 10) set", bus.mem[PIO0 + 0x12c], 1 << 10)
bus.mem[PIO0 + 0x138] = 0x81
pio.set_irqn_source_enabled(1, Pico::PIO::PIS_SM0_TX_FIFO_NOT_FULL + 3, false)
expect("IRQ1_INTE: SM3 TX not full (bit 7) cleared, bit 0 kept", bus.mem[PIO0 + 0x138], 1)
bus.fix(PIO0 + 0x140, 0x400)
expect("ints(1)", pio.ints(1), 0x400)
raises("interrupt line 2") { pio.ints(2) }
pio.clear_fdebug(1 << 16)
expect("clear_fdebug writes FDEBUG", bus.mem[PIO0 + 0x08], 1 << 16)

# ---- state machine helpers (SM1)
s1 = pio.sm(1)
sm1 = 0x5020_00c8 + 0x18
bus.mem[sm1 + 4] = 0x0002_f000
s1.set_wrap(3, 9)
expect("set_wrap(3, 9) keeps the other EXECCTRL bits", bus.mem[sm1 + 4], 0x0002_0000 | (9 << 12) | (3 << 7))
s1.set_clkdiv_int_frac(2, 128)
expect("CLKDIV 2 + 128/256", bus.mem[sm1], (2 << 16) | (128 << 8))
raises("clkdiv 0 with a fraction") { s1.set_clkdiv_int_frac(0, 1) }
bus.mem[sm1 + 0x14] = 0
s1.set_out_pins(10, 4)
s1.set_set_pins(2, 3)
s1.set_in_pins(7)
s1.set_sideset_pins(25)
expect("PINCTRL: out 10 x4, set 2 x3, in 7, side-set 25", bus.mem[sm1 + 0x14],
       10 | (4 << 20) | (2 << 5) | (3 << 26) | (7 << 15) | (25 << 10))
bus.fix(sm1 + 0x0c, 0x2b)
expect("get_pc", s1.get_pc, 0x0b)
bus.fix(sm1 + 4, 0x8000_0000)
expect("is_exec_stalled? (EXECCTRL bit 31)", s1.is_exec_stalled? ? 1 : 0, 1)
bus.fix(sm1 + 4, 0x0000_1000)
expect("not stalled", s1.is_exec_stalled? ? 1 : 0, 0)
bus.mem[sm1 + 8] = 0
s1.clear_fifos
expect("clear_fifos flips FJOIN_RX: 0x80000000 then back", bus.writes_to(sm1 + 8).last(2).inject(0) { |a, b| a + b }, 0x8000_0000)
expect("clear_fifos leaves SHIFTCTRL as it was", bus.mem[sm1 + 8], 0)

# set_pins(values): GPIO 0-31 in 5-pin chunks; PINCTRL and EXECCTRL restored
bus.mem[sm1 + 0x14] = 0x1234
n_before = bus.writes_to(sm1 + 0x10).size
s1.set_pins((1 << 25) | 3)
instrs = bus.writes_to(sm1 + 0x10).drop(n_before)
expect("set_pins: 7 set instructions", instrs.size, 7)
expect("set_pins: chunk 0 sets pins 0-1", instrs[0], 0xe003)
expect("set_pins: chunk 5 (GPIO 25-29) sets its first pin", instrs[5], 0xe001)
expect("set_pins: last chunk GPIO 30-31 (count 2)", bus.writes_to(sm1 + 0x14)[-2], (2 << 26) | (30 << 5))
expect("set_pins restores PINCTRL", bus.mem[sm1 + 0x14], 0x1234)
n_before = bus.writes_to(sm1 + 0x10).size
s1.set_pindirs_with_mask(1 << 4, (1 << 4) | (1 << 9))
instrs = bus.writes_to(sm1 + 0x10).drop(n_before)
expect("set_pindirs_with_mask: set pindirs 1 for GPIO 4, 0 for GPIO 9", instrs[0] * 65_536 + instrs[1], 0xe081 * 65_536 + 0xe080)

# drain_tx_fifo: the model reports TX empty after three instructions
class DrainModel < FakeBus
  def read32(a)
    return (writes_to(0x5020_00c8 + 0x18 + 0x10).size >= 3 ? 1 << 25 : 0) if a == 0x5020_0004
    super
  end
end
dm = DrainModel.new
dp = Pico::PIO::Block.new(dm, Pico::RP2040, 0)
dp.sm(1).drain_tx_fifo
expect("drain_tx_fifo without autopull: pull noblock until empty", dm.writes_to(0x5020_00c8 + 0x18 + 0x10).inject(0) { |a, b| a * 2 + (b == 0x8080 ? 1 : 0) }, 7)
dm2 = DrainModel.new
dm2.mem[0x5020_00c8 + 0x18 + 8] = 1 << 17
Pico::PIO::Block.new(dm2, Pico::RP2040, 0).sm(1).drain_tx_fifo
expect("drain_tx_fifo with autopull: out null, 32", dm2.writes_to(0x5020_00c8 + 0x18 + 0x10).last, 0x6060)

# ---- Encode (test/encode_vs_asm.rb checks every encoder against the assembler)
expect("Encode.irq_wait(false, 1)", Pico::PIO::Encode.irq_wait(false, 1), 0xc021)
expect("Encode.wait_irq(true, true, 2)", Pico::PIO::Encode.wait_irq(true, true, 2), 0x20d2)
raises("Encode.set value 32") { Pico::PIO::Encode.set(:pins, 32) }

# ---- mov_status and clock_div from the directives reach the state machine
# (what Assembled#to_ruby prints for: mov_status :rxfifo, 3; clock_div 2.5; out_pins 5, :left, auto: true, threshold: 16)
ST_PROG = Pico::PIO::Program.new("st", [0xa025], -1, 0, 0, 0, false, false, false, 16, true, nil, nil, false,
                                 0, 5, 0, -1, nil, 0, :txrx, :rxfifo, 3, 2, 128)
pio.sm(2).init(0, ST_PROG.default_config(0))
sm2 = 0x5020_00c8 + 2 * 0x18
expect("directives: SM2_CLKDIV = 2 + 128/256", bus.mem[sm2], (2 << 16) | (128 << 8))
expect("directives: SM2_EXECCTRL STATUS_SEL = RX level (bit 4), STATUS_N = 3, wrap 0 -> 0", bus.mem[sm2 + 4], (1 << 4) | 3)
expect("directives: SM2_SHIFTCTRL shift left, autopull, threshold 16", bus.mem[sm2 + 8], (1 << 17) | (16 << 25) | (1 << 18))

# ---- RP2350: the third PIO block, the moved interrupt registers and the pio_version 1 FIFO modes. Addresses and bits
# are the ones tools/regs_check.sh checks against pico-sdk; nothing here has run on an RP2350
b2 = FakeBus.new
b2.fix(0x4002_0008, 0x1FFF_FFFF)  # RESET_DONE
b2.fix(0x5040_0004, 0)            # PIO2 FSTAT
p2 = Pico::PIO::Block.new(b2, Pico::RP2350, 2)
p2.reset!
expect("RP2350: PIO2 reset is bit 13 of RESETS at 0x40020000", b2.writes_to(0x4002_0000).first, 1 << 13)
p2.gpio_init(25)
expect("RP2350: GPIO25_CTRL = PIO2 (8)", b2.mem[0x4002_80cc], 8)
expect("RP2350: pad 25 at 0x40038068: input enabled, isolation (bit 8) cleared last", b2.writes_to(0x4003_8068).last, 0x40)
V1_PUT = Pico::PIO::Program.new("v1_put", [0x8010, 0x8090], -1, 0, 1, 0, false, false, nil, nil, false, nil, nil, false,
                                0, 0, 0, -1, nil, 1, :putget)
o = p2.add_program(V1_PUT)
expect("RP2350: a pio_version 1 program loads at the top of PIO2 (offset)", o, 30)
expect("RP2350: its first word in INSTR_MEM30", b2.mem[0x5040_0048 + 4 * 30], 0x8010)
p2.sm(1).init(o, V1_PUT.default_config(o))
expect("RP2350: SHIFTCTRL for fifo :putget (FJOIN_RX_PUT and _GET, default shifts right)", b2.mem[0x5040_00c8 + 0x18 + 8], 0x000c_c000)
p2.set_irqn_source_enabled(1, Pico::PIO::PIS_INTERRUPT0 + 5, true)
expect("RP2350: IRQ1_INTE at 0x17c, source 13 (IRQ flag 5)", b2.mem[0x5040_017c], 1 << 13)
b2.mem[0x5040_016c] = 0xFFFF_FFFF
expect("RP2350: INTR at 0x16c, 16 sources", p2.intr, 0xFFFF)
raises("RP2040: a pio_version 1 program") { pio.add_program(V1_PUT) }
V0_PUT = Pico::PIO::Program.new("v0_put", [0xa042], -1, 0, 0, 0, false, false, nil, nil, false, nil, nil, false,
                                0, 0, 0, -1, nil, 0, :txput)
raises("RP2040: fifo :txput") { pio.sm(3).init(0, V0_PUT.default_config(0)) }
V1_ST = Pico::PIO::Program.new("v1_st", [0xa025], -1, 0, 0, 0, false, false, nil, nil, false, nil, nil, false,
                               0, 0, 0, -1, nil, 1, :txrx, :irq, 18, 0, 0)
p2.sm(0).init(0, V1_ST.default_config(0))
expect("RP2350: EXECCTRL STATUS_SEL = IRQ (2 at bit 5), STATUS_N = 18 (flag 2 of the next block)", b2.mem[0x5040_00c8 + 4], (2 << 5) | 18)
V0_ST = Pico::PIO::Program.new("v0_st", [0xa025], -1, 0, 0, 0, false, false, nil, nil, false, nil, nil, false,
                               0, 0, 0, -1, nil, 0, :txrx, :txfifo, 18, 0, 0)
raises("RP2040: mov_status n 18") { pio.sm(3).init(0, V0_ST.default_config(0)) }
raises("PIO block 2 on RP2040") { Pico::PIO::Block.new(bus, Pico::RP2040, 2) }

puts($fail == 0 ? "runtime: all passed" : "runtime: #{$fail} mismatches")
exit($fail == 0 ? 0 : 1)
