# SPI controller (Arm PL022; names follow pico-sdk's hardware_spi without the spi_ prefix). Pins are not touched:
# route them with gpio.set_function(pin, :spi). The bit rate is worked out from clk_peri.
# Frames are 4-16 bits; data is passed as Arrays of Integers.
require_relative "chip"
require_relative "resets"
require_relative "clocks"

module Pico
  class SPI
    SSPCR0 = 0x00
    SSPCR1 = 0x04
    SSPDR = 0x08
    SSPSR = 0x0c
    SSPCPSR = 0x10
    SSPDMACR = 0x24                  # TXDMAE bit 1, RXDMAE bit 0
    CR1_LBM = 1 << 0
    CR1_SSE = 1 << 1
    CR1_MS = 1 << 2
    SR_TFE = 1 << 0
    SR_TNF = 1 << 1
    SR_RNE = 1 << 2
    SR_BSY = 1 << 4

    attr_reader :index

    def initialize(bus, chip, index)
      raise "#{chip.name} SPI must be 0-#{chip.spi_bases.size - 1}" unless index.between?(0, chip.spi_bases.size - 1)
      @bus = bus
      @chip = chip
      @index = index
      @base = chip.spi_bases[index]
    end

    def reg(off) = @base + off
    def block = @index == 0 ? :spi0 : :spi1

    # Reset, then controller mode, 8-bit frames, CPOL 0 / CPHA 0, at about baud. Returns the actual rate (pico-sdk's spi_init)
    def init(baud)
      Resets.new(@bus, @chip).reset_unreset_block_wait([block])
      actual = set_baudrate(baud)
      set_format(8, 0, 0)
      @bus.set_bits(reg(SSPDMACR), 3)            # DREQs for DMA, as pico-sdk's spi_init does
      @bus.set_bits(reg(SSPCR1), CR1_SSE)
      actual
    end

    def deinit = Resets.new(@bus, @chip).reset_block([block])

    # Data register address, for DMA (write_addr / read_addr with DREQ spi<n>_tx / spi<n>_rx)
    def dr_addr = reg(SSPDR)

    # pico-sdk's spi_set_baudrate: the smallest even prescale (2-254) that leaves a post-divide (1-256) in range,
    # then the largest post-divide whose rate does not exceed baud. Comparisons are rearranged to stay within 32 bits
    def set_baudrate(baud)
      freq = Clocks.new(@bus, @chip).get_hz(:peri)
      raise "clk_peri is not running" if freq == 0
      raise "SPI baud must be positive" if baud <= 0
      q = freq / baud
      prescale = 2
      while prescale <= 254
        break if q < prescale * 256                     # freq < prescale * 256 * baud
        prescale += 2
      end
      raise "SPI baud #{baud} is too slow for clk_peri #{freq}Hz" if prescale > 254
      postdiv = 256
      while postdiv > 1
        break if freq / (prescale * (postdiv - 1)) > baud
        postdiv -= 1
      end
      with_disabled do
        @bus.write32(reg(SSPCPSR), prescale)
        @bus.write_masked(reg(SSPCR0), (postdiv - 1) << 8, 0xff << 8)
      end
      freq / (prescale * postdiv)
    end

    def get_baudrate
      freq = Clocks.new(@bus, @chip).get_hz(:peri)
      prescale = @bus.read32(reg(SSPCPSR)) & 0xff
      postdiv = ((@bus.read32(reg(SSPCR0)) >> 8) & 0xff) + 1
      freq / (prescale * postdiv)
    end

    # data_bits 4-16, cpol 0/1, cpha 0/1, MSB first (the PL022 has no LSB-first mode)
    def set_format(data_bits, cpol, cpha)
      raise "SPI data bits must be 4-16" unless data_bits.between?(4, 16)
      raise "cpol and cpha must be 0 or 1" unless cpol.between?(0, 1) && cpha.between?(0, 1)
      with_disabled do
        @bus.write_masked(reg(SSPCR0), (data_bits - 1) | (cpol << 6) | (cpha << 7), 0xff)   # FRF 0: Motorola
      end
    end

    # Controller (false) or peripheral (true) mode
    def set_slave(on) = with_disabled { @bus.write_masked(reg(SSPCR1), on ? CR1_MS : 0, CR1_MS) }

    # Internal loopback: the transmit shifter feeds the receive shifter, the pins are not used (PL022 LBM; not in pico-sdk)
    def set_loopback(on) = @bus.write_masked(reg(SSPCR1), on ? CR1_LBM : 0, CR1_LBM)

    def with_disabled
      cr1 = @bus.read32(reg(SSPCR1))
      @bus.clear_bits(reg(SSPCR1), CR1_SSE) if (cr1 & CR1_SSE) != 0
      yield
      @bus.set_bits(reg(SSPCR1), CR1_SSE) if (cr1 & CR1_SSE) != 0
    end

    def is_writable? = (@bus.read32(reg(SSPSR)) & SR_TNF) != 0
    def is_readable? = (@bus.read32(reg(SSPSR)) & SR_RNE) != 0
    def is_busy? = (@bus.read32(reg(SSPSR)) & SR_BSY) != 0

    FIFO_DEPTH = 8

    # Send every frame and return the frames received at the same time (pico-sdk's spi_write_read_blocking:
    # keeps the TX FIFO topped up, never more than the FIFO depth ahead of what has been read back)
    def write_read_blocking(frames)
      out = []
      tx = 0
      n = frames.size
      while out.size < n
        if tx < n && is_writable? && out.size + FIFO_DEPTH > tx
          @bus.write32(reg(SSPDR), frames[tx] & 0xffff)
          tx += 1
        end
        out << (@bus.read32(reg(SSPDR)) & 0xffff) if out.size < tx && is_readable?
      end
      out
    end

    # Send frames and throw away what comes back
    def write_blocking(frames)
      write_read_blocking(frames)
      frames.size
    end

    # Receive count frames while sending repeated_tx each time
    def read_blocking(repeated_tx, count)
      frames = []
      count.times { frames << repeated_tx }
      write_read_blocking(frames)
    end
  end
end
