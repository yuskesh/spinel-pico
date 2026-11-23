# each_bit and bit.pick: check both per-word (inbox.take) and unbroken streaming (inbox.each_bit) with sim, and check that errors are caught
require_relative "../lib/pico/pio"
require_relative "../lib/pico/pio/sim"

class PerWord < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main
    loop do
      word = inbox.take
      word.each_bit(24) do |bit|
        data.on
        sleep bit.pick(800.ns, 400.ns)
        data.off
        sleep bit.pick(450.ns, 850.ns)
      end
    end
  end
end

class Stream < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main
    loop do
      inbox.each_bit(8, order: :lsb) do |bit|
        data.on
        sleep bit.pick(10.cycles, 3.cycles)
        data.off
        sleep 6.cycles
      end
    end
  end
end

$fail = 0
def check(prog, words, n, msb, one, zero, word_gap = 0)
  prog.report
  sim = Pico::PIO::Sim.new(prog.assembled, fifo: words).run(3000)
  bits = words.flat_map { |w| (0...n).map { |i| msb ? (w >> (31 - i)) & 1 : (w >> i) & 1 } }
  bad = []
  sim.pulses.each_with_index do |g, i|
    break if i >= bits.size
    w = bits[i] == 1 ? one : zero
    w = [w[0], w[1] + word_gap] if i % n == n - 1    # last bit of a word (the report's "after the word's last bit +k")
    bad << "bit #{i}: expected #{w.inspect} got #{g.inspect}" if g != w
  end
  puts "  sim: #{[sim.pulses.size, bits.size].min} bits / mismatched bits #{bad.size}"
  bad.each { |b| puts "    #{b}" }
  $fail += bad.size
end

class At12MHz < Pico::PIO::TimedProgram
  clock 12_000_000
  tolerance 150.ns
  output :data
  def main
    loop do
      inbox.each_bit(24) do |bit|
        data.on
        sleep bit.pick(800.ns, 400.ns)
        data.off
        sleep bit.pick(450.ns, 850.ns)
      end
    end
  end
end

class Within < Pico::PIO::TimedProgram          # per-segment within: (takes precedence over tolerance)
  clock 12_000_000
  output :data
  def main
    loop do
      data.on
      sleep 1000.ns, within: 50.ns          # 12 cycles = exactly 1000ns
      data.off
      sleep 700.ns, within: 50.ns           # 8 cycles = 666.7ns (-33.3ns)
    end
  end
end

check(At12MHz.assemble, [0xA5C30000, 0x3C000000], 24, true, [10, 5], [5, 10])
w = Within.assemble
w.report
$fail += 1 unless w.cycles == [0, 20]
check(PerWord.assemble, [0xAACCF000, 0x0F3355FF], 24, true, [16, 9], [8, 17], 1)   # the word's last bit has Low +1, as the report says
check(Stream.assemble, [0x000000A5, 0x0000003C], 8, false, [10, 6], [3, 6])

class TooShort < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main = loop { inbox.each_bit(8) { |b| data.on; sleep b.pick(1.cycles, 3.cycles); data.off; sleep 3.cycles } }
end
class PickOutside < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main = loop { data.on; sleep Pico::PIO::Bit.new.pick(2.cycles, 3.cycles); data.off }
end
class TwoBitLoops < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main
    loop do
      w = inbox.take
      w.each_bit(4) { |b| data.on; sleep b.pick(8.cycles, 4.cycles); data.off; sleep 4.cycles }
      w.each_bit(4) { |b| data.on; sleep b.pick(8.cycles, 4.cycles); data.off; sleep 4.cycles }
    end
  end
end
class StreamNotFirst < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main = loop { data.off; inbox.each_bit(8) { |b| data.on; sleep b.pick(4.cycles, 2.cycles); data.off; sleep 4.cycles } }
end
class AfterStream < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main = loop { inbox.each_bit(8) { |b| data.on; sleep b.pick(4.cycles, 2.cycles); data.off; sleep 4.cycles }; data.on }
end
class UnusedBit < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main = loop { w = inbox.take; w.each_bit(8) { |b| data.on; sleep 4.cycles; data.off; sleep 4.cycles } }
end
class MixInbox < Pico::PIO::TimedProgram
  clock 20_000_000
  output :data
  def main = loop { n = inbox.current; w = inbox.take; data.on; sleep n; data.off }
end
class NoTolerance < Pico::PIO::TimedProgram     # 800ns at 12MHz is not exact, and no tolerance is given
  clock 12_000_000
  output :data
  def main = loop { data.on; sleep 800.ns; data.off; sleep 800.ns }
end
class OverTolerance < Pico::PIO::TimedProgram   # 450ns at 12MHz is 5 cycles (-33.3ns), exceeding the 20ns tolerance
  clock 12_000_000
  tolerance 20.ns
  output :data
  def main = loop { data.on; sleep 450.ns; data.off; sleep 450.ns }
end
class WithinNarrower < Pico::PIO::TimedProgram  # tolerance is wide, but within: is narrower
  clock 12_000_000
  tolerance 150.ns
  output :data
  def main = loop { data.on; sleep 450.ns, within: 10.ns; data.off; sleep 450.ns }
end
class RoundsToZero < Pico::PIO::TimedProgram    # 30ns rounds to 0 cycles
  clock 12_000_000
  tolerance 50.ns
  output :data
  def main = loop { data.on; sleep 30.ns; data.off; sleep 1.us }
end
[NoTolerance, OverTolerance, WithinNarrower, RoundsToZero, TooShort, PickOutside, TwoBitLoops, StreamNotFirst, AfterStream, UnusedBit, MixInbox].each do |c|
  begin
    c.assemble
    puts "passed unexpectedly: #{c}"
    $fail += 1
  rescue => e
    puts "stopped: #{e.message}"
  end
end
puts($fail == 0 ? "bits: all passed" : "bits: #{$fail} mismatches")
exit($fail == 0 ? 0 : 1)
