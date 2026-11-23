# DMA (names follow pico-sdk's hardware_dma without the dma_ prefix: dma_channel_configure -> channel.configure,
# channel_config_set_dreq -> config.set_dreq). Addresses are plain Integers: a peripheral register, or a
# Pico::RAMBuffer's addr for memory. Transfer counts are in transfers of the configured size (1, 2 or 4 bytes).
#
# Pico::DMA remembers which channels are claimed (pico-sdk's dma_claim_unused_channel), so keep the object
# Board#dma returns. There is no interrupt handling yet: poll get_irq0_status / is_busy?.
# The constructor releases the DMA block if it is in reset (without resetting a running DMA).
require_relative "chip"
require_relative "resets"

module Pico
  class DMA
    CH_STRIDE = 0x40
    READ_ADDR = 0x00
    WRITE_ADDR = 0x04
    TRANS_COUNT = 0x08
    CTRL_TRIG = 0x0c
    AL1_CTRL = 0x10
    AL1_TRANS_COUNT_TRIG = 0x1c
    AL2_WRITE_ADDR_TRIG = 0x2c
    AL3_READ_ADDR_TRIG = 0x3c
    INTR = 0x400
    INTE0 = 0x404
    INTS0 = 0x40c
    IRQN_STRIDE = 0x10                         # INTE1 / INTS1 are 0x10 after INTE0 / INTS0
    # TIMER0, MULTI_CHAN_TRIGGER, SNIFF_CTRL / SNIFF_DATA and CHAN_ABORT differ by chip (Chip#dma_*)
    NUM_TIMERS = 4

    attr_reader :chip

    def initialize(bus, chip)
      @bus = bus
      @chip = chip
      @claimed = 0
      resets = Resets.new(bus, chip)
      resets.unreset_block_wait([:dma]) if resets.in_reset?(:dma)
    end

    def bus = @bus
    def reg(off) = @chip.dma_base + off

    def channel(n)
      check_channel(n)
      Channel.new(self, n)
    end

    def check_channel(n)
      raise "#{@chip.name} DMA channel must be 0-#{@chip.num_dma_channels - 1} (got #{n})" unless n.between?(0, @chip.num_dma_channels - 1)
      n
    end

    # ---- claiming (pico-sdk's dma_channel_claim / dma_claim_unused_channel)
    def channel_claim(n)
      raise "DMA channel #{n} is already claimed" if is_claimed?(n)
      @claimed |= 1 << check_channel(n)
    end

    def channel_unclaim(n) = @claimed &= ~(1 << check_channel(n))
    def is_claimed?(n) = (@claimed & (1 << check_channel(n))) != 0

    # The lowest free channel, or -1 (raises instead when required is true)
    def claim_unused_channel(required)
      @chip.num_dma_channels.times do |n|
        unless is_claimed?(n)
          channel_claim(n)
          return n
        end
      end
      raise "no free DMA channel" if required
      -1
    end

    def get_default_config(n) = ChannelConfig.new(check_channel(n))

    # Start several channels at once (pico-sdk's dma_start_channel_mask)
    def start_channel_mask(mask) = @bus.write32(reg(@chip.dma_multi_chan_trigger), mask)

    # ---- interrupt flags (lines 0 and 1). intr is raw; get_irqn_status the flags enabled for that line
    def intr = @bus.read32(reg(INTR)) & 0xFFFF
    def irqn_set_channel_mask_enabled(irq_index, mask, on)
      a = irqn_reg(irq_index, INTE0)
      on ? @bus.set_bits(a, mask) : @bus.clear_bits(a, mask)
    end
    def irqn_get_status(irq_index) = @bus.read32(irqn_reg(irq_index, INTS0)) & 0xFFFF
    def irqn_acknowledge_channel_mask(irq_index, mask) = @bus.write32(irqn_reg(irq_index, INTS0), mask)

    def irqn_reg(irq_index, off)
      raise "DMA interrupt line must be 0 or 1 (got #{irq_index})" unless irq_index == 0 || irq_index == 1
      reg(off + IRQN_STRIDE * irq_index)
    end

    # ---- pacing timers: DREQ dma_timer<n> fires at clk_sys x numerator / denominator (pico-sdk's dma_timer_set_fraction)
    def timer_set_fraction(timer, numerator, denominator)
      raise "DMA timer must be 0-#{NUM_TIMERS - 1} (got #{timer})" unless timer.between?(0, NUM_TIMERS - 1)
      raise "DMA timer fraction must be 0-65535 with numerator <= denominator" unless numerator.between?(0, 0xFFFF) &&
                                                                                      denominator.between?(1, 0xFFFF) && numerator <= denominator
      @bus.write32_hl(reg(@chip.dma_timer0 + 4 * timer), numerator, denominator)
    end

    def get_timer_dreq(timer) = @chip.dreq(:dma_timer0) + timer

    # ---- sniffer: watches the data of one channel whose config has set_sniff_enable(true)
    # mode: :crc32, :crc32_bitrev, :crc16, :crc16_bitrev, :xor, :sum (pico-sdk's DMA_SNIFF_CTRL_CALC_VALUE_*)
    def sniffer_enable(channel, mode, force_channel_enable)
      calc = case mode
             when :crc32 then 0x0
             when :crc32_bitrev then 0x1
             when :crc16 then 0x2
             when :crc16_bitrev then 0x3
             when :xor then 0xe
             when :sum then 0xf
             else raise "DMA sniff mode must be :crc32, :crc32_bitrev, :crc16, :crc16_bitrev, :xor or :sum (got #{mode})"
             end
      if force_channel_enable
        c = Channel.new(self, check_channel(channel))
        @bus.set_bits(c.reg(AL1_CTRL), 1 << 23)
      end
      @bus.write32(reg(@chip.dma_sniff_ctrl), 1 | (check_channel(channel) << 1) | (calc << 5))
    end

    def sniffer_set_byte_swap_enabled(on) = on ? @bus.set_bits(reg(@chip.dma_sniff_ctrl), 1 << 9) : @bus.clear_bits(reg(@chip.dma_sniff_ctrl), 1 << 9)
    def sniffer_set_output_invert_enabled(on) = on ? @bus.set_bits(reg(@chip.dma_sniff_ctrl), 1 << 11) : @bus.clear_bits(reg(@chip.dma_sniff_ctrl), 1 << 11)
    def sniffer_set_output_reverse_enabled(on) = on ? @bus.set_bits(reg(@chip.dma_sniff_ctrl), 1 << 10) : @bus.clear_bits(reg(@chip.dma_sniff_ctrl), 1 << 10)
    def sniffer_disable = @bus.write32(reg(@chip.dma_sniff_ctrl), 0)
    def sniffer_set_data_accumulator(v) = @bus.write32(reg(@chip.dma_sniff_ctrl + 4), v)
    def sniffer_get_data_accumulator = @bus.read32(reg(@chip.dma_sniff_ctrl + 4))

    # pico-sdk's dma_channel_config: kept as fields, turned into CTRL by ctrl_value
    class ChannelConfig
      attr_reader :read_increment, :write_increment, :dreq, :chain_to, :data_size, :ring_write, :ring_size_bits,
                  :bswap, :irq_quiet, :high_priority, :enable, :sniff_enable

      # pico-sdk's dma_channel_get_default_config: read increments, write does not, unpaced, chained to itself
      # (no chain), 32-bit transfers, no ring, enabled
      def initialize(channel)
        @read_increment = true
        @write_increment = false
        @dreq = 63                              # DREQ_FORCE: as fast as possible
        @chain_to = channel
        @data_size = 4
        @ring_write = false
        @ring_size_bits = 0
        @bswap = false
        @irq_quiet = false
        @high_priority = false
        @enable = true
        @sniff_enable = false
      end

      def set_read_increment(on) = @read_increment = on
      def set_write_increment(on) = @write_increment = on

      def set_dreq(n)
        raise "DREQ must be 0-63 (got #{n})" unless n.between?(0, 63)
        @dreq = n
      end

      def set_chain_to(n)
        raise "DMA chain_to must be 0-15 (got #{n})" unless n.between?(0, 15)
        @chain_to = n
      end

      # Bytes per transfer: 1, 2 or 4 (pico-sdk's DMA_SIZE_8 / 16 / 32)
      def set_transfer_data_size(bytes)
        raise "DMA transfer size must be 1, 2 or 4 bytes (got #{bytes})" unless bytes == 1 || bytes == 2 || bytes == 4
        @data_size = bytes
      end

      # Wrap the read (write = false) or write address within 2^size_bits bytes; 0 = no ring. The buffer must be
      # aligned to 2^size_bits
      def set_ring(write, size_bits)
        raise "DMA ring size must be 0-15 bits (got #{size_bits})" unless size_bits.between?(0, 15)
        @ring_write = write
        @ring_size_bits = size_bits
      end

      def set_bswap(on) = @bswap = on
      def set_irq_quiet(on) = @irq_quiet = on
      def set_high_priority(on) = @high_priority = on
      def set_enable(on) = @enable = on
      def set_sniff_enable(on) = @sniff_enable = on

      # CTRL for the chip's field positions (Chip#dma_ctrl)
      def ctrl_value(f)
        size = @data_size == 1 ? 0 : (@data_size == 2 ? 1 : 2)
        ((@enable ? 1 : 0) << f[:en]) | ((@high_priority ? 1 : 0) << f[:high_priority]) | (size << f[:data_size]) |
          ((@read_increment ? 1 : 0) << f[:incr_read]) | ((@write_increment ? 1 : 0) << f[:incr_write]) |
          (@ring_size_bits << f[:ring_size]) | ((@ring_write ? 1 : 0) << f[:ring_sel]) | (@chain_to << f[:chain_to]) |
          (@dreq << f[:treq_sel]) | ((@irq_quiet ? 1 : 0) << f[:irq_quiet]) | ((@bswap ? 1 : 0) << f[:bswap]) |
          ((@sniff_enable ? 1 : 0) << f[:sniff_en])
      end
    end

    class Channel
      attr_reader :index

      def initialize(dma, index)
        @dma = dma
        @index = index
      end

      def bus = @dma.bus
      def reg(off) = @dma.reg(CH_STRIDE * @index + off)
      def mask = 1 << @index

      # pico-sdk's dma_channel_configure: addresses, count, then CTRL (which starts the channel if trigger)
      def configure(config, write_addr, read_addr, count, trigger)
        set_read_addr(read_addr, false)
        set_write_addr(write_addr, false)
        set_trans_count(count, false)
        set_config(config, trigger)
      end

      def set_config(config, trigger) = bus.write32(reg(trigger ? CTRL_TRIG : AL1_CTRL), config.ctrl_value(@dma.chip.dma_ctrl))
      def set_read_addr(a, trigger) = bus.write32(reg(trigger ? AL3_READ_ADDR_TRIG : READ_ADDR), a)
      def set_write_addr(a, trigger) = bus.write32(reg(trigger ? AL2_WRITE_ADDR_TRIG : WRITE_ADDR), a)

      def set_trans_count(n, trigger)
        raise "DMA transfer count must be 0-2147483647 (got #{n})" if n < 0
        raise "RP2350 DMA transfer count must be below 2^28 (the top 4 bits are the mode)" if !@dma.chip.rp2040? && n >= 0x1000_0000
        bus.write32(reg(trigger ? AL1_TRANS_COUNT_TRIG : TRANS_COUNT), n)
      end

      def start = bus.write32(@dma.reg(@dma.chip.dma_multi_chan_trigger), mask)
      def is_busy? = ((bus.read32(reg(CTRL_TRIG)) >> @dma.chip.dma_ctrl[:busy]) & 1) != 0

      def wait_for_finish_blocking
        while is_busy?
        end
      end

      # Transfers left; read and write addresses (they move as the channel runs)
      def get_trans_count = bus.read32(reg(TRANS_COUNT))
      def get_read_addr = bus.read32(reg(READ_ADDR))
      def get_write_addr = bus.read32(reg(WRITE_ADDR))

      # Error flags in CTRL: [read error, write error] (bus errors; they stop the channel)
      def read_error? = (bus.read32(reg(CTRL_TRIG)) & (1 << 30)) != 0
      def write_error? = (bus.read32(reg(CTRL_TRIG)) & (1 << 29)) != 0

      # Stop the channel (pico-sdk's dma_channel_abort, with erratum RP2040-E13's workaround: an abort with
      # transfers in flight finishes them as a normal completion and raises the channel's interrupt flag. So the
      # interrupt enables are cleared first, BUSY is polled rather than the abort bit, and the spurious flag cleared)
      def abort
        e0 = (@dma.bus.read32(@dma.irqn_reg(0, INTE0)) & mask) != 0
        e1 = (@dma.bus.read32(@dma.irqn_reg(1, INTE0)) & mask) != 0
        @dma.irqn_set_channel_mask_enabled(0, mask, false)
        @dma.irqn_set_channel_mask_enabled(1, mask, false)
        bus.write32(@dma.reg(@dma.chip.dma_chan_abort), mask)
        while is_busy?
        end
        acknowledge_irq0
        acknowledge_irq1
        @dma.irqn_set_channel_mask_enabled(0, mask, true) if e0
        @dma.irqn_set_channel_mask_enabled(1, mask, true) if e1
      end

      def set_irq0_enabled(on) = @dma.irqn_set_channel_mask_enabled(0, mask, on)
      def set_irq1_enabled(on) = @dma.irqn_set_channel_mask_enabled(1, mask, on)
      def get_irq0_status = (@dma.irqn_get_status(0) & mask) != 0
      def get_irq1_status = (@dma.irqn_get_status(1) & mask) != 0
      def acknowledge_irq0 = @dma.irqn_acknowledge_channel_mask(0, mask)
      def acknowledge_irq1 = @dma.irqn_acknowledge_channel_mask(1, mask)
    end
  end
end
