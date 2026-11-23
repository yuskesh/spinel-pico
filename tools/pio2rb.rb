# Convert a pioasm .pio file to Pico::PIO.asm Ruby (for testing; test/asm_vs_pioasm.rb checks the result matches pioasm)
#   ruby tools/pio2rb.rb file.pio > file.rb
# Supported: .program .side_set .define .origin .pio_version .fifo .in .out .set .mov_status .clock_div .wrap_target .wrap,
# labels (public), all instructions,
# side, [delay]
# Not converted: code blocks such as % c-sdk { }, .lang_opt
class Pio2Rb
  JMP_CONDS = { "!x" => :not_x, "x--" => :x_dec, "!y" => :not_y, "y--" => :y_dec,
                "x!=y" => :x_ne_y, "pin" => :pin, "!osre" => :not_osre }
  KEYWORDS = %w[pins x y null isr osr pindirs pc exec status gpio pin irq jmppin]

  def initialize
    @out = []
    @defs = {}          # .define name -> Ruby variable name (per program)
    @in_program = false
  end

  def var(name) = "d_#{name.downcase}"

  # Expressions: .define names become Ruby variables, 0x... is kept as is
  def expr(s)
    s = s.strip
    s.gsub(/0[xX][0-9a-fA-F]+|0[bB][01]+|\d+|[A-Za-z_][A-Za-z0-9_]*/) do |id|
      if id =~ /\A\d/ then id
      elsif @defs.key?(id) || @global_defs&.key?(id) then var(id)
      else raise "unknown symbol #{id} in expression (#{s})"
      end
    end
  end

  def close_program
    set_header if @in_program
    @out << "end" if @in_program
    @in_program = false
  end

  def convert(text)
    @global_defs = {}
    lines = text.lines
    i = 0
    pending_opts = nil
    while i < lines.size
      line = lines[i]
      i += 1
      if line =~ /^\s*%\s*[\w-]+\s*\{/       # skip code blocks
        i += 1 until lines[i - 1] =~ /^\s*%\}/
        next
      end
      line = line.sub(%r{//.*}, "").sub(/;.*/, "").strip
      next if line.empty?
      if line =~ /\A\.program\s+(\w+)/
        close_program
        @name = $1
        @defs = {}
        @header = { name: @name }
        @header[:pio_version] = @file_pio_version if @file_pio_version
        @body = []
        @in_program = true
        @program_start = @out.size
        @out << nil                                   # the Pico::PIO.asm line is filled in later (.side_set etc. come after)
        next
      end
      if line =~ /\A\.define\s+(public\s+)?(\w+)\s+(.+)\z/
        pub = !$1.nil?
        n = $2
        v = expr($3)
        if @in_program
          @defs[n] = true
          @out << "  #{var(n)} = define(:#{n}, #{v}#{pub ? ', public: true' : ''})"
        else
          @global_defs[n] = true
          @out << "#{var(n)} = #{v}"
        end
        next
      end
      if line =~ /\A\.side_set\s+(\d+)(.*)\z/
        @header[:side_set] = $1.to_i
        rest = $2
        @header[:side_set_opt] = true if rest =~ /\bopt\b/
        @header[:side_set_pindirs] = true if rest =~ /\bpindirs\b/
        set_header
        next
      end
      if line =~ /\A\.origin\s+(\S+)/
        @header[:origin] = expr($1)
        set_header
        next
      end
      if line =~ /\A\.pio_version\s+(\S+)/
        if @in_program
          @header[:pio_version] = expr($1)
          set_header
        else
          @file_pio_version = expr($1)                # before .program: applies to every program in the file
        end
        next
      end
      if line =~ /\A\.fifo\s+(\w+)/
        @header[:fifo] = $1.downcase
        set_header
        next
      end
      if line =~ /\A\.(in|out)\s+(\S+)(.*)\z/
        which = $1
        opts = $3.split
        args = [expr($2)]
        dir = opts.find { |o| %w[left right].include?(o.downcase) }
        args << ":#{dir.downcase}" if dir
        args << "auto: true" if opts.any? { |o| o.downcase == "auto" }
        thr = opts.find { |o| o =~ /\A\d/ }
        args << "threshold: #{expr(thr)}" if thr
        @out << "  #{which}_pins #{args.join(', ')}"
        next
      end
      if line =~ /\A\.set\s+(\S+)\z/
        @out << "  set_pins #{expr($1)}"
        next
      end
      if line =~ /\A\.clock_div\s+(\S+)\z/
        @out << "  clock_div #{$1}r"                  # a Rational, as exact as the text
        next
      end
      if line =~ /\A\.mov_status\s+(txfifo|rxfifo)\s*<\s*(\S+)\z/i
        @out << "  mov_status :#{$1.downcase}, #{expr($2)}"
        next
      end
      if line =~ /\A\.mov_status\s+irq\s+(?:(prev|next)\s+)?set\s+(\S+)\z/i
        @out << "  mov_status :irq, #{expr($2)}#{$1 ? ", pio: :#{$1.downcase}" : ''}"
        next
      end
      next if line =~ /\A\.lang_opt/
      if line == ".wrap_target" then @out << "  wrap_target"; next end
      if line == ".wrap" then @out << "  wrap"; next end
      raise "unknown directive: #{line}" if line.start_with?(".")
      if line =~ /\A(public\s+)?(\w+):\s*(.*)\z/i
        @out << "  label :#{$2}#{$1 ? ', public: true' : ''}"
        line = $3
        next if line.empty?
      end
      @out << "  " + instruction(line)
    end
    close_program
    set_header
    @out.join("\n") + "\n"
  end

  def set_header
    return unless @header && @program_start
    h = @header
    opts = []
    opts << "side_set: #{h[:side_set]}" if h[:side_set]
    opts << "side_set_opt: true" if h[:side_set_opt]
    opts << "side_set_pindirs: true" if h[:side_set_pindirs]
    opts << "origin: #{h[:origin]}" if h[:origin]
    opts << "pio_version: #{h[:pio_version]}" if h[:pio_version]
    opts << "fifo: :#{h[:fifo]}" if h[:fifo]
    @out[@program_start] = "PROGRAMS << Pico::PIO.asm(:#{h[:name]}#{opts.map { |o| ', ' + o }.join}) do"
  end

  # One instruction: split into body, side N, [delay]
  def instruction(line)
    delay = nil
    line = line.gsub(/rxfifo\s*\[\s*(\w+)\s*\]/i) { "rxfifo<#{$1}>" }      # not a [delay]
    if line =~ /\[([^\]]+)\]/                    # [delay] may come before or after side
      delay = expr($1)
      line = line.sub(/\[([^\]]+)\]/, " ").strip
    end
    side = nil
    if line =~ /\bside\s+([^\s\[]+)/i
      side = expr($1)
      line = line.sub(/\bside\s+([^\s\[]+)/i, " ").strip
    end
    op, rest = line.split(/\s+/, 2)
    op = op.downcase
    rest = (rest || "").strip
    args = body(op, rest)
    kw = []
    kw << "side: #{side}" if side
    kw << "delay: #{delay}" if delay
    call = op == "in" ? "in_" : op
    all = args + kw
    all.empty? ? call : "#{call} #{all.join(', ')}"
  end

  def sym(word)
    w = word.downcase
    raise "unknown keyword: #{word}" unless KEYWORDS.include?(w)
    ":#{w}"
  end

  def target(t)
    t =~ /\A[A-Za-z_]\w*\z/ && !@defs.key?(t) && !@global_defs.key?(t) ? ":#{t}" : expr(t)
  end

  def body(op, rest)
    toks = rest.gsub(",", " ").split
    case op
    when "nop" then []
    when "jmp"
      if toks.size == 2
        c = JMP_CONDS[toks[0].downcase] or raise "invalid jmp condition #{toks[0]}"
        [":#{c}", target(toks[1])]
      else
        [target(toks[0])]
      end
    when "wait"
      pol = toks.shift
      src = toks.shift
      if pol =~ /\A[a-z]/i                  # polarity defaults to 1 when omitted
        src, pol = pol, "1"
        toks.unshift(src) if false
      end
      rel = toks.last&.downcase == "rel" ? toks.pop : nil
      blk = %w[prev next].include?(toks.first&.downcase) ? toks.shift.downcase : nil     # wait 1 irq prev N
      idx = toks.join(" ").sub(/\A\+/, "").strip     # wait jmppin + N
      idx = "0" if idx.empty?
      [expr(pol), sym(src), expr(idx)] + (rel ? ["rel: true"] : []) + (blk ? ["pio: :#{blk}"] : [])
    when "in", "out"
      [sym(toks[0]), expr(toks[1])]
    when "push", "pull"
      r = []
      toks.each do |t|
        case t.downcase
        when "iffull" then r << "iffull: true"
        when "ifempty" then r << "ifempty: true"
        when "block" then nil
        when "noblock" then r << "block: false"
        else raise "invalid #{op} option #{t}"
        end
      end
      r
    when "mov"
      d, s = rest.split(",", 2).map(&:strip)
      o = nil
      if s.start_with?("::") then o = "reverse"; s = s[2..]
      elsif s.start_with?("~") || s.start_with?("!") then o = "invert"; s = s[1..]
      end
      fifo = ->(w) { w =~ /\Arxfifo<(\w+)>\z/i ? "rxfifo(#{$1.downcase == 'y' ? ':y' : expr($1)})" : sym(w) }
      [fifo.(d), fifo.(s.strip)] + (o ? ["op: :#{o}"] : [])
    when "irq"
      rel = toks.last&.downcase == "rel" ? toks.pop : nil
      blk = %w[prev next].include?(toks[0].downcase) ? toks.shift.downcase : nil         # irq prev set N
      mode = %w[set nowait wait clear].include?(toks[0].downcase) ? toks.shift.downcase : nil
      (mode ? [":#{mode}"] : []) + [expr(toks.join(" "))] + (rel ? ["rel: true"] : []) + (blk ? ["pio: :#{blk}"] : [])
    when "set"
      [sym(toks[0]), expr(toks[1..].join(" "))]
    else
      raise "unknown instruction: #{op}"
    end
  end
end

if __FILE__ == $0
  print Pio2Rb.new.convert(File.read(ARGV[0]))
end
