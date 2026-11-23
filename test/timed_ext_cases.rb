# Time layer extensions: side-set outputs, inputs (wait, sample), outbox (push, autopush) and IRQ flags.
# Checks the timing with sim and that errors are caught
require_relative "../lib/pico/pio"
require_relative "../lib/pico/pio/sim"
require_relative "timed_ext_programs"

$fail = 0
def expect(what, got, want)
  if got == want
    puts "  ok: #{what}"
  else
    puts "  FAIL: #{what}: got #{got.inspect}, expected #{want.inspect}"
    $fail += 1
  end
end

def sim(c, **kw)
  pr = c.assemble
  pr.report
  Pico::PIO::Sim.new(pr.assembled, **kw)
end

s = sim(TwoPins).run(100)
expect("TwoPins: data High / Low", s.pulses.uniq, [[5, 5]])
expect("TwoPins: clk High / Low", s.side_pulses(0).uniq, [[3, 7]])
expect("TwoPins: clk rises with data", s.side_edges.select { |e| e[2] == 1 }.map { |e| e[0] }, s.edges.select { |e| e[1] == 1 }.map { |e| e[0] })

words = [0xA5C3_0000, 0x0F00_0000]
s = sim(WS2812Side, fifo: words).run(2000)
bits = words.flat_map { |w| (0...24).map { |i| (w >> (31 - i)) & 1 } }
got = s.side_pulses(0).first(bits.size - 1)
want = bits.first(bits.size - 1).map { |b| b == 1 ? [16, 9] : [8, 17] }
expect("WS2812Side: 47 bits as 16 / 9 (1) and 8 / 17 (0) cycles", got, want)

s = sim(Pulse, inputs: [[10, 1], [40, 0], [60, 1], [90, 0]]).run(120)
expect("Pulse: led rises 1 cycle after each button rise, High 10", s.edges, [[11, 1], [21, 0], [61, 1], [71, 0]])

byte_in = []
8.times do |i|
  b = (0xA5 >> (7 - i)) & 1
  t = 10 + 20 * i
  byte_in << [t, b]
  byte_in << [t + 5, b | 2]
  byte_in << [t + 15, b]
end
s = sim(Sampler, inputs: byte_in).run(200)
expect("Sampler: 8 bits at the sclk rises, MSB first, pushed as one word", s.rx, [0xA5])

s = sim(IrqTick).run(450)
expect("IrqTick: IRQ flag 0 set every 100 cycles", s.irq_log, [[0, 0], [100, 0], [200, 0], [300, 0], [400, 0]])

s = sim(Handshake, irq_clears: [[50, 1], [200, 1]]).run(300)
expect("Handshake: flag 1 raised, ready pulses 5 cycles after each clear", s.side_edges, [[51, 0, 1], [56, 0, 0], [201, 0, 1], [206, 0, 0]])
expect("Handshake: flag raised again 10 cycles after the pulse starts", s.irq_log, [[0, 1], [61, 1], [211, 1]])


# ---- several SET pins, sample(width), input pick, repeat, OUT pin
s = sim(Phases).run(100)
expect("Phases: a High 2 / Low 8", s.set_pulses(0).uniq, [[2, 8]])
expect("Phases: b High 5 / Low 5", s.set_pulses(1).uniq, [[5, 5]])
expect("Phases: a and b rise together", s.set_edges.select { |e| e[2] == 1 }.map { |e| e[0] }.uniq.size, s.set_pulses(0).size + 1)

nib = []
[0x5, 0xA, 0x3, 0xC].each_with_index do |v, i|
  t = 10 + 20 * i
  nib << [t, v]
  nib << [t + 5, v | 16]
  nib << [t + 15, v]
end
s = sim(Nibbles, inputs: nib).run(120)
# shifting right, the 8 bits fill the ISR from the top: the byte is in bits 24-31 of the word pushed
expect("Nibbles: 4 pins per sample, two samples per byte (LSB first, in the top byte)", s.rx, [0xA500_0000, 0xC300_0000])

