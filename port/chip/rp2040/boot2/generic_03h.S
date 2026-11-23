// tools/bare-full: the RP2040's second-stage boot (boot2) for a flash read
// with the 03h command, as the Raspberry Pi Pico's is. A board selects it with
// flash.boot2: generic_03h and gives the flash clock divider.
//
// Copyright (c) 2019-2021 Raspberry Pi (Trading) Ltd.
// SPDX-License-Identifier: BSD-3-Clause
//
// From pico-sdk 2.3.1's src/rp2040/boot_stage2/boot2_generic_03h.S and
// asminclude/boot2_helpers/exit_from_boot2.S, made self-contained: the
// SDK's header macros are replaced by the values they name (hardware/regs
// ssi.h, addressmap.h, m0plus.h), and the code is otherwise the same.
//
// The boot ROM copies the first 256 bytes of flash into SRAM, checks the
// CRC-32 of the first 252 against the last 4, and runs them. This code puts
// the flash interface (SSI) into XIP mode with plain 03h reads, which any
// serial flash answers, then starts the image through the vector table,
// which follows this stage in flash (0x10000100 on the RP2040; the address is
// the family's flash origin plus this stage's size, as the link script's).
// spinel-bare-full assembles it, pads it to 252 bytes and adds the checksum.

    .syntax unified
    .cpu cortex-m0plus
    .thumb
    .section .text
    .global _stage2_boot
    .type _stage2_boot, %function
    .thumb_func
_stage2_boot:
    push {lr}
    ldr r3, =0x18000000          // XIP_SSI_BASE

    movs r1, #0                  // SSIENR = 0: disable to configure
    str r1, [r3, #0x08]

    movs r1, #BF_BOARD_FLASH_CLOCK_DIVIDER  // BAUDR: flash clock = clk_sys / the divider
    str r1, [r3, #0x14]

    // CTRLR0: standard SPI frames (SPI_FRF 0 << 21), 32 clocks per frame
    // (31 << DFS_32 16), send instruction and address then read (TMOD 3 << 8)
    ldr r1, =0x001f0300
    str r1, [r3, #0x00]

    // SPI_CTRLR0 (+0xf4): instruction 03h (<< 24), 24 address bits (6 << 2),
    // 8-bit instruction (2 << 8), both in serial format (TRANS_TYPE 0)
    ldr r1, =0x03000218
    ldr r0, =0x180000f4
    str r1, [r0]

    movs r1, #0                  // CTRLR1: NDF = 0, one 32-bit read
    str r1, [r3, #0x04]

    movs r1, #1                  // SSIENR = 1: XIP is on
    str r1, [r3, #0x08]

    // lr was 0 when the boot ROM entered: start the image; otherwise return
    pop {r0}
    cmp r0, #0
    beq 1f
    bx r0
1:
    ldr r0, =(BF_CHIP_FLASH_ORIGIN + BF_CHIP_FLASH_BOOT2_BYTES)  // the vector table: where the link places CODE
    ldr r1, =0xe000ed08          // PPB_BASE + M0PLUS_VTOR_OFFSET
    str r0, [r1]
    ldmia r0, {r0, r1}
    msr msp, r0
    bx r1

    .ltorg
