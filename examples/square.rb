require_relative "../lib/pico/pio"
class Square < Pico::PIO::TimedProgram
  clock 12_000_000
  output :speaker
  def main
    loop do
      half = inbox.current
      speaker.on
      sleep half
      speaker.off
      sleep half
    end
  end
end
p = Square.assemble
p.report
puts p.to_c
