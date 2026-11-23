require_relative "../lib/pico/pio"
class Fast < Pico::PIO::TimedProgram
  clock 12_000_000
  output :led
  def main
    loop { led.on; sleep 1.us; led.off; sleep 1.us }
  end
end
class Slow < Pico::PIO::TimedProgram
  clock 1_000_000
  output :led
  def main
    loop { led.on; sleep 1.us; led.off; sleep 1.us }
  end
end
class NoClock < Pico::PIO::TimedProgram
  output :led
  def main = loop { led.on; sleep 1.us }
end
Fast.assemble.report
Slow.assemble.report
begin
  NoClock.assemble
rescue => e
  puts "stopped: #{e.message}"
end
