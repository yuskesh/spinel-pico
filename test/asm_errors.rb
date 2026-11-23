# Does Pico::PIO.asm reject invalid code? Writes the same mistake as .pio and shows side by side whether pioasm rejects it too
#   ruby test/asm_errors.rb [pioasm]
require "tmpdir"
require_relative "../lib/pico/pio/asm"

pioasm = ARGV[0]
many = (".program many\n" + "    nop\n" * 33)
CASES = [
  ["33 instructions",             -> { Pico::PIO.asm(:t) { 33.times { nop } } }, many],
  ["side-set 1 with delay 16", -> { Pico::PIO.asm(:t, side_set: 1) { nop side: 0, delay: 16 } }, ".program t\n.side_set 1\n    nop side 0 [16]\n"],
  ["side-set 1 opt with delay 8", -> { Pico::PIO.asm(:t, side_set: 1, side_set_opt: true) { nop delay: 8 } }, ".program t\n.side_set 1 opt\n    nop [8]\n"],
  ["missing side (not opt)", -> { Pico::PIO.asm(:t, side_set: 1) { nop } }, ".program t\n.side_set 1\n    nop\n"],
  ["side value does not fit in 2 bits", -> { Pico::PIO.asm(:t, side_set: 2) { nop side: 4 } }, ".program t\n.side_set 2\n    nop side 4\n"],
  ["side without side_set", -> { Pico::PIO.asm(:t) { nop side: 1 } }, ".program t\n    nop side 1\n"],
  ["undefined label",           -> { Pico::PIO.asm(:t) { jmp :nowhere } }, ".program t\n    jmp nowhere\n"],
  ["label defined twice",          -> { Pico::PIO.asm(:t) { label :a; nop; label :a; nop } }, ".program t\na:\n    nop\na:\n    nop\n"],
  ["set value 32",            -> { Pico::PIO.asm(:t) { set :x, 32 } }, ".program t\n    set x, 32\n"],
  ["out bit count 0",        -> { Pico::PIO.asm(:t) { out :x, 0 } }, ".program t\n    out x, 0\n"],
  ["in bit count 33",        -> { Pico::PIO.asm(:t) { in_ :x, 33 } }, ".program t\n    in x, 33\n"],
  ["set destination isr",       -> { Pico::PIO.asm(:t) { set :isr, 1 } }, ".program t\n    set isr, 1\n"],
  ["mov source pc",            -> { Pico::PIO.asm(:t) { mov :x, :pc } }, ".program t\n    mov x, pc\n"],
  ["in source pc",             -> { Pico::PIO.asm(:t) { in_ :pc, 1 } }, ".program t\n    in pc, 1\n"],
  ["out destination status",    -> { Pico::PIO.asm(:t) { out :status, 1 } }, ".program t\n    out status, 1\n"],
  ["irq index 8",           -> { Pico::PIO.asm(:t) { irq 8 } }, ".program t\n    irq 8\n"],
  ["wait irq index 8",      -> { Pico::PIO.asm(:t) { wait 1, :irq, 8 } }, ".program t\n    wait 1 irq 8\n"],
  ["wait gpio 32",           -> { Pico::PIO.asm(:t) { wait 1, :gpio, 32 } }, ".program t\n    wait 1 gpio 32\n"],
  ["wait jmppin on v0",      -> { Pico::PIO.asm(:t) { wait 1, :jmppin, 0 } }, ".program t\n    wait 1 jmppin\n"],
  ["mov pindirs on v0",      -> { Pico::PIO.asm(:t) { mov :pindirs, :x } }, ".program t\n    mov pindirs, x\n"],
  ["wait jmppin + 4",        -> { Pico::PIO.asm(:t, pio_version: 1) { wait 1, :jmppin, 4 } }, ".pio_version 1\n.program t\n    wait 1 jmppin + 4\n"],
  ["delay 32",               -> { Pico::PIO.asm(:t) { nop delay: 32 } }, ".program t\n    nop [32]\n"],
  ["unknown jmp condition name",   -> { Pico::PIO.asm(:t) { label :a; jmp :x_inc, :a } }, nil],
  ["wrap twice",           -> { Pico::PIO.asm(:t) { nop; wrap; nop; wrap } }, ".program t\n    nop\n.wrap\n    nop\n.wrap\n"],
]

fail = 0
Dir.mktmpdir do |dir|
  CASES.each do |title, rb, pio|
    mine = begin
      rb.call
      "accepted"
    rescue Pico::PIO::AsmError => e
      "rejected (#{e.message})"
    end
    ref = "-"
    if pioasm && pio
      f = File.join(dir, "t.pio")
      File.write(f, pio)
      ok = system(pioasm, "-o", "hex", f, out: File::NULL, err: File::NULL)
      ref = ok ? "accepted" : "rejected"
    end
    same = ref == "-" || (mine.start_with?("rejected") == (ref == "rejected"))
    fail += 1 unless same && mine.start_with?("rejected")
    puts "#{same ? '  ' : '!!'} #{title}: Ruby #{mine} / pioasm #{ref}"
  end
end
puts(fail == 0 ? "all rejected (same as pioasm)" : "#{fail} cases differ")
exit(fail == 0 ? 0 : 1)
