# Register access on the microcontroller (inlined into the generated C via Spinel FFI's ffi_source).
# Only volatile 32-bit reads/writes. Values pass as signed 32-bit (converted to uint32_t on the C side)
#
# Every driver talks to registers through a bus with this interface:
#   read32(addr), write32(addr, v), write32_hl(addr, hi16, lo16),
#   set_bits(addr, mask), clear_bits(addr, mask), xor_bits(addr, mask), write_masked(addr, v, mask)
# On the microcontroller pass Pico::MMIOBus; for host-side checks pass a bus that just records writes (test/fake_bus.rb)
require_relative "chip"

module Pico
  module MMIOFFI
    ffi_source <<~C
      #include <stdint.h>
      static intptr_t pico_mmio_read32(intptr_t a) { return (intptr_t)*(volatile uint32_t *)(uintptr_t)a; }
      static intptr_t pico_mmio_write32(intptr_t a, intptr_t v) {
        *(volatile uint32_t *)(uintptr_t)a = (uint32_t)v;
        return 0;
      }
      static intptr_t pico_mmio_write32_hl(intptr_t a, intptr_t hi, intptr_t lo) {
        *(volatile uint32_t *)(uintptr_t)a = ((uint32_t)hi << 16) | ((uint32_t)lo & 0xFFFFu);
        return 0;
      }
    C
    ffi_func :pico_mmio_read32, [:long], :long
    ffi_func :pico_mmio_write32, [:long, :long], :long
    ffi_func :pico_mmio_write32_hl, [:long, :long, :long], :long
  end

  class MMIOBus
    def read32(a) = MMIOFFI.pico_mmio_read32(a)
    def write32(a, v) = MMIOFFI.pico_mmio_write32(a, v)
    def write32_hl(a, hi, lo) = MMIOFFI.pico_mmio_write32_hl(a, hi, lo)
    def set_bits(a, mask) = MMIOFFI.pico_mmio_write32(a + SET_ALIAS, mask)
    def clear_bits(a, mask) = MMIOFFI.pico_mmio_write32(a + CLR_ALIAS, mask)
    def xor_bits(a, mask) = MMIOFFI.pico_mmio_write32(a + XOR_ALIAS, mask)

    # Change only the bits in mask to those of v, in one atomic write (pico-sdk's hw_write_masked)
    def write_masked(a, v, mask) = xor_bits(a, (read32(a) ^ v) & mask)
  end
end
