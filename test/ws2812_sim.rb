# Run the WS2812 from examples/ws2812.rb in sim and check that each bit's High/Low match the written lengths
require_relative "../lib/pico/pio"
require_relative "../lib/pico/pio/sim"
load File.expand_path("../examples/ws2812.rb", __dir__) unless defined?(WS2812)

code = WS2812.assemble.assembled
words = [0xAACCF000, 0x0F3355FF]          # the low 8 bits are unused (only 24 bits are output)
sim = Pico::PIO::Sim.new(code, fifo: words).run(2000)
bits = words.flat_map { |w| (0...24).map { |i| (w >> (31 - i)) & 1 } }
want = bits.map { |b| b == 1 ? [16, 9] : [8, 17] }
got = sim.pulses
fail = 0
got.each_with_index do |g, i|
  w = want[i]
  break if w.nil?
  extra = (i % 24 == 23) ? " (end of word)" : ""
  if g != w
    fail += 1
    puts "bit #{i}: expected #{w.inspect} got #{g.inspect}#{extra}"
  end
end
puts "#{got.size} bits checked: #{fail} bits with High/Low not as written"
