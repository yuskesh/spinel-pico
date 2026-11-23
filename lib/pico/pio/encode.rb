# Single PIO instructions built at run time, for StateMachine#exec (names follow pico-sdk's pio_instructions.h without
# the pio_encode_ prefix: pio_encode_irq_set -> Encode.irq_set). Runs on the device; the assembler layer (asm.rb) is
# host-only. Destinations and sources are the same symbols as in asm.rb. test/runtime_regs.rb checks every encoder
# against the assembler. Side-set and delay are not encoded (pico-sdk adds them with pio_encode_sideset / _delay).
module Pico
  module PIO
    module Encode
      def self.jmp(addr) = 0x0000 | check(addr, 31, "jmp address")
      def self.jmp_not_x(addr) = 0x0020 | check(addr, 31, "jmp address")
      def self.jmp_x_dec(addr) = 0x0040 | check(addr, 31, "jmp address")
      def self.jmp_not_y(addr) = 0x0060 | check(addr, 31, "jmp address")
      def self.jmp_y_dec(addr) = 0x0080 | check(addr, 31, "jmp address")
      def self.jmp_x_ne_y(addr) = 0x00a0 | check(addr, 31, "jmp address")
      def self.jmp_pin(addr) = 0x00c0 | check(addr, 31, "jmp address")
      def self.jmp_not_osre(addr) = 0x00e0 | check(addr, 31, "jmp address")

      def self.wait_gpio(polarity, gpio) = 0x2000 | (polarity ? 0x80 : 0) | check(gpio, 31, "wait gpio")
      def self.wait_pin(polarity, pin) = 0x2020 | (polarity ? 0x80 : 0) | check(pin, 31, "wait pin")
      def self.wait_irq(polarity, relative, irq) = 0x2040 | (polarity ? 0x80 : 0) | irq_index(relative, irq)

      def self.in_(src, count) = 0x4000 | (in_source(src) << 5) | bit_count(count)
      def self.out(dest, count) = 0x6000 | (out_dest(dest) << 5) | bit_count(count)
      def self.push(if_full, block) = 0x8000 | (if_full ? 0x40 : 0) | (block ? 0x20 : 0)
      def self.pull(if_empty, block) = 0x8080 | (if_empty ? 0x40 : 0) | (block ? 0x20 : 0)
      def self.mov(dest, src) = 0xa000 | (mov_dest(dest) << 5) | mov_source(src)
      def self.mov_not(dest, src) = 0xa008 | (mov_dest(dest) << 5) | mov_source(src)
      def self.mov_reverse(dest, src) = 0xa010 | (mov_dest(dest) << 5) | mov_source(src)
      def self.irq_set(relative, irq) = 0xc000 | irq_index(relative, irq)
      def self.irq_wait(relative, irq) = 0xc020 | irq_index(relative, irq)
      def self.irq_clear(relative, irq) = 0xc040 | irq_index(relative, irq)
      def self.set(dest, value) = 0xe000 | (set_dest(dest) << 5) | check(value, 31, "set value")
      def self.nop = 0xa042                     # mov y, y

      def self.check(v, max, what)
        raise "#{what} must be 0-#{max} (got #{v})" unless v.between?(0, max)
        v
      end

      def self.bit_count(n)
        raise "bit count must be 1-32 (got #{n})" unless n.between?(1, 32)
        n & 31                                  # 32 is encoded as 0
      end

      def self.irq_index(relative, irq) = check(irq, 7, "irq index") | (relative ? 0x10 : 0)

      def self.in_source(s)
        case s
        when :pins then 0
        when :x then 1
        when :y then 2
        when :null then 3
        when :isr then 6
        when :osr then 7
        else raise "invalid in source #{s}"
        end
      end

      def self.out_dest(d)
        case d
        when :pins then 0
        when :x then 1
        when :y then 2
        when :null then 3
        when :pindirs then 4
        when :pc then 5
        when :isr then 6
        when :exec then 7
        else raise "invalid out destination #{d}"
        end
      end

      def self.mov_dest(d)
        case d
        when :pins then 0
        when :x then 1
        when :y then 2
        when :exec then 4
        when :pc then 5
        when :isr then 6
        when :osr then 7
        else raise "invalid mov destination #{d}"
        end
      end

      def self.mov_source(s)
        case s
        when :pins then 0
        when :x then 1
        when :y then 2
        when :null then 3
        when :status then 5
        when :isr then 6
        when :osr then 7
        else raise "invalid mov source #{s}"
        end
      end

      def self.set_dest(d)
        case d
        when :pins then 0
        when :x then 1
        when :y then 2
        when :pindirs then 4
        else raise "invalid set destination #{d}"
        end
      end
    end
  end
end
