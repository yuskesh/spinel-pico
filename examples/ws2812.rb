# WS2812 written in the time layer (1 bit = 1.25us; 1 is High 0.8us + Low 0.45us, 0 is High 0.4us + Low 0.85us)
require_relative "../lib/pico/pio"

class WS2812 < Pico::PIO::TimedProgram
  clock 20_000_000            # 1 cycle = 50ns
  output :data

  def main
    loop do
      inbox.each_bit(24) do |bit|   # words with GRB 24 bits packed at the top (0xGGRRBB00), 1 bit at a time with no gap between words
        data.on
        sleep bit.pick(800.ns, 400.ns)
        data.off
        sleep bit.pick(450.ns, 850.ns)
      end
    end
  end
end

prog = WS2812.assemble
prog.report
puts prog.to_c
