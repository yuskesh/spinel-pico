# A block of RAM outside Ruby's objects, for DMA (which needs a plain address) and anything else that reads or writes
# memory by address. Allocated with C aligned_alloc and never moved or collected: call free when done.
# Offsets are in bytes; read32 returns a signed 32-bit Integer like MMIOBus#read32. Device only (Spinel FFI)
module Pico
  module RAMBufferFFI
    ffi_source <<~C
      #include <stdint.h>
      #include <stdlib.h>
      #include <string.h>
      static intptr_t pico_mem_alloc(intptr_t align, intptr_t bytes) {
        size_t a = (size_t)align, n = ((size_t)bytes + a - 1) / a * a;   /* aligned_alloc wants a multiple of align */
        void *p = aligned_alloc(a, n ? n : a);
        if (p) memset(p, 0, n ? n : a);
        return (intptr_t)p;
      }
      static intptr_t pico_mem_free(intptr_t p) { free((void *)p); return 0; }
      static intptr_t pico_mem_read8(intptr_t a) { return *(volatile uint8_t *)a; }
      static intptr_t pico_mem_write8(intptr_t a, intptr_t v) { *(volatile uint8_t *)a = (uint8_t)v; return 0; }
      static intptr_t pico_mem_read16(intptr_t a) { return *(volatile uint16_t *)a; }
      static intptr_t pico_mem_write16(intptr_t a, intptr_t v) { *(volatile uint16_t *)a = (uint16_t)v; return 0; }
      static intptr_t pico_mem_read32(intptr_t a) { return (intptr_t)*(volatile uint32_t *)a; }
      static intptr_t pico_mem_write32(intptr_t a, intptr_t v) { *(volatile uint32_t *)a = (uint32_t)v; return 0; }
    C
    ffi_func :pico_mem_alloc, [:long, :long], :long
    ffi_func :pico_mem_free, [:long], :long
    ffi_func :pico_mem_read8, [:long], :long
    ffi_func :pico_mem_write8, [:long, :long], :long
    ffi_func :pico_mem_read16, [:long], :long
    ffi_func :pico_mem_write16, [:long, :long], :long
    ffi_func :pico_mem_read32, [:long], :long
    ffi_func :pico_mem_write32, [:long, :long], :long
  end

  class RAMBuffer
    attr_reader :addr, :size

    # align: a power of two, at least 4 (a DMA ring of 2^n bytes needs a buffer aligned to 2^n)
    def initialize(size, align)
      raise "RAMBuffer size must be positive (got #{size})" if size <= 0
      raise "RAMBuffer align must be a power of two, at least 4 (got #{align})" if align < 4 || (align & (align - 1)) != 0
      @size = size
      @addr = RAMBufferFFI.pico_mem_alloc(align, size)
      raise "RAMBuffer: no room for #{size} bytes (align #{align})" if @addr == 0
    end

    def free
      RAMBufferFFI.pico_mem_free(@addr) if @addr != 0
      @addr = 0
    end

    def read8(off) = RAMBufferFFI.pico_mem_read8(at(off, 1))
    def write8(off, v) = RAMBufferFFI.pico_mem_write8(at(off, 1), v)
    def read16(off) = RAMBufferFFI.pico_mem_read16(at(off, 2))
    def write16(off, v) = RAMBufferFFI.pico_mem_write16(at(off, 2), v)
    def read32(off) = RAMBufferFFI.pico_mem_read32(at(off, 4))
    def write32(off, v) = RAMBufferFFI.pico_mem_write32(at(off, 4), v)

    def at(off, width)
      raise "RAMBuffer was freed" if @addr == 0
      raise "RAMBuffer offset #{off} (#{width} bytes) is outside 0-#{@size - 1}" if off < 0 || off + width > @size
      raise "RAMBuffer offset #{off} is not #{width}-byte aligned" if (off % width) != 0
      @addr + off
    end

    # Words 0..n-1 as an Array (n = size / 4 by default)
    def words(n)
      out = []
      n.times { |i| out << read32(4 * i) }
      out
    end
  end
end
