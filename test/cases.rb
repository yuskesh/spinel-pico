require_relative "../lib/pico/pio"
class Prelude < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    led.off
    loop { led.on; sleep 2.cycles; led.off; sleep 2.cycles }
  end
end
class Stale < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop { a = inbox.current; b = inbox.current; led.on; sleep a; led.off; sleep b }
  end
end
class StartWait < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main = loop { sleep 2.cycles; led.on }
end
class AfterLoop < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop { led.on; led.off }
    led.on
  end
end
class TwoLoops < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop { led.on }
    loop { led.off }
  end
end
class NoLoop < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main = led.on
end
class FirstInLoop < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    led.off
    loop { sleep 3.cycles; led.on; sleep 2.cycles; led.off }
  end
end
module Board
  class Tick < Pico::PIO::TimedProgram
    clock 1_000_000
    output :led
    def main = loop { led.on; led.off }
  end
end
[Prelude, Stale, StartWait, AfterLoop, TwoLoops, NoLoop, FirstInLoop, Board::Tick].each do |c|
  begin
    c.assemble.report
  rescue => e
    puts "stopped: #{e.message}"
  end
end
puts Board::Tick.assemble.to_c.lines.grep(/define/).join
a = Board::Tick.assemble.assembled
puts "#{a.name} #{a.instructions.map { |w| format('%04x', w) }.join(' ')} wrap #{a.wrap_target}..#{a.wrap}"