s = sim(Follow, inputs: [[0, 1], [60, 0]], jmp_pin: 0).run(120)
expect("Follow: High 10 while the input is high, 3 after it goes low", s.pulses.map { |x| x[0] }.uniq, [10, 3])
expect("Follow: Low 5 throughout", s.pulses.map { |x| x[1] }.uniq, [5])

s = sim(Burst).run(4000)
ps = s.pulses
expect("Burst: 20 periods of 9 / 17, then 9 / 1000, repeating", ps.first(42),
       (Array.new(20) { [9, 17] } + [[9, 1000]]) * 2)

words = [0xB400_0000, 0x0F00_0000]       # bytes 0xB4 and 0x0F
s = sim(SpiTx, fifo: words).run(80)
bits = [1, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1]
mosi = bits.each_with_index.map { |b, i| t = 4 * i; lv = 0; s.out_edges.each { |e| lv = e[1] if e[0] <= t + 1 }; lv }
expect("SpiTx: MOSI holds each bit (sampled just after it is put)", mosi, bits)
# SCK idles High (its level at the end of the loop), so it starts High at cycle 0; bits are put at 1, 5, 9, ...
expect("SpiTx: SCK High 2 / Low 2", s.side_pulses(0).drop(1).uniq, [[2, 2]])
expect("SpiTx: SCK rises 2 cycles after each bit is put", s.side_edges.select { |e| e[2] == 1 && e[0] > 0 }.first(3).map { |e| e[0] }, [3, 7, 11])

s = sim(LongPick, inputs: [[0, 1], [5500, 0]], jmp_pin: 0).run(12_000)
# the input falls at 5500, inside the wait that began at 5000 (read high): that wait is still 1000
expect("LongPick: 1000 while high, 3000 after the input falls, read when each wait begins",
       s.irq_log.map { |e| e[0] }.each_cons(2).map { |x| x[1] - x[0] }, [1000, 1000, 1000, 1000, 1000, 1000, 3000])

# ---- the side-set bits shrink the delay field: one side-set pin leaves 15
class LongSide < Pico::PIO::TimedProgram
  clock 1_000_000
  output :clk, side: true
  def main = loop { clk.on; sleep 20.us; clk.off; sleep 20.us }
end
s = sim(LongSide).run(200)
expect("LongSide: 20 / 20 with delays of at most 15", s.side_pulses(0).uniq, [[20, 20]])
expect("LongSide: no delay above 15", LongSide.assemble.encoded.all? { |w| ((w >> 8) & 0xF) <= 15 }, true)

# ---- errors
def rejects(what, msg)
  yield
  puts "  FAIL: #{what}: not rejected"
  $fail += 1
rescue RuntimeError => e
  if e.message.include?(msg)
    puts "  ok: rejected #{what}: #{e.message}"
  else
    puts "  FAIL: #{what}: wrong error #{e.message}"
    $fail += 1
  end
end

class TwiceSide < Pico::PIO::TimedProgram
  clock 1_000_000
  output :clk, side: true
  def main = loop { clk.on; clk.off; sleep 2.us }
end
rejects("the same side-set pin changed twice at one point", "already changes") { TwiceSide.assemble }

class SampleSecond < Pico::PIO::TimedProgram
  clock 1_000_000
  input :a
  input :b
  def main = loop { b.sample; sleep 2.us }
end
rejects("sampling an input other than the first", "only the first input") { SampleSecond.assemble }

class TwoAutopush < Pico::PIO::TimedProgram
  clock 1_000_000
  input :a
  def main
    outbox.autopush(8)
    outbox.autopush(16)
    loop { a.sample; sleep 2.us }
  end
end
rejects("outbox.autopush twice", "only once") { TwoAutopush.assemble }

class BadIrq < Pico::PIO::TimedProgram
  clock 1_000_000
  def main = loop { irq(8).set; sleep 2.us }
end
rejects("IRQ flag 8", "0-7") { BadIrq.assemble }

class SixSides < Pico::PIO::TimedProgram
  clock 1_000_000
  output :s0, side: true
  output :s1, side: true
  output :s2, side: true
  output :s3, side: true
  output :s4, side: true
  output :s5, side: true
  def main = loop { s0.on; sleep 2.us; s0.off; sleep 2.us }
