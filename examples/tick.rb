require_relative "../lib/pico/pio"

class Tick < Pico::PIO::TimedProgram
  clock 12_000_000
  output :led

  def main
    loop do
      led.on
      sleep 2.us          # LED on for 24 cycles
      led.off
      sleep 100.cycles    # LED off for 100 cycles
    end
  end
end

prog = Tick.assemble
prog.report
puts prog.to_c
