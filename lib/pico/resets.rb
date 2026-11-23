# Peripheral resets (names follow pico-sdk's hardware_resets). Blocks are named by symbol (:pio0, :uart1, ...)
require_relative "chip"

module Pico
  class Resets
    def initialize(bus, chip)
      @bus = bus
      @chip = chip
    end

    def reset_block(blocks) = @bus.set_bits(@chip.resets_base + RESETS_RESET, @chip.reset_mask(blocks))
    def unreset_block(blocks) = @bus.clear_bits(@chip.resets_base + RESETS_RESET, @chip.reset_mask(blocks))

    # Release the blocks and wait until they are out of reset
    def unreset_block_wait(blocks)
      mask = @chip.reset_mask(blocks)
      @bus.clear_bits(@chip.resets_base + RESETS_RESET, mask)
      n = 0
      while (@bus.read32(@chip.resets_base + RESETS_DONE) & mask) != mask
        n += 1
        raise "#{@chip.name}: timed out waiting for #{blocks.inspect} to leave reset" if n > 100_000
      end
    end

    # Reset then release (leaves no prior state)
    def reset_unreset_block_wait(blocks)
      reset_block(blocks)
      unreset_block_wait(blocks)
    end

    def in_reset?(block) = (@bus.read32(@chip.resets_base + RESETS_RESET) & (1 << @chip.reset_bit(block))) != 0
  end
end
