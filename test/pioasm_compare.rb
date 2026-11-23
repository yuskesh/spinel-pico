require_relative "../lib/pico/pio"
require_relative "timed_ext_programs"
class Square < Pico::PIO::TimedProgram
  clock 12_000_000
  output :speaker
  def main
    loop { half = inbox.current; speaker.on; sleep half; speaker.off; sleep half }
  end
end
class Tick < Pico::PIO::TimedProgram
  clock 12_000_000
  output :led
  def main = loop { led.on; sleep 2.us; led.off; sleep 100.cycles }
end
class FirstInLoop < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    led.off
    loop { sleep 3.cycles; led.on; sleep 2.cycles; led.off }
  end
end
class WS2812Timed < Pico::PIO::TimedProgram
  clock 20_000_000
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
{ "square" => Square, "tick" => Tick, "first_in_loop" => FirstInLoop, "ws2812_timed" => WS2812Timed,
  "two_pins" => TwoPins, "ws2812_side" => WS2812Side, "pulse" => Pulse, "sampler" => Sampler, "irq_tick" => IrqTick,
  "handshake" => Handshake, "phases" => Phases, "nibbles" => Nibbles, "follow" => Follow, "burst" => Burst, "manchester" => Manchester, "gate" => Gate, "preset_pwm" => PresetPwm, "parallel8" => Parallel8, "confirm" => Confirm, "groups" => Groups, "two_reads" => TwoReads, "two_words" => TwoWords,
  "double_pulse" => DoublePulse, "two_inputs" => TwoInputs, "pick_second" => PickSecond,
  "spi_tx" => SpiTx }.each do |n, c|
  pr = c.assemble
  mine = pr.encoded.map { |w| format("%04x", w) }
  ref = File.read(File.join(ARGV[0], "#{n}.hex")).split
  puts "#{n}: #{mine == ref ? 'match' : "MISMATCH #{mine} #{ref}"} / #{pr.to_c.lines.grep(/define/).map(&:strip).join(' ')}"
end
