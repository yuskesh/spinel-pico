# I2C controller (Synopsys DW_apb_i2c; names follow pico-sdk's hardware_i2c without the i2c_ prefix).
# Pins are not touched: route SDA and SCL with gpio.set_function(pin, :i2c) and enable pull-ups (on chip or external).
# The bus clock is worked out from clk_sys (not clk_peri). 7-bit addresses only.
#
# Results follow pico-sdk: write_blocking / read_blocking return the number of bytes transferred, or ERROR_GENERIC
# (no acknowledge, for example nothing at that address) or ERROR_TIMEOUT. read_blocking fills the Array it is given.
# The object remembers whether the next transfer starts with a repeated START (after nostop = true), as pico-sdk's
# i2c_inst_t does, so keep using the same object for related transfers.
require_relative "chip"
require_relative "resets"
require_relative "clocks"

module Pico
  class I2C
    IC_CON = 0x00
    IC_TAR = 0x04
    IC_SAR = 0x08
    IC_DATA_CMD = 0x10
    IC_FS_SCL_HCNT = 0x1c
    IC_FS_SCL_LCNT = 0x20
    IC_RAW_INTR_STAT = 0x34
    IC_RX_TL = 0x38
    IC_TX_TL = 0x3c
    IC_CLR_TX_ABRT = 0x54
    IC_CLR_STOP_DET = 0x60
    IC_ENABLE = 0x6c
    IC_TXFLR = 0x74
    IC_RXFLR = 0x78
    IC_SDA_HOLD = 0x7c
    IC_TX_ABRT_SOURCE = 0x80
    IC_DMA_CR = 0x88
    IC_FS_SPKLEN = 0xa0
    CON_MASTER_MODE = 0x001
    CON_SPEED_FAST = 2 << 1
    CON_SPEED = 0x006
    CON_RESTART_EN = 0x020
    CON_SLAVE_DISABLE = 0x040
    CON_TX_EMPTY_CTRL = 0x100
    CON_RX_FIFO_FULL_HLD_CTRL = 0x200
    CMD_READ = 0x100
    CMD_STOP = 0x200
    CMD_RESTART = 0x400
    RAW_TX_EMPTY = 0x010
    RAW_TX_ABRT = 0x040
    RAW_STOP_DET = 0x200
    ABRT_7B_ADDR_NOACK = 0x1
    ABRT_TXDATA_NOACK = 0x8
    TX_FIFO_DEPTH = 16
    ERROR_TIMEOUT = -1               # pico-sdk's PICO_ERROR_TIMEOUT
    ERROR_GENERIC = -2               # pico-sdk's PICO_ERROR_GENERIC

    attr_reader :index, :last_abort_reason

    def initialize(bus, chip, index)
      raise "#{chip.name} I2C must be 0-#{chip.i2c_bases.size - 1}" unless index.between?(0, chip.i2c_bases.size - 1)
      @bus = bus
      @chip = chip
      @index = index
      @base = chip.i2c_bases[index]
      @restart_on_next = false
      @last_abort_reason = 0
    end

    def reg(off) = @base + off
    def block = @index == 0 ? :i2c0 : :i2c1

    # Reset, then controller mode, fast-mode timing for baud. Returns the actual rate (pico-sdk's i2c_init)
    def init(baud)
      Resets.new(@bus, @chip).reset_unreset_block_wait([block])
      @restart_on_next = false
      @bus.write32(reg(IC_ENABLE), 0)
      @bus.write32(reg(IC_CON), CON_SPEED_FAST | CON_MASTER_MODE | CON_SLAVE_DISABLE | CON_RESTART_EN | CON_TX_EMPTY_CTRL)
      @bus.write32(reg(IC_TX_TL), 0)
      @bus.write32(reg(IC_RX_TL), 0)
      @bus.write32(reg(IC_DMA_CR), 3)                         # TDMAE, RDMAE
      set_baudrate(baud)
    end

    def deinit = Resets.new(@bus, @chip).reset_block([block])

    # pico-sdk's i2c_set_baudrate: period = clk_sys / baud, low 3/5 of it, high the rest
    def set_baudrate(baud)
      raise "I2C baud must be positive" if baud <= 0
      freq = Clocks.new(@bus, @chip).get_hz(:sys)
      period = (freq + baud / 2) / baud
      lcnt = period * 3 / 5
      hcnt = period - lcnt
      raise "I2C baud #{baud} needs SCL counts #{hcnt}/#{lcnt}, outside 8-65535 at clk_sys #{freq}Hz" if hcnt < 8 || lcnt < 8 || hcnt > 0xffff || lcnt > 0xffff
      raise "clk_sys #{freq}Hz is too fast for the 32-bit hold-time calculation" if freq > 0x7FFF_FFFF / 3
      hold = baud < 1_000_000 ? freq * 3 / 10_000_000 + 1 : freq * 3 / 25_000_000 + 1
      raise "I2C SDA hold #{hold} does not fit the low period #{lcnt}" if hold > lcnt - 2
      @bus.write32(reg(IC_ENABLE), 0)
      @bus.write_masked(reg(IC_CON), CON_SPEED_FAST, CON_SPEED)
      @bus.write32(reg(IC_FS_SCL_HCNT), hcnt)
      @bus.write32(reg(IC_FS_SCL_LCNT), lcnt)
      @bus.write32(reg(IC_FS_SPKLEN), lcnt < 16 ? 1 : lcnt / 16)
      @bus.write_masked(reg(IC_SDA_HOLD), hold, 0xffff)
      @bus.write32(reg(IC_ENABLE), 1)
      freq / period
    end

    # Answer as a target at addr (true) or go back to controller mode (false) (pico-sdk's i2c_set_slave_mode)
    def set_slave_mode(slave, addr)
      check_addr(addr)
      @bus.write32(reg(IC_ENABLE), 0)
      master_bits = CON_MASTER_MODE | CON_SLAVE_DISABLE
      if slave
        @bus.write_masked(reg(IC_CON), CON_RX_FIFO_FULL_HLD_CTRL, master_bits | CON_RX_FIFO_FULL_HLD_CTRL)
        @bus.write32(reg(IC_SAR), addr)
      else
        @bus.write_masked(reg(IC_CON), master_bits, master_bits | CON_RX_FIFO_FULL_HLD_CTRL)
      end
      @bus.write32(reg(IC_ENABLE), 1)
    end

    def write_blocking(addr, bytes, nostop) = write_internal(addr, bytes, nostop, nil, 0)
    def read_blocking(addr, dst, len, nostop) = read_internal(addr, dst, len, nostop, nil, 0)

    # As above, but give up after timeout_us microseconds of the given Pico::Timer (returns ERROR_TIMEOUT)
    def write_timeout_us(addr, bytes, nostop, timer, timeout_us) = write_internal(addr, bytes, nostop, timer, timeout_us)
    def read_timeout_us(addr, dst, len, nostop, timer, timeout_us) = read_internal(addr, dst, len, nostop, timer, timeout_us)

    def write_internal(addr, bytes, nostop, timer, timeout_us)
      check_addr(addr)
      raise "I2C write needs at least one byte" if bytes.empty?
      start = timer.nil? ? 0 : timer.time_us_31
      set_target(addr)
      abort = false
      timeout = false
      reason = 0
      n = 0
      len = bytes.size
      while n < len
        first = n == 0
        last = n == len - 1
        @bus.write32(reg(IC_DATA_CMD), cmd_bits(first, last, nostop) | (bytes[n] & 0xff))
        until (@bus.read32(reg(IC_RAW_INTR_STAT)) & RAW_TX_EMPTY) != 0
          timeout = timed_out?(timer, start, timeout_us)
          break if timeout
        end
        unless timeout
          reason = @bus.read32(reg(IC_TX_ABRT_SOURCE))
          if reason != 0
            @bus.read32(reg(IC_CLR_TX_ABRT))                    # reading clears the abort
            abort = true
          end
          timeout = wait_stop(timer, start, timeout_us) if abort || (last && !nostop)
        end
        abort = true if timeout
        break if abort
        n += 1
      end
      @restart_on_next = nostop
      @last_abort_reason = reason
      return n unless abort
      return ERROR_TIMEOUT if timeout
      return n if (reason & ABRT_7B_ADDR_NOACK) == 0 && (reason & ABRT_TXDATA_NOACK) != 0   # data byte refused
      ERROR_GENERIC
    end

    def read_internal(addr, dst, len, nostop, timer, timeout_us)
      check_addr(addr)
      raise "I2C read needs at least one byte" if len <= 0
      dst.clear
      start = timer.nil? ? 0 : timer.time_us_31
      set_target(addr)
      abort = false
      timeout = false
      reason = 0
      n = 0
      while n < len
        first = n == 0
        last = n == len - 1
        while TX_FIFO_DEPTH - @bus.read32(reg(IC_TXFLR)) <= 0
        end
        @bus.write32(reg(IC_DATA_CMD), cmd_bits(first, last, nostop) | CMD_READ)
        while true
          reason = @bus.read32(reg(IC_TX_ABRT_SOURCE))
          if (@bus.read32(reg(IC_RAW_INTR_STAT)) & RAW_TX_ABRT) != 0
            abort = true
            @bus.read32(reg(IC_CLR_TX_ABRT))
          end
          timeout = timed_out?(timer, start, timeout_us)
          abort = true if timeout
          break if abort || @bus.read32(reg(IC_RXFLR)) != 0
        end
        break if abort
        dst << (@bus.read32(reg(IC_DATA_CMD)) & 0xff)
        n += 1
      end
      @restart_on_next = nostop
      @last_abort_reason = reason
      return n unless abort
      timeout ? ERROR_TIMEOUT : ERROR_GENERIC
    end

    def cmd_bits(first, last, nostop)
      (first && @restart_on_next ? CMD_RESTART : 0) | (last && !nostop ? CMD_STOP : 0)
    end

    def set_target(addr)
      @bus.write32(reg(IC_ENABLE), 0)
      @bus.write32(reg(IC_TAR), addr)
      @bus.write32(reg(IC_ENABLE), 1)
    end

    def wait_stop(timer, start, timeout_us)
      until (@bus.read32(reg(IC_RAW_INTR_STAT)) & RAW_STOP_DET) != 0
        return true if timed_out?(timer, start, timeout_us)
      end
      @bus.read32(reg(IC_CLR_STOP_DET))
      false
    end

    def timed_out?(timer, start, timeout_us)
      return false if timer.nil?
      timer.us_since(start) >= timeout_us
    end

    # 0x00-0x07 and 0x78-0x7f are reserved by the I2C specification (pico-sdk refuses them too)
    def check_addr(addr)
      raise "I2C address must be 7-bit (got #{addr})" unless addr.between?(0, 0x7f)
      raise "I2C address 0x#{addr.to_s(16)} is reserved" if (addr & 0x78) == 0 || (addr & 0x78) == 0x78
    end

    def self.reserved_addr?(addr) = (addr & 0x78) == 0 || (addr & 0x78) == 0x78
  end
end
