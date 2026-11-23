# Runtime layer: procedures that drive PIO blocks and SMs (names follow pico-sdk's hardware_pio).
# Registers are accessed through a bus (read32 / write32 / write32_hl / set_bits / clear_bits).
# On the microcontroller pass Pico::MMIOBus from lib/pico/mmio.rb; for host-side checks pass a bus that just records writes.
#
# bare-full Integers are signed 32-bit, so values with bit 31 set are written as upper/lower 16-bit halves via write32_hl.
# Values read back are signed (negative if bit 31 is set)
require_relative "program"
require_relative "encode"
require_relative "../resets"
require_relative "../gpio"

module Pico
  module PIO
    # Register offsets within a PIO block (same on RP2040 and RP2350 unless noted)
    module Regs
      CTRL = 0x000
      FSTAT = 0x004
      FDEBUG = 0x008
      FLEVEL = 0x00c
      TXF0 = 0x010
      RXF0 = 0x020
      IRQ = 0x030                    # the 8 IRQ flags; writing 1 clears
      IRQ_FORCE = 0x034              # writing 1 sets
      INSTR_MEM0 = 0x048
      SM0 = 0x0c8                    # SM n's register set is at SM0 + SM_STRIDE * n
      SM_STRIDE = 0x18
      SM_CLKDIV = 0x00
      SM_EXECCTRL = 0x04
      SM_SHIFTCTRL = 0x08
      SM_ADDR = 0x0c
      SM_INSTR = 0x10
      SM_PINCTRL = 0x14
      # INTR and IRQ0_INTE / INTF / INTS differ: Chip#pio_intr, Chip#pio_irq0_inte (+4 INTF, +8 INTS); IRQ n's are
      # IRQN_STRIDE further
      IRQN_STRIDE = 0x0c
      EXECCTRL_OUT_STICKY = 1 << 17
      SHIFTCTRL_FJOIN_RX = -0x8000_0000         # bit 31 (as a signed 32-bit Integer)
      SHIFTCTRL_AUTOPULL = 1 << 17
    end

    # Interrupt sources for Block#set_irqn_source_enabled (pico-sdk's pio_interrupt_source):
    # SM n's RX FIFO not empty is PIS_SM0_RX_FIFO_NOT_EMPTY + n, TX FIFO not full PIS_SM0_TX_FIFO_NOT_FULL + n,
    # IRQ flag n (0-3) PIS_INTERRUPT0 + n
    PIS_SM0_RX_FIFO_NOT_EMPTY = 0
    PIS_SM0_TX_FIFO_NOT_FULL = 4
    PIS_INTERRUPT0 = 8

    class Block
      attr_reader :bus, :chip, :index, :base

      def initialize(bus, chip, index)
        raise "#{chip.name} PIO index must be 0-#{chip.pio_bases.size - 1}" unless index.between?(0, chip.pio_bases.size - 1)
        @bus = bus
        @chip = chip
        @index = index
        @base = chip.pio_bases[index]
        @used = Array.new(32, false)             # used slots in instruction memory
        @sms = [StateMachine.new(self, 0), StateMachine.new(self, 1),
                StateMachine.new(self, 2), StateMachine.new(self, 3)]
      end

      # Assert then deassert reset on this block and IO_BANK0 / PADS_BANK0 (leaves no prior state)
      def reset!
        resets = Pico::Resets.new(@bus, @chip)
        resets.reset_block([block_name])
        resets.unreset_block_wait([block_name, :io_bank0, :pads_bank0])
        @used = Array.new(32, false)
        self
      end

      def block_name
        return :pio0 if @index == 0
        return :pio1 if @index == 1
        :pio2
      end

      def sm(n)
        raise "SM must be 0-3" unless n.between?(0, 3)
        @sms[n]
      end

      # Route a pin to this PIO block (pico-sdk's pio_gpio_init)
      def gpio_init(pin)
        Pico::GPIO.new(@bus, @chip).set_function(pin, block_name)
      end

      def can_add_program?(prog) = !find_offset(prog).nil?

      # Load into instruction memory and return the offset (pico-sdk's pio_add_program).
      # Programs without a fixed origin (origin -1) take the first free space searching from the top. jmp targets are relocated by the offset
      def add_program(prog)
        if prog.pio_version > @chip.pio_version
          raise "#{prog.name} needs pio_version #{prog.pio_version} (#{@chip.name} supports up to #{@chip.pio_version})"
        end
        offset = find_offset(prog)
        raise "#{prog.name}: instruction memory has no room for #{prog.length} instructions" if offset.nil?
        prog.instructions.each_with_index do |w, i|
          @bus.write32(@base + Regs::INSTR_MEM0 + 4 * (offset + i), relocate(w, offset))
          @used[offset + i] = true
        end
        offset
      end

      def remove_program(prog, offset)
        prog.length.times { |i| @used[offset + i] = false }
      end

      def find_offset(prog)
        len = prog.length
        return nil if len < 1 || len > 32
        if prog.origin >= 0
          return free?(prog.origin, len) ? prog.origin : nil
        end
        o = 32 - len
        while o >= 0
          return o if free?(o, len)
          o -= 1
        end
        nil
      end

      def free?(o, len)
        return false if o + len > 32
        len.times { |i| return false if @used[o + i] }
        true
      end

      def relocate(w, offset)
        return w if (w & 0xE000) != 0            # only jmp
        (w & 0xFFE0) | (((w & 0x1F) + offset) & 0x1F)
      end

      # Start several SMs together on the same clock (pico-sdk's pio_enable_sm_mask_in_sync)
      def enable_in_sync(sms)
        mask = 0
        sms.each { |s| mask |= 1 << s.index }
        @bus.set_bits(@base + Regs::CTRL, mask | (mask << 8))   # SM_ENABLE and CLKDIV_RESTART
      end

      def fstat = @bus.read32(@base + Regs::FSTAT)
      def flevel = @bus.read32(@base + Regs::FLEVEL)

      # ---- IRQ flags 0-7, set and cleared by the irq instruction (and waited on by wait irq) and by the CPU
      def irq_flags = @bus.read32(@base + Regs::IRQ) & 0xFF
      def interrupt_get(n) = (irq_flags & (1 << check_irq(n))) != 0
      def interrupt_clear(n) = @bus.write32(@base + Regs::IRQ, 1 << check_irq(n))
      def interrupt_clear_mask(mask) = @bus.write32(@base + Regs::IRQ, mask & 0xFF)
      def interrupt_force(n) = @bus.write32(@base + Regs::IRQ_FORCE, 1 << check_irq(n))

      def check_irq(n)
        raise "PIO IRQ flag must be 0-7 (got #{n})" unless n.between?(0, 7)
        n
      end

      # ---- interrupt sources (the PIO's two interrupt lines, IRQ 0 and IRQ 1). There is no interrupt handling yet,
      # so poll: intr is the raw sources, ints(irq_index) those enabled for that line
      def intr = @bus.read32(@base + @chip.pio_intr) & ((1 << @chip.pio_irq_sources) - 1)
      def ints(irq_index) = @bus.read32(irqn_reg(irq_index, @chip.pio_irq0_inte + 8)) & ((1 << @chip.pio_irq_sources) - 1)

      def set_irqn_source_enabled(irq_index, source, on)
        n = @chip.pio_irq_sources               # 12 on RP2040 (IRQ flags 0-3), 16 on RP2350 (flags 0-7)
        raise "PIO interrupt source must be 0-#{n - 1} (got #{source})" unless source.between?(0, n - 1)
        set_irqn_source_mask_enabled(irq_index, 1 << source, on)
      end

      def set_irqn_source_mask_enabled(irq_index, mask, on)
        a = irqn_reg(irq_index, @chip.pio_irq0_inte)
        on ? @bus.set_bits(a, mask) : @bus.clear_bits(a, mask)
      end

      def set_irq0_source_enabled(source, on) = set_irqn_source_enabled(0, source, on)
      def set_irq1_source_enabled(source, on) = set_irqn_source_enabled(1, source, on)

      def irqn_reg(irq_index, off)
        raise "PIO interrupt line must be 0 or 1 (got #{irq_index})" unless irq_index == 0 || irq_index == 1
        @base + off + Regs::IRQN_STRIDE * irq_index
      end

      # ---- FIFO debug flags (sticky; write 1 to clear). Bits for SM n: RX stall n, RX underflow 8 + n,
      # TX overflow 16 + n, TX stall 24 + n
      def fdebug = @bus.read32(@base + Regs::FDEBUG)
      def clear_fdebug(mask) = @bus.write32(@base + Regs::FDEBUG, mask)
    end

    class StateMachine
      attr_reader :block, :index

      def initialize(block, index)
        @block = block
        @index = index
      end

      def bus = @block.bus
      def reg(off) = @block.base + Regs::SM0 + Regs::SM_STRIDE * @index + off

      # Write the config, clear the FIFOs, and prepare to start at initial_pc. Actually starting is done by set_enabled or
      # Block#enable_in_sync (pico-sdk's pio_sm_init)
      def init(initial_pc, config)
        set_enabled(false)
        b = bus
        b.write32_hl(reg(Regs::SM_CLKDIV), config.clkdiv_int, config.clkdiv_frac << 8)
        write_execctrl(config)
        write_shiftctrl(config)
        write_pinctrl(config)
        clear_fifos
        restart
        exec(initial_pc & 0x1F)                  # jmp initial_pc
      end

      def write_execctrl(c)
        side_en = c.side_opt ? 1 : 0
        pindir = c.side_pindirs ? 1 : 0
        hi = (side_en << 14) | (pindir << 13) | (c.jmp_pin << 8) | (c.wrap_top >> 4)
        chip = @block.chip
        sel = c.status_sel == :rxfifo ? 1 : (c.status_sel == :irq ? 2 : 0)
        raise "mov_status :irq needs pio_version 1 (#{chip.name} has #{chip.pio_version})" if sel == 2 && chip.pio_version < 1
        raise "#{chip.name} mov_status n must be 0-#{chip.pio_status_n_max} (got #{c.status_n})" if c.status_n > chip.pio_status_n_max
        lo = ((c.wrap_top & 0xF) << 12) | (c.wrap_bottom << 7) | (sel << chip.pio_status_sel_lsb) | c.status_n
        bus.write32_hl(reg(Regs::SM_EXECCTRL), hi, lo)
      end

      def shiftctrl_hi(c, join)
        rx = join == :rx ? 1 : 0
        tx = join == :tx ? 1 : 0
        (rx << 15) | (tx << 14) | ((c.pull_thresh & 31) << 9) | ((c.push_thresh & 31) << 4) |
          ((c.out_right ? 1 : 0) << 3) | ((c.in_right ? 1 : 0) << 2) |
          ((c.autopull ? 1 : 0) << 1) | (c.autopush ? 1 : 0)
      end

      # FJOIN_RX_GET (bit 14) and FJOIN_RX_PUT (bit 15) exist only on RP2350
      def write_shiftctrl(c)
        j = c.fifo_join
        get = j == :txget || j == :putget
        put = j == :txput || j == :putget
        raise "fifo_join :#{j} needs pio_version 1 (#{@block.chip.name} has #{@block.chip.pio_version})" if (get || put) && @block.chip.pio_version < 1
        bus.write32_hl(reg(Regs::SM_SHIFTCTRL), shiftctrl_hi(c, j), ((put ? 1 : 0) << 15) | ((get ? 1 : 0) << 14))
      end

      def write_pinctrl(c)
        hi = (c.side_bits << 13) | (c.set_count << 10) | (c.out_count << 4) | (c.in_base >> 1)
        lo = ((c.in_base & 1) << 15) | (c.sideset_base << 10) | (c.set_base << 5) | c.out_base
        bus.write32_hl(reg(Regs::SM_PINCTRL), hi, lo)
      end

      # Changing the FIFO join empties both FIFOs: flip FJOIN_RX twice (pico-sdk's pio_sm_clear_fifos)
      def clear_fifos
        bus.xor_bits(reg(Regs::SM_SHIFTCTRL), Regs::SHIFTCTRL_FJOIN_RX)
        bus.xor_bits(reg(Regs::SM_SHIFTCTRL), Regs::SHIFTCTRL_FJOIN_RX)
      end

      def restart = bus.set_bits(@block.base + Regs::CTRL, 1 << (4 + @index))
      def clkdiv_restart = bus.set_bits(@block.base + Regs::CTRL, 1 << (8 + @index))

      # Clock divider int + frac / 256 (pico-sdk's pio_sm_set_clkdiv_int_frac); takes effect at once
      def set_clkdiv_int_frac(int, frac)
        raise "PIO clkdiv integer must be 0-65535 (0 = 65536) (got #{int})" unless int.between?(0, 0xFFFF)
        raise "PIO clkdiv fraction must be 0-255 (got #{frac})" unless frac.between?(0, 255)
        raise "PIO clkdiv integer 0 means 65536 and takes no fraction" if int == 0 && frac != 0
        bus.write32_hl(reg(Regs::SM_CLKDIV), int, frac << 8)
      end

      def set_wrap(wrap_target, wrap)
        raise "PIO wrap must be 0-31" unless wrap_target.between?(0, 31) && wrap.between?(0, 31)
        bus.write_masked(reg(Regs::SM_EXECCTRL), (wrap << 12) | (wrap_target << 7), 0x1FF80)
      end

      # Pin mapping at run time (pico-sdk's pio_sm_set_out_pins and friends)
      def set_out_pins(base, count) = set_pinctrl(base, 0, count, 20, 6, 32)
      def set_set_pins(base, count) = set_pinctrl(base, 5, count, 26, 3, 5)
      def set_in_pins(base) = bus.write_masked(reg(Regs::SM_PINCTRL), check_pin(base) << 15, 0x1F << 15)
      def set_sideset_pins(base) = bus.write_masked(reg(Regs::SM_PINCTRL), check_pin(base) << 10, 0x1F << 10)

      def set_pinctrl(base, base_lsb, count, count_lsb, count_bits, max)
        raise "PIO pin count must be 0-#{max} (got #{count})" unless count.between?(0, max)
        mask = (0x1F << base_lsb) | (((1 << count_bits) - 1) << count_lsb)
        bus.write_masked(reg(Regs::SM_PINCTRL), (check_pin(base) << base_lsb) | (count << count_lsb), mask)
      end

      def check_pin(pin)
        raise "PIO pin must be 0-31 (got #{pin})" unless pin.between?(0, 31)
        pin
      end

      # The instruction the SM is at (pico-sdk's pio_sm_get_pc)
      def get_pc = bus.read32(reg(Regs::SM_ADDR)) & 0x1F

      # An instruction given to exec that has not finished yet (a wait, a blocking pull, ...) leaves the SM stalled on
      # it (EXECCTRL bit 31, so the register reads negative). On an RP2040 Pico an exec'd irq wait stops the SM but
      # does not set this bit, although the datasheet says it should
      def is_exec_stalled? = bus.read32(reg(Regs::SM_EXECCTRL)) < 0

      # exec, then wait until the instruction has finished (pico-sdk's pio_sm_exec_wait_blocking). Returns at once for
      # irq wait (see is_exec_stalled?)
      def exec_wait_blocking(instr)
        exec(instr)
        while is_exec_stalled?
        end
      end

      def set_enabled(on)
        if on
          bus.set_bits(@block.base + Regs::CTRL, 1 << @index)
        else
          bus.clear_bits(@block.base + Regs::CTRL, 1 << @index)
        end
      end

      # Execute one instruction immediately (pico-sdk's pio_sm_exec)
      def exec(instr) = bus.write32(reg(Regs::SM_INSTR), instr & 0xFFFF)

      # Set the direction of count pins starting at base (pico-sdk's pio_sm_set_consecutive_pindirs).
      # Temporarily borrows the SET pin config and executes set pindirs
      def set_consecutive_pindirs(base, count, output)
        saved = bus.read32(reg(Regs::SM_PINCTRL))
        pin = base
        left = count
        while left > 0
          n = left > 5 ? 5 : left
          bus.write32_hl(reg(Regs::SM_PINCTRL), n << 10, pin << 5)
          exec(0xE080 | (output ? (1 << n) - 1 : 0))   # set pindirs, mask
          pin += n
          left -= n
        end
        bus.write32(reg(Regs::SM_PINCTRL), saved)
      end

      def tx_full? = (@block.fstat & (1 << (16 + @index))) != 0
      def tx_empty? = (@block.fstat & (1 << (24 + @index))) != 0
      def rx_full? = (@block.fstat & (1 << @index)) != 0
      def rx_empty? = (@block.fstat & (1 << (8 + @index))) != 0
      def rx_level = (@block.flevel >> (8 * @index + 4)) & 0xF
      def tx_level = (@block.flevel >> (8 * @index)) & 0xF

      # Empty the TX FIFO by having the SM take the words (pico-sdk's pio_sm_drain_tx_fifo): out null, 32 with autopull,
      # pull noblock without. The SM's program does not see them
      def drain_tx_fifo
        autopull = (bus.read32(reg(Regs::SM_SHIFTCTRL)) & Regs::SHIFTCTRL_AUTOPULL) != 0
        instr = autopull ? Encode.out(:null, 32) : Encode.pull(false, false)
        exec(instr) until tx_empty?
      end

      # Drive pin values through this SM with set pins, 5 pins at a time (pico-sdk's pio_sm_set_pins). Bit n of values
      # is GPIO n. Meant for setup with the SM stopped; PINCTRL and EXECCTRL are restored afterwards
      def set_pins(values)
        with_set_pins do
          base = 0
          while base < 32
            n = base == 30 ? 2 : 5
            bus.write32(reg(Regs::SM_PINCTRL), (n << 26) | (base << 5))
            exec(Encode.set(:pins, (values >> base) & 0x1F))
            base += n
          end
        end
      end

      # Only the pins in mask, one at a time (pico-sdk's pio_sm_set_pins_with_mask / pio_sm_set_pindirs_with_mask)
      def set_pins_with_mask(values, mask) = set_each_pin(values, mask, :pins)
      def set_pindirs_with_mask(dirs, mask) = set_each_pin(dirs, mask, :pindirs)

      def set_each_pin(values, mask, dest)
        with_set_pins do
          32.times do |pin|
            if ((mask >> pin) & 1) != 0
              bus.write32(reg(Regs::SM_PINCTRL), (1 << 26) | (pin << 5))
              exec(Encode.set(dest, (values >> pin) & 1))
            end
          end
        end
      end

      def with_set_pins
        pinctrl = bus.read32(reg(Regs::SM_PINCTRL))
        execctrl = bus.read32(reg(Regs::SM_EXECCTRL))
        bus.clear_bits(reg(Regs::SM_EXECCTRL), Regs::EXECCTRL_OUT_STICKY)
        yield
        bus.write32(reg(Regs::SM_PINCTRL), pinctrl)
        bus.write32(reg(Regs::SM_EXECCTRL), execctrl)
      end

      # Push one word into the TX FIFO, waiting while it is full (pico-sdk's pio_sm_put_blocking).
      # word is signed 32-bit (to set bit 31 use a negative number or put_hl)
      def put(word)
        while tx_full?
        end
        bus.write32(@block.base + Regs::TXF0 + 4 * @index, word)
      end

      def put_hl(hi, lo)
        while tx_full?
        end
        bus.write32_hl(@block.base + Regs::TXF0 + 4 * @index, hi, lo)
      end

      # Put a value in the ISR (for inbox.preset): through the TX FIFO, then pull and out isr, 32 run with exec. Call it
      # while the state machine is stopped, with the TX FIFO empty (as pico-examples' pio_pwm_set_period)
      def load_isr(word)
        put(word)
        exec(Encode.pull(false, false))
        exec(Encode.out(:isr, 32))
      end

      def load_isr_hl(hi, lo)
        put_hl(hi, lo)
        exec(Encode.pull(false, false))
        exec(Encode.out(:isr, 32))
      end

      # Pop one word from the RX FIFO, waiting while it is empty (pico-sdk's pio_sm_get_blocking). Returned signed
      def get
        while rx_empty?
        end
        bus.read32(@block.base + Regs::RXF0 + 4 * @index)
      end
    end
  end
end
