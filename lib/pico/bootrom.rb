# Boot ROM functions (RP2040 datasheet 2.8.3; names follow pico-sdk's pico_bootrom). Uses Spinel FFI.
#   Pico::BootROM.reset_usb_boot(activity_pin_mask, disable_interface_mask)
#     reboot into the BOOTSEL USB mode (mass storage drive + PICOBOOT), as if BOOTSEL were held at power-up.
#     activity_pin_mask: GPIOs to flash on USB activity (0 for none); disable_interface_mask: 1 = no drive,
#     2 = no PICOBOOT (0 keeps both). Does not return.
module Pico
  module BootROMFFI
    ffi_source <<~C
      #include <stdint.h>
      typedef void *(*pico_rom_lookup_fn)(const uint16_t *, uint32_t);
      /* rom_func_table is a 16-bit pointer at 0x14 and rom_table_lookup one at 0x18 (datasheet 2.8.3.1) */
      static void *pico_rom_func(uint32_t c1, uint32_t c2) {
        const uint16_t *table = (const uint16_t *)(uintptr_t)*(volatile uint16_t *)0x14u;
        pico_rom_lookup_fn lookup = (pico_rom_lookup_fn)(uintptr_t)*(volatile uint16_t *)0x18u;
        return lookup(table, c1 | (c2 << 8));
      }
      static intptr_t pico_reset_usb_boot(intptr_t pins, intptr_t disable) {
        void (*f)(uint32_t, uint32_t) = (void (*)(uint32_t, uint32_t))pico_rom_func('U', 'B');
        f((uint32_t)pins, (uint32_t)disable);
        return 0;
      }
    C
    ffi_func :pico_reset_usb_boot, [:long, :long], :long
  end

  module BootROM
    def self.reset_usb_boot(activity_pin_mask, disable_interface_mask) =
      BootROMFFI.pico_reset_usb_boot(activity_pin_mask, disable_interface_mask)
  end
end