end
rejects("six side-set outputs", "at most 5") { SixSides.assemble }



class TripleRepeat < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main = loop { repeat(2) { repeat(2) { repeat(2) { led.on; sleep 2.us; led.off; sleep 2.us } } } }
end
rejects("a third level of repeat", "nested only once") { TripleRepeat.assemble }

class BitsInInner < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop do
      repeat(2) do
        repeat(2) do
          w = inbox.take
          w.each_bit(4) { |bit| led.on; sleep bit.pick(6.cycles, 3.cycles); led.off; sleep 4.cycles }
        end
      end
    end
  end
end
rejects("each_bit inside a repeat inside a repeat (both need Y)", "counts in Y") { BitsInInner.assemble }

class RepeatCurrent < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop do
      n = inbox.current
      repeat(3) { led.on; sleep n; led.off; sleep 2.us }
    end
  end
end
rejects("repeat with inbox.current (both use X)", "inbox.current uses") { RepeatCurrent.assemble }

class RepeatSleepFirst < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main = loop { led.off; repeat(3) { sleep 2.us; led.on; sleep 2.us; led.off } }
end
rejects("a repeat body starting with a sleep", "cannot start with a sleep") { RepeatSleepFirst.assemble }

class PutOutside < Pico::PIO::TimedProgram
  clock 1_000_000
  output :mosi, out: true
  def main = loop { mosi.put(1); sleep 2.us }
end
rejects("put outside each_bit", "only inside each_bit") { PutOutside.assemble }

class PutOnSet < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main = loop { inbox.each_bit(8) { |bit| led.put(bit); sleep 2.us } }
end
rejects("put on a SET pin", "only an OUT pin") { PutOnSet.assemble }

class WideSample < Pico::PIO::TimedProgram
  clock 1_000_000
  input :a
  input :b
  def main = loop { a.sample(3); sleep 2.us }
end
rejects("sample wider than the inputs", "width must be 1-2") { WideSample.assemble }

class ShortLow < Pico::PIO::TimedProgram
  clock 1_000_000
  input :mode
  output :led
  def main = loop { led.on; sleep mode.pick(10.us, 2.us); led.off; sleep 5.us }
end
rejects("a low wait shorter than the jmp pin branch", "too short a wait for mode low") { ShortLow.assemble }

# ---- branch: different statements per path
s = sim(Manchester, fifo: [0xA500_0000]).run(80)
level = ->(t) { s.set_edges.select { |e| e[0] <= t }.map { |e| e[2] }.last || 0 }
# bit k starts at 2 + 8k (after out y, 1 and jmp !y); its halves are sampled in their middles
halves = (0...8).map { |k| [level.(2 + 8 * k + 2), level.(2 + 8 * k + 6)] }
expect("Manchester: 4-cycle halves, bit 1 = low then high, bit 0 = high then low (0xA5)", halves,
       [1, 0, 1, 0, 0, 1, 0, 1].map { |b| [1 - b, b] })
expect("Manchester: every edge on a 4-cycle boundary from the first bit", s.set_edges.all? { |e| (e[0] - 2) % 4 == 0 }, true)
s = sim(Gate, inputs: [[0, 1], [30, 0]], jmp_pin: 0).run(60)
expect("Gate: flag 2 every 11 cycles while din is high, then every 7", s.irq_log.select { |e| e[1] == 2 }.map { |e| e[0] },
       [0, 11, 22, 33, 40, 47, 54])
expect("Gate: flag 0 (high path) 6 after flag 2, flag 1 (low path) 2 after", s.irq_log.reject { |e| e[1] == 2 }.map { |e| e[0] },
       [6, 17, 28, 35, 42, 49, 56])
expect("Gate: led pulses 3 cycles only while high", s.set_pulses(0), [[3, 8], [3, 8]])
s = sim(SideJoin, inputs: [[0, 1], [20, 0]], jmp_pin: 0).run(40)
expect("SideJoin: flag 3 three cycles after flag 1 (high), two after flag 2 (low)",
       s.irq_log.each_cons(2).select { |a| a[1][1] == 3 }.map { |a| [a[0][1], a[1][0] - a[0][0]] }.uniq, [[1, 3], [2, 2]])
