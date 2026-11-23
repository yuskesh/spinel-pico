# Convert .pio files (pico-examples etc.) to Ruby with tools/pio2rb.rb and compare the Pico::PIO.asm result with pioasm (-o json)
#   ruby test/asm_vs_pioasm.rb <pioasm> <.pio ...>
require "json"
require_relative "../lib/pico/pio/asm"
require_relative "../tools/pio2rb"

pioasm = ARGV.shift
ok = 0
bad = 0
ARGV.each do |path|
  ref = JSON.parse(`#{pioasm} -o json #{path}`)["programs"]
  rb = Pio2Rb.new.convert(File.read(path))
  PROGRAMS = [] unless defined?(PROGRAMS)
  PROGRAMS.clear
  begin
    eval(rb, binding, path + ".rb")
  rescue => e
    puts "FAILED #{path}: #{e.message}"
    bad += 1
    next
  end
  ref.each_with_index do |r, k|
    m = PROGRAMS[k]
    diffs = []
    if m.nil?
      diffs << "missing on the Ruby side"
    else
      words = r["instructions"].map { |x| x["hex"].to_i(16) }
      diffs << "instructions #{m.instructions.map { |w| format('%04x', w) }} != #{words.map { |w| format('%04x', w) }}" if m.instructions != words
      diffs << "wrap_target #{m.wrap_target} != #{r['wrapTarget']}" if m.wrap_target != r["wrapTarget"]
      diffs << "wrap #{m.wrap} != #{r['wrap']}" if m.wrap != r["wrap"]
      diffs << "origin #{m.origin} != #{r['origin']}" if m.origin != r["origin"]
      diffs << "pio_version #{m.pio_version} != #{r['pioVersion']}" if m.pio_version != r["pioVersion"]
      ss = r["sideset"]
      mine = { "size" => m.side_set_bits, "optional" => m.side_set_opt, "pindirs" => m.side_set_pindirs }
      diffs << "sideset #{mine} != #{ss}" if ss && mine != ss
      diffs << "unexpected sideset" if ss.nil? && m.side_set_bits > 0
      pl = r["publicLabels"].to_a.map { |a, b| [a.to_s, b] }.sort
      ml = m.public_labels.map { |a, b| [a.to_s, b] }.sort
      diffs << "public label #{ml} != #{pl}" if pl != ml
      fifo = r["fifoConfig"] || "PIO_FIFO_JOIN_NONE"
      mf = "PIO_FIFO_JOIN_#{Pico::PIO::FIFO_MODES[m.fifo]}"
      diffs << "fifo #{mf} != #{fifo}" if fifo != mf
      mi = m.in_decl.nil? ? nil : { "pinCount" => m.in_decl[0], "right" => m.in_decl[1], "autopush" => m.in_decl[2], "threshold" => m.in_decl[3] }
      diffs << "in #{mi} != #{r['in']}" if mi != r["in"]
      mo = m.out_decl.nil? ? nil : { "pinCount" => m.out_decl[0], "right" => m.out_decl[1], "autopull" => m.out_decl[2], "threshold" => m.out_decl[3] }
      diffs << "out #{mo} != #{r['out']}" if mo != r["out"]
      diffs << "setCount #{m.set_decl.inspect} != #{r['setCount'].inspect}" if m.set_decl != r["setCount"]
      mm = m.mov_status.nil? ? nil : { "type" => m.mov_status[0], "n" => m.mov_status[1] }
      diffs << "movStatus #{mm} != #{r['movStatus']}" if mm != r["movStatus"]
      mc = m.clock_div.nil? ? nil : { "int" => m.clock_div[0], "frac" => m.clock_div[1] }
      diffs << "clockDiv #{mc} != #{r['clockDiv']}" if mc != r["clockDiv"]
      ps = r["publicSymbols"].to_a.map { |a, b| [a.to_s, b] }.sort
      ms = m.defines.map { |a, b| [a.to_s, b] }.sort
      diffs << "public define #{ms} != #{ps}" if ps != ms
    end
    if diffs.empty?
      ok += 1
    else
      bad += 1
      puts "MISMATCH #{File.basename(path)} #{r['name']}: #{diffs.join(' / ')}"
    end
  end
  puts "MISMATCH #{File.basename(path)}: extra program on the Ruby side" if PROGRAMS.size > ref.size
  # the sm_config_set_* lines of get_default_config, in pioasm's order (only for files without c-sdk code blocks,
  # which may add their own)
  unless File.read(path).include?("% c-sdk")
    theirs = `#{pioasm} #{path}`.lines.grep(/sm_config_set_/).map(&:strip)
    mine = PROGRAMS.flat_map { |m| m.to_c.lines.grep(/sm_config_set_/).map(&:strip) }
    if theirs != mine
      bad += 1
      puts "MISMATCH #{File.basename(path)}: get_default_config differs: #{(mine - theirs).inspect} / #{(theirs - mine).inspect}"
    end
  end
end
puts "match #{ok} / mismatch or failed #{bad}"
exit(bad == 0 ? 0 : 1)
