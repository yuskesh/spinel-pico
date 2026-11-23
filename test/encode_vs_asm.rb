# Check every Pico::PIO::Encode encoder (on-device, for exec) against the assembler layer (host-only, itself checked
# against pioasm by asm_vs_pioasm.rb). CRuby only: the assembler uses instance_eval.
require_relative "../lib/pico/pio/asm"
require_relative "../lib/pico/pio/encode"

E = Pico::PIO::Encode
$fail = 0
$n = 0

# The instruction under test is followed by nops up to 32 words, so that any jmp target is inside the program
def same(what, got, &block)
  want = Pico::PIO.asm(:t) do
    instance_eval(&block)
    31.times { nop }
  end.instructions[0]
  $n += 1
  return if got == want
  $fail += 1
  puts format("MISMATCH %s: Encode 0x%04x, asm 0x%04x", what, got, want)
end

[0, 7, 31].each do |a|
  same("jmp #{a}", E.jmp(a)) { jmp a }
  same("jmp !x #{a}", E.jmp_not_x(a)) { jmp :not_x, a }
  same("jmp x-- #{a}", E.jmp_x_dec(a)) { jmp :x_dec, a }
  same("jmp !y #{a}", E.jmp_not_y(a)) { jmp :not_y, a }
  same("jmp y-- #{a}", E.jmp_y_dec(a)) { jmp :y_dec, a }
  same("jmp x!=y #{a}", E.jmp_x_ne_y(a)) { jmp :x_ne_y, a }
  same("jmp pin #{a}", E.jmp_pin(a)) { jmp :pin, a }
  same("jmp !osre #{a}", E.jmp_not_osre(a)) { jmp :not_osre, a }
end
[0, 1].each do |pol|
  [0, 13, 31].each do |i|
    same("wait #{pol} gpio #{i}", E.wait_gpio(pol == 1, i)) { wait pol, :gpio, i }
    same("wait #{pol} pin #{i}", E.wait_pin(pol == 1, i)) { wait pol, :pin, i }
  end
  [0, 7].each do |i|
    same("wait #{pol} irq #{i}", E.wait_irq(pol == 1, false, i)) { wait pol, :irq, i }
    same("wait #{pol} irq #{i} rel", E.wait_irq(pol == 1, true, i)) { wait pol, :irq, i, rel: true }
  end
end
%i[pins x y null isr osr].each do |s|
  [1, 8, 32].each { |n| same("in #{s}, #{n}", E.in_(s, n)) { in_ s, n } }
end
%i[pins x y null pindirs pc isr exec].each do |d|
  [1, 8, 32].each { |n| same("out #{d}, #{n}", E.out(d, n)) { out d, n } }
end
[false, true].each do |f|
  [false, true].each do |b|
    same("push iffull #{f} block #{b}", E.push(f, b)) { push iffull: f, block: b }
    same("pull ifempty #{f} block #{b}", E.pull(f, b)) { pull ifempty: f, block: b }
  end
end
%i[pins x y exec pc isr osr].each do |d|
  %i[pins x y null status isr osr].each do |s|
    same("mov #{d}, #{s}", E.mov(d, s)) { mov d, s }
    same("mov #{d}, !#{s}", E.mov_not(d, s)) { mov d, s, op: :invert }
    same("mov #{d}, ::#{s}", E.mov_reverse(d, s)) { mov d, s, op: :reverse }
  end
end
[0, 3, 7].each do |i|
  [false, true].each do |r|
    same("irq set #{i} rel #{r}", E.irq_set(r, i)) { irq :set, i, rel: r }
    same("irq wait #{i} rel #{r}", E.irq_wait(r, i)) { irq :wait, i, rel: r }
    same("irq clear #{i} rel #{r}", E.irq_clear(r, i)) { irq :clear, i, rel: r }
  end
end
%i[pins x y pindirs].each do |d|
  [0, 1, 31].each { |v| same("set #{d}, #{v}", E.set(d, v)) { set d, v } }
end
same("nop", E.nop) { nop }

puts($fail == 0 ? "encode: all #{$n} encoders match the assembler" : "encode: #{$fail} of #{$n} mismatches")
exit($fail == 0 ? 0 : 1)
