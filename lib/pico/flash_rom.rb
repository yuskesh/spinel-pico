# The part of flash erase/program that must run with XIP off (inlined into the generated C via Spinel FFI).
# Follows pico-sdk's flash_range_erase / flash_range_program: look up the boot ROM's flash functions
# (RP2040 datasheet 2.8.3.1.3), then, with interrupts masked and from RAM:
#   connect_internal_flash, flash_exit_xip, erase or program, flash_flush_cache, then boot2 (copied to RAM beforehand)
#   to put the flash interface back into XIP mode.
# The RAM function sits in a .data.* section, which bare-full's linker script copies to RAM at reset. It calls only
# the ROM and the RAM copy of boot2, never code in flash. Core 1 must not be running from flash (bare-full leaves it
# asleep in the boot ROM).
require_relative "bootrom"            # pico_rom_func

module Pico
  module FlashROMFFI
    ffi_source <<~C
      #include <stdint.h>
      typedef void (*pico_void_fn)(void);
      typedef void (*pico_erase_fn)(uint32_t, uint32_t, uint32_t, uint8_t);
      typedef void (*pico_program_fn)(uint32_t, const uint8_t *, uint32_t);
      struct pico_flash_fns {
        pico_void_fn connect, exit_xip, flush, boot2;
        pico_erase_fn erase;
        pico_program_fn program;
      };
      static uint8_t pico_flash_page[256];
      static uint32_t pico_boot2_copy[64];
      static int pico_boot2_copied;

      __attribute__((noinline, section(".data.pico_flash_ram")))
      static void pico_flash_ram_op(const struct pico_flash_fns *f, uint32_t op, uint32_t offs, uint32_t count) {
        f->connect();
        f->exit_xip();
        if (op == 0) {
          f->erase(offs, count, 1u << 16, 0xd8);   /* 64 KB block erase (D8h) where it fits */
        } else {
          f->program(offs, pico_flash_page, count);
        }
        f->flush();
        f->boot2();
      }

      static intptr_t pico_flash_op(intptr_t op, intptr_t offs, intptr_t count) {
        struct pico_flash_fns f;
        uint32_t primask;
        void (*volatile ram)(const struct pico_flash_fns *, uint32_t, uint32_t, uint32_t) = pico_flash_ram_op;
        if (!pico_boot2_copied) {
          for (int i = 0; i < 64; i++) pico_boot2_copy[i] = ((volatile uint32_t *)0x10000000u)[i];
          pico_boot2_copied = 1;
        }
        f.connect = (pico_void_fn)pico_rom_func('I', 'F');
        f.exit_xip = (pico_void_fn)pico_rom_func('E', 'X');
        f.erase = (pico_erase_fn)pico_rom_func('R', 'E');
        f.program = (pico_program_fn)pico_rom_func('R', 'P');
        f.flush = (pico_void_fn)pico_rom_func('F', 'C');
        f.boot2 = (pico_void_fn)((uintptr_t)pico_boot2_copy + 1u);   /* Thumb */
        __asm volatile("mrs %0, primask" : "=r"(primask));
        __asm volatile("cpsid i" ::: "memory");
        ram(&f, (uint32_t)op, (uint32_t)offs, (uint32_t)count);
        __asm volatile("msr primask, %0" ::"r"(primask) : "memory");
        return 0;
      }

      static intptr_t pico_flash_page_set(intptr_t i, intptr_t b) {
        pico_flash_page[i & 255] = (uint8_t)b;
        return 0;
      }

      /* the address one past the image's last byte in flash: the link script's name for it (the port contract's
         `image` capability), so that this file does not depend on how the script places .data */
      extern char __image_end[];
      static intptr_t pico_flash_image_end(void) {
        return (intptr_t)__image_end;
      }
    C
    ffi_func :pico_flash_op, [:long, :long, :long], :long
    ffi_func :pico_flash_page_set, [:long, :long], :long
    ffi_func :pico_flash_image_end, [], :long
  end

  class FlashROM
    def erase(offset, count) = FlashROMFFI.pico_flash_op(0, offset, count)

    def program_page(offset, bytes)
      i = 0
      while i < 256
        FlashROMFFI.pico_flash_page_set(i, bytes[i])
        i += 1
      end
      FlashROMFFI.pico_flash_op(1, offset, 256)
    end

    def image_end = FlashROMFFI.pico_flash_image_end
  end
end