expect("SideJoin: clk high from the high path's first statement to the statement after the branch", s.side_pulses(0).uniq, [[3, 3]])
rejects("side-set paths that end at different levels with nothing setting the pin after", "left at different levels") { SideSplit.assemble.encoded }

s = sim(Confirm, inputs: [[0, 1], [10, 0], [20, 1], [25, 0]], jmp_pin: 0).run(40)
# a pass every 10 cycles: btn read 1 cycle after flag 3 and, after a high, again at 6
expect("Confirm: flag 0 if btn is high at both reads, flag 1 if it fell in between, flag 2 if low at the first",
       s.irq_log.reject { |e| e[1] == 3 }, [[7, 0], [12, 2], [27, 1], [32, 2]])
expect("Confirm: flag 3 every 10 cycles whichever path ran", s.irq_log.select { |e| e[1] == 3 }.map { |e| e[0] }, [0, 10, 20, 30])

class BitInBit < Pico::PIO::TimedProgram
  clock 1_000_000
  output :tx
  def main
    loop do
      inbox.each_bit(8) do |bit|
        bit.branch do |one|
          bit.branch { |again| tx.on }
          sleep 4.cycles
        end
      end
    end
  end
end
rejects("a bit.branch inside a bit.branch", "already known") { BitInBit.assemble }

class OneSidedSleep < Pico::PIO::TimedProgram
  clock 1_000_000
  input :din
  output :led
  def main
    loop do
      led.on
      din.branch do |high|
        if high
          led.off
          sleep 3.us
        else
          led.off
        end
      end
    end
  end
end
rejects("a branch with a sleep at the end of only one path", "both paths end with a sleep") { OneSidedSleep.assemble }

# inputs: bit 0 = en (the JMP pin), bit 1 = dir (read through the OSR into Y)
s = sim(TwoInputs, inputs: [[0, 3], [9, 1], [18, 0], [27, 2]], jmp_pin: 0).run(40)
expect("TwoInputs: en and dir high: flag 0; dir low: flag 1; en low: flag 2 whatever dir is; 9 cycles per pass",
       s.irq_log, [[0, 4], [6, 0], [9, 4], [15, 1], [18, 4], [20, 2], [27, 4], [29, 2], [36, 4], [38, 2]])
s = sim(PickSecond, inputs: [[0, 3], [30, 1], [60, 2], [90, 0]], jmp_pin: 0).run(130)
expect("PickSecond: High 5 / 3 by en, Low 12 / 6 by rate", s.pulses,
       [[5, 12], [5, 12], [5, 6], [5, 6], [5, 12], [3, 12], [3, 6], [3, 6], [3, 6], [3, 6]])

class SecondWithInbox < Pico::PIO::TimedProgram
  clock 1_000_000
  input :a
  input :b
  output :led
  def main
    loop do
      n = inbox.current
      led.on
      sleep a.pick(3.us, 5.us)
      led.off
      sleep b.pick(8.us, 12.us)
    end
  end
end
rejects("a second input to branch on together with inbox (both use the OSR)", "read through the OSR") { SecondWithInbox.assemble }

class SecondThenInbox < Pico::PIO::TimedProgram
  clock 1_000_000
  input :a
  input :b
  output :led
  def main
    loop do
      led.on
      sleep a.pick(3.us, 5.us)
      led.off
      sleep b.pick(8.us, 12.us)
      n = inbox.current
    end
  end
end
rejects("inbox after a second input was branched on", "inbox uses the OSR") { SecondThenInbox.assemble }

class SecondInBits < Pico::PIO::TimedProgram
  clock 1_000_000
  input :a
  input :b
  output :led
  def main
    loop do
      sleep 1.cycles if false
      led.on
      sleep a.pick(3.us, 5.us)
      w = Pico::PIO::Word.new(self)
      w.each_bit(8) { |bit| led.off; sleep b.pick(8.us, 12.us) }
    end
  end
end
rejects("a second input to branch on inside each_bit", "which each_bit uses") { SecondInBits.assemble }

