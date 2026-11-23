# Entry point for programs that run on the microcontroller (bare-full): every driver plus the MMIO bus.
# Host-side code (tests, tools) requires the individual files under lib/pico and lib/pio instead,
# because lib/pico/mmio.rb uses Spinel FFI.
require_relative "pico/board"
require_relative "pico/mmio"
require_relative "pico/bootrom"
require_relative "pico/flash"
require_relative "pico/flash_rom"
require_relative "pico/ram_buffer"
require_relative "pico/irq"

module Pico
  class Board
    def flash = Flash.new(@bus, @chip, FlashROM.new)
  end

  def self.rp2040 = Board.new(MMIOBus.new, RP2040)

  # RP2350A (Pico 2). The register numbers are checked against pico-sdk (tools/regs_check.sh), but nothing has run on
  # an RP2350 yet: bare-full has no RP2350 chip family, so nothing can be built for it. Pico::IRQ is RP2040 only
  def self.rp2350 = Board.new(MMIOBus.new, RP2350)

  # Reboot into BOOTSEL (USB drive) mode; see lib/pico/bootrom.rb
  def self.reset_usb_boot = BootROM.reset_usb_boot(0, 0)
end
