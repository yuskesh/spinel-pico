# WS2812 written in the instruction layer (same as pico-examples' ws2812.pio)
require_relative "../lib/pico/pio/asm"

code = Pico::PIO.asm(:ws2812, side_set: 1) do
  t1 = define(:T1, 3, public: true)
  t2 = define(:T2, 3, public: true)
  t3 = define(:T3, 4, public: true)
  wrap_target
  label :bitloop
  out :x, 1, side: 0, delay: t3 - 1        # side-set is driven even while the instruction is stalled
  jmp :not_x, :do_zero, side: 1, delay: t1 - 1
  label :do_one
  jmp :bitloop, side: 1, delay: t2 - 1
  label :do_zero
  nop side: 0, delay: t2 - 1
  wrap
end

puts code.to_hex
puts code.to_c
begin
  Pico::PIO.asm(:bad, side_set: 1) { nop side: 0, delay: 16 }
rescue Pico::PIO::AsmError => e
  puts "stopped: #{e.message}"
end
