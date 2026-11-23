/* port/chip/rp2040: core 0 of the RP2040 on the Raspberry Pi Pico.
 *
 * Flash (the Pico's 2 MB W25Q16, read through XIP at 0x10000000): the first
 * 256 bytes are boot2 (boot2/<name>.S with its CRC), which the boot ROM checks and
 * runs; boot2 starts the image through the vector table at 0x10000100.
 *
 * RAM at 0x20000000, 264 KB: SRAM0-3 (256 KB, striped) and SRAM4-5 (4 KB
 * each), contiguous in the address map. The boot ROM runs boot2 from the top
 * of SRAM5; nothing of it is needed once the image has started.
 *
 * The origins and sizes are the chip family's values (chip.yaml) and the
 * board's (its flash size, where it states one), the stack size the board's
 * policy.stack_bytes; the driver puts them in through the C preprocessor
 * (bf-board.h) before the link.
 *
 * This is the chip family's part of the link script: the memory regions.
 * The runtime's part (platform/common/link.ld) follows it and places the
 * sections in the regions named CODE and RAM.
 */
#ifdef BF_POLICY_RAM_BYTES
#define BF_RAM_BYTES BF_POLICY_RAM_BYTES
#else
#define BF_RAM_BYTES BF_CHIP_RAM_BYTES
#endif
MEMORY
{
  BOOT2 (rx) : ORIGIN = BF_CHIP_FLASH_ORIGIN, LENGTH = BF_CHIP_FLASH_BOOT2_BYTES
  CODE (rx)  : ORIGIN = BF_CHIP_FLASH_ORIGIN + BF_CHIP_FLASH_BOOT2_BYTES, LENGTH = BF_BOARD_FLASH_SIZE_BYTES - BF_CHIP_FLASH_BOOT2_BYTES
  RAM  (rwx) : ORIGIN = BF_CHIP_RAM_ORIGIN, LENGTH = BF_RAM_BYTES
}

/* The second stage goes before the vector table: the boot ROM reads the
 * first BF_CHIP_FLASH_BOOT2_BYTES bytes of flash. */
SECTIONS
{
  .boot2 : { KEEP(*(.boot2)) } > BOOT2
}
INSERT BEFORE .vectors;
ASSERT(SIZEOF(.boot2) == BF_CHIP_FLASH_BOOT2_BYTES, "boot2 must be exactly 256 bytes")