class BitBranchOutside < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main = loop { led.on; Pico::PIO::Bit.new(self).branch { |o| led.off }; sleep 2.us }
end
rejects("bit.branch outside each_bit", "only inside each_bit") { BitBranchOutside.assemble }

s = sim(Groups).run(120)
expect("Groups: 3 pulses 2 / 3, the third Low 13; after the second group Low 33", s.pulses.first(6), [[2, 3], [2, 3], [2, 13], [2, 3], [2, 3], [2, 33]])
s = sim(TwoReads, inputs: [[0, 1], [7, 0]], jmp_pin: 0).run(36)
expect("TwoReads: flag 2, the path's flag 2 later, the next read 4 after that; flag 3 after two reads, 5 to the next pass",
       s.irq_log.first(8), [[1, 2], [3, 0], [7, 2], [9, 1], [13, 3], [18, 2], [20, 1], [24, 2]])
s = sim(TwoWords, fifo: [0xA000_0000, 0x3000_0000, 0xF000_0000]).run(90)
expect("TwoWords: bits 1010 then 0011 as High 6 / 3; flag 0 after the second word", [s.pulses.first(8).map { |pl| pl[0] }, s.irq_log.first(1).size],
       [[6, 3, 6, 3, 3, 3, 6, 6], 1])
s = sim(DoublePulse, fifo: [0xA500_0000, 0xA500_0000]).run(200)
expect("DoublePulse: two pulses per bit, then Low 2 + 8 for a 1 and 2 + 4 for a 0 (0xA5)", s.pulses.first(16).each_slice(2).map { |a, b| [a, b[1]] },
       [1, 0, 1, 0, 0, 1, 0, 1].map { |b| [[2, 2], b == 1 ? 10 : 6] })

class ShortTail < Pico::PIO::TimedProgram
  clock 1_000_000
  output :tx
  def main
    loop do
      inbox.each_bit(8) do |bit|
        bit.branch do |one|
          one ? tx.on : tx.off
          sleep 2.cycles
        end
      end
    end
  end
end
rejects("a path's last sleep shorter than the jmp to the end and the next bit's out / jmp", "too short") { ShortTail.assemble }

# ---- inbox.preset: the second value, in the ISR
s = sim(PresetPwm, fifo: [10, 20], isr: 30).run(300)
expect("PresetPwm: High n + 3 (13, then 23 after the second word), Low m + 5 (35)", s.pulses.first(4), [[13, 35], [23, 35], [23, 35], [23, 35]])

class PresetSample < Pico::PIO::TimedProgram
  clock 1_000_000
  input :din
  output :led
  def main
    period = inbox.preset
    loop do
      led.on
      din.sample
      sleep period
    end
  end
end
rejects("inbox.preset with sample (both use the ISR)", "inbox.preset keeps its value in the ISR") { PresetSample.assemble }

# ---- out pins, n: inbox.next with autopull
s = sim(Parallel8, fifo: [0x1234_5678, 0xFEDC_BA98]).run(40)
expect("Parallel8: a byte every 4 cycles, MSB first", s.out_writes.map { |w| w[1] }, [0x12, 0x34, 0x56, 0x78, 0xFE, 0xDC, 0xBA, 0x98])
expect("Parallel8: wr rises 2 cycles after each byte", s.side_edges.select { |e| e[2] == 1 }.map { |e| e[0] }.first(4), [2, 6, 10, 14])

class WidthMismatch < Pico::PIO::TimedProgram
  clock 1_000_000
  output :data, out: true, width: 8
  def main = loop { data.write(inbox.next(4)); sleep 2.cycles }
end
rejects("inbox.next(4) onto 8 OUT pins", "must match") { WidthMismatch.assemble }

class NextAndCurrent < Pico::PIO::TimedProgram
  clock 1_000_000
  output :data, out: true, width: 8
  def main
    loop do
      n = inbox.current
      data.write(inbox.next(8))
      sleep n
    end
  end
end
rejects("inbox.next with inbox.current", "cannot be used together") { NextAndCurrent.assemble }

puts($fail == 0 ? "timed extensions: all passed" : "timed extensions: #{$fail} failed")
exit($fail == 0 ? 0 : 1)
