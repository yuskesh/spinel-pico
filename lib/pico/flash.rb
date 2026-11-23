# The on-board QSPI flash (names follow pico-sdk's hardware_flash). RP2040 only for now.
# Offsets are from the start of flash (0 = XIP address 0x10000000), as in pico-sdk.
#   read via XIP: read_u32, read
#   erase / program through the boot ROM: range_erase (4096-byte sectors), range_program (256-byte pages)
# Erasing and programming need code running from RAM with XIP off; that part is C in lib/pico/flash_rom.rb (the rom
# object passed in), so this file holds only the checks and stays testable on the host.
# The running program lives in flash too: offsets below image_end_offset (rounded up to a sector) are refused.
require_relative "chip"

module Pico
  class Flash
    PAGE_SIZE = 256
    SECTOR_SIZE = 4096

    attr_reader :size

    # rom: erase(offset, count), program_page(offset, bytes), image_end (XIP address just past the program image)
    def initialize(bus, chip, rom)
      raise "Pico::Flash supports only RP2040 (got #{chip.name})" unless chip.rp2040?
      @bus = bus
      @chip = chip
      @rom = rom
      @size = chip.flash_size
    end

    def image_end_offset = @rom.image_end - @chip.xip_base

    # The first offset that may be erased or programmed: the sector after the program image
    def first_free_offset = (image_end_offset + SECTOR_SIZE - 1) / SECTOR_SIZE * SECTOR_SIZE

    def read_u32(offset)
      check_range(offset, 4, "read")
      raise "read_u32 offset #{offset} is not 4-byte aligned" if offset % 4 != 0
      @bus.read32(@chip.xip_base + offset)
    end

    # count bytes from offset, as an Array of 0-255
    def read(offset, count)
      check_range(offset, count, "read")
      out = []
      a = offset
      while a < offset + count
        w = @bus.read32(@chip.xip_base + a / 4 * 4)
        out << ((w >> (8 * (a % 4))) & 0xFF)
        a += 1
      end
      out
    end

    def range_erase(offset, count)
      raise "erase offset #{offset} is not a multiple of #{SECTOR_SIZE}" if offset % SECTOR_SIZE != 0
      raise "erase count #{count} is not a positive multiple of #{SECTOR_SIZE}" if count <= 0 || count % SECTOR_SIZE != 0
      check_writable(offset, count, "erase")
      @rom.erase(offset, count)
    end

    # bytes: Array of 0-255, a multiple of 256 long. Programming can only clear bits: erase first
    def range_program(offset, bytes)
      raise "program offset #{offset} is not a multiple of #{PAGE_SIZE}" if offset % PAGE_SIZE != 0
      if bytes.size == 0 || bytes.size % PAGE_SIZE != 0
        raise "program length #{bytes.size} is not a positive multiple of #{PAGE_SIZE}"
      end
      bytes.each { |b| raise "program data must be bytes (0-255), got #{b}" unless b.between?(0, 255) }
      check_writable(offset, bytes.size, "program")
      page = 0
      while page < bytes.size
        @rom.program_page(offset + page, bytes[page, PAGE_SIZE])
        page += PAGE_SIZE
      end
    end

    def check_range(offset, count, what)
      raise "#{what} of #{count} bytes at #{offset} is outside the #{@size}-byte flash" if offset < 0 || count < 0 || offset + count > @size
    end

    def check_writable(offset, count, what)
      check_range(offset, count, what)
      free = first_free_offset
      raise "#{what} at #{offset} would overwrite the running program (free space starts at #{free})" if offset < free
    end
  end
end
