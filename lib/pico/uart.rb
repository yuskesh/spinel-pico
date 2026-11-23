# UART (names follow pico-sdk's hardware_uart; the block is an Arm PL011). Pins are not touched: route them with
# gpio.set_function(pin, :uart). The baud rate is worked out from clk_peri, read from the clock registers.
# Under bare-full UART0 is the console (GPIO 0/1, 115200 8N1); init(0) re-initialises it after the console has
# finished sending.
require_relative "chip"
require_relative "timer"
require_relative "resets"
require_relative "clocks"

module Pico
  class UART
    DR = 0x00
    FR = 0x18
    IBRD = 0x24
    FBRD = 0x28
    LCR_H = 0x2c
    CR = 0x30
    DMACR = 0x48                     # TXDMAE bit 1, RXDMAE bit 0
    FR_BUSY = 1 << 3
    FR_RXFE = 1 << 4
    FR_TXFF = 1 << 5
    CR_UARTEN = 1 << 0
    CR_LBE = 1 << 7
    CR_TXE = 1 << 8
    CR_RXE = 1 << 9
    LCR_H_PEN = 1 << 1
    LCR_H_EPS = 1 << 2
    LCR_H_STP2 = 1 << 3
    LCR_H_FEN = 1 << 4
    LCR_H_WLEN = 3 << 5

    attr_reader :index

    def initialize(bus, chip, index)
      raise "#{chip.name} UART must be 0-#{chip.uart_bases.size - 1}" unless index.between?(0, chip.uart_bases.size - 1)
      @bus = bus
      @chip = chip
      @index = index
      @base = chip.uart_bases[index]
    end

    def reg(off) = @base + off
    def block = @index == 0 ? :uart0 : :uart1
    def enabled? = !Resets.new(@bus, @chip).in_reset?(block) && (@bus.read32(reg(CR)) & CR_UARTEN) != 0

    # Reset the block, then 8N1 at baud with the FIFOs on. Returns the baud rate actually set (pico-sdk's uart_init)
    def init(baud)
      tx_wait_blocking if enabled?
      Resets.new(@bus, @chip).reset_unreset_block_wait([block])
      actual = set_baudrate(baud)
      set_format(8, 1, :none)
      @bus.set_bits(reg(LCR_H), LCR_H_FEN)
      @bus.write32(reg(CR), CR_UARTEN | CR_TXE | CR_RXE)
      @bus.write32(reg(DMACR), 3)                # DREQs for DMA, as pico-sdk's uart_init does
      actual
    end

    # Data register address, for DMA (write_addr / read_addr with DREQ uart<n>_tx / uart<n>_rx)
    def dr_addr = reg(DR)

    def deinit
      tx_wait_blocking if enabled?
      Resets.new(@bus, @chip).reset_block([block])
    end

    # pico-sdk's uart_set_baudrate: divider = clk_peri / (16 * baud) in 1/64 steps. Returns the actual rate
    def set_baudrate(baud)
      peri = Clocks.new(@bus, @chip).get_hz(:peri)
      raise "clk_peri is not running (or its frequency is unknown)" if peri == 0
      raise "clk_peri #{peri}Hz is too fast for the 32-bit baud calculation" if peri > 0x7FFF_FFFF / 8
      div = 8 * peri / baud + 1
      ibrd = div >> 7
      fbrd = (div & 0x7f) >> 1
      if ibrd == 0
        ibrd = 1
        fbrd = 0
      elsif ibrd >= 65_535
        ibrd = 65_535
        fbrd = 0
      end
      with_uart_disabled do
        @bus.write32(reg(IBRD), ibrd)
        @bus.write32(reg(FBRD), fbrd)
        @bus.set_bits(reg(LCR_H), 0)                 # a write to LCR_H latches the divisor
      end
      4 * peri / (64 * ibrd + fbrd)
    end

    # data_bits 5-8, stop_bits 1-2, parity :none, :even or :odd
    def set_format(data_bits, stop_bits, parity)
      raise "data bits must be 5-8" unless data_bits.between?(5, 8)
      raise "stop bits must be 1 or 2" unless stop_bits.between?(1, 2)
      raise "parity must be :none, :even or :odd" unless parity == :none || parity == :even || parity == :odd
      v = ((data_bits - 5) << 5) | ((stop_bits - 1) << 3) | (parity == :none ? 0 : LCR_H_PEN) |
          (parity == :even ? LCR_H_EPS : 0)
      with_uart_disabled { @bus.write_masked(reg(LCR_H), v, LCR_H_WLEN | LCR_H_STP2 | LCR_H_PEN | LCR_H_EPS) }
    end

    # Changing the divisor or the line format while the UART runs can corrupt a character (pico-sdk 2.x does the same)
    def with_uart_disabled
      cr = @bus.read32(reg(CR))
      if (cr & CR_UARTEN) != 0
        tx_wait_blocking
        @bus.clear_bits(reg(CR), CR_UARTEN)
      end
      yield
      @bus.write32(reg(CR), cr) if (cr & CR_UARTEN) != 0
    end

    def set_fifo_enabled(on)
      with_uart_disabled { @bus.write_masked(reg(LCR_H), on ? LCR_H_FEN : 0, LCR_H_FEN) }
    end

    # Internal loopback: what is sent is received, and the TX pin stays idle (PL011 LBE; not in pico-sdk).
    # An RX that is not routed to a pin sees a constant low line (a break), so the RX FIFO may already hold 0 bytes
    # from before the switch: call drain_rx after one character time
    def set_loopback(on) = @bus.write_masked(reg(CR), on ? CR_LBE : 0, CR_LBE)

    # Throw away everything in the RX FIFO; returns how many bytes were dropped
    def drain_rx
      n = 0
      while is_readable?
        @bus.read32(reg(DR))
        n += 1
      end
      n
    end

    def is_writable? = (@bus.read32(reg(FR)) & FR_TXFF) == 0
    def is_readable? = (@bus.read32(reg(FR)) & FR_RXFE) == 0

    def tx_wait_blocking
      while (@bus.read32(reg(FR)) & FR_BUSY) != 0
      end
    end

    # One byte (0-255), waiting while the TX FIFO is full
    def putc_raw(byte)
      while !is_writable?
      end
      @bus.write32(reg(DR), byte & 0xFF)
    end

    def write(str) = str.bytes.each { |b| putc_raw(b) }

    def puts(str)
      write(str)
      putc_raw(13)
      putc_raw(10)
    end

    # One byte, waiting while the RX FIFO is empty
    def getc
      while !is_readable?
      end
      @bus.read32(reg(DR)) & 0xFF
    end

    # Like getc, but gives up after timeout_us microseconds of the given Pico::Timer; returns -1 then
    # (The elapsed time is worked out here, not with timer.us_since: if a program never calls getc_timeout, Spinel
    # cannot type timer, and passing its values to Timer#us_since would make every caller of us_since use boxed values)
    def getc_timeout(timer, timeout_us)
      start = timer.time_us_31
      while !is_readable?
        return -1 if ((timer.time_us_31 - start) & Timer::MASK31) >= timeout_us
      end
      @bus.read32(reg(DR)) & 0xFF
    end
  end
end
