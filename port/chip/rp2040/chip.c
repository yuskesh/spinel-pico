/* port/chip/rp2040: the rp2040 chip family's console and clock, for core 0
 * (a Cortex-M0+) of the RP2040, with no RTOS and no SDK. The board file gives
 * the values: the crystal, which UART, its two pins and the baud rate. What
 * follows describes the Raspberry Pi Pico (a 12 MHz crystal), the one board
 * of this family so far.
 *
 * Every register value is from pico-sdk 2.3.1's
 * src/rp2040/hardware_regs/include/hardware/regs (addressmap.h, xosc.h,
 * clocks.h, resets.h, io_bank0.h, uart.h, timer.h, watchdog.h); nothing of the
 * SDK is compiled.
 *
 * Clock: after the boot ROM the system clock runs from the ring oscillator,
 * whose rate is not fixed. The console needs a known rate, so the 12 MHz
 * crystal oscillator (XOSC) is started and clk_ref switched to it; clk_sys
 * stays on clk_ref, and clk_peri (the UART's clock) is enabled from clk_sys.
 * Everything runs at 12 MHz, the flash at 3 MHz (boot2's divider of 4).
 *
 * Console: UART0 on GP0 (TX) and GP1 (RX), 115200 8N1. 12 MHz / (16 x 115200)
 * = 6.51: IBRD 6, FBRD round(0.51 x 64) = 33, about 115,108 baud (-0.08%).
 * The Pico's debug probe reads it through its UART bridge.
 *
 * Core 1 is left as the boot ROM leaves it, asleep. Only core 0 runs the
 * program, which atomic-v6m.c relies on.
 */
#include <stdint.h>

#include "bare.h"

#define REG(a) (*(volatile uint32_t *)(a))
#define SET(a) REG((a) + 0x2000u) /* the atomic set alias */
#define CLR(a) REG((a) + 0x3000u) /* the atomic clear alias */

#define XOSC 0x40024000u
#define XOSC_CTRL REG(XOSC + 0x00u)
#define XOSC_STATUS REG(XOSC + 0x04u)
#define XOSC_STARTUP REG(XOSC + 0x0cu)
#define XOSC_STABLE 0x80000000u
#if BF_BOARD_CLOCK_CRYSTAL_HZ < 1000000 || BF_BOARD_CLOCK_CRYSTAL_HZ > 15000000 || BF_BOARD_CLOCK_CRYSTAL_HZ % 1000000
#error "rp2040: clock.crystal_hz must be a whole number of MHz from 1 to 15"
#endif
#define XOSC_HZ ((uint32_t)BF_BOARD_CLOCK_CRYSTAL_HZ)
#define XOSC_RANGE_1_15MHZ 0xaa0u
#define XOSC_ENABLE (0xfabu << 12)

#define CLOCKS 0x40008000u
#define CLK_REF_CTRL REG(CLOCKS + 0x30u)
#define CLK_REF_DIV REG(CLOCKS + 0x34u)
#define CLK_REF_SELECTED REG(CLOCKS + 0x38u)
#define CLK_SYS_CTRL REG(CLOCKS + 0x3cu)
#define CLK_SYS_DIV REG(CLOCKS + 0x40u)
#define CLK_SYS_SELECTED REG(CLOCKS + 0x44u)
#define CLK_PERI_CTRL REG(CLOCKS + 0x48u)
#define CLK_REF_SRC_XOSC 2u
#define CLK_PERI_ENABLE 0x800u

#define RESETS 0x4000c000u
#define RESETS_RESET (RESETS + 0x0u)
#define RESETS_DONE REG(RESETS + 0x8u)
#define RESET_ALL 0x01ffffffu
#define RESET_ADC 0x1u
#define RESET_IO_QSPI 0x40u
#define RESET_PADS_QSPI 0x200u
#define RESET_PLL_SYS 0x1000u
#define RESET_PLL_USB 0x2000u
#define RESET_RTC 0x8000u
#define RESET_SPI0 0x10000u
#define RESET_SPI1 0x20000u
#define RESET_SYSCFG 0x40000u
#define RESET_UART0 0x400000u
#define RESET_UART1 0x800000u
#define RESET_USBCTRL 0x1000000u
/* never put into reset: the flash's pads and IO bank (the program runs
 * from it), the PLLs, USB and SYSCFG, as pico-sdk's runtime_init_early_resets */
#define RESET_KEEP (RESET_IO_QSPI | RESET_PADS_QSPI | RESET_PLL_SYS | RESET_PLL_USB | \
		    RESET_USBCTRL | RESET_SYSCFG)
/* clocked by clk_peri, which bf_clocks_init enables */
#define RESET_PERI (RESET_SPI0 | RESET_SPI1 | RESET_UART0 | RESET_UART1)
/* clocked by clk_adc, clk_rtc and clk_usb, which stay off */
#define RESET_UNCLOCKED (RESET_ADC | RESET_RTC | RESET_USBCTRL)

#define TIMER 0x40054000u
#define TIMER_TIMERAWH REG(TIMER + 0x24u)
#define TIMER_TIMERAWL REG(TIMER + 0x28u)

#define WATCHDOG 0x40058000u
#define WATCHDOG_TICK REG(WATCHDOG + 0x2cu)
#define WATCHDOG_TICK_ENABLE 0x200u

#define IO_BANK0 0x40014000u
#define GPIO_CTRL(n) REG(IO_BANK0 + 0x04u + 8u * (n))
#define FUNCSEL_UART 2u

/* console.uart -> the UART base. Only instances with a cited source are
 * listed. */
#if BF_BOARD_CONSOLE_UART == 0
#define UART0 0x40034000u
#else
#error "rp2040: console.uart has no entry in the instance table"
#endif
/* pico-sdk uart_set_baudrate: the divisor in 1/128ths, rounded; the UART runs
 * from clk_peri, which is the crystal here */
#define UART_BAUD_DIV (8u * XOSC_HZ / BF_BOARD_CONSOLE_BAUD + 1u)
#define UART_DR REG(UART0 + 0x00u)
#define UART_FR REG(UART0 + 0x18u)
#define UART_IBRD REG(UART0 + 0x24u)
#define UART_FBRD REG(UART0 + 0x28u)
#define UART_LCR_H REG(UART0 + 0x2cu)
#define UART_CR REG(UART0 + 0x30u)
#define UART_FR_TXFF 0x20u

const uint32_t bf_early_write[2] = {0u, 0u}; /* the SRAM needs nothing */

static uint32_t bf_clock_selected;

static void bf_clocks_init(void)
{
	/* (12 MHz / 1000 + 128) / 256: about 1 ms, the SDK's startup delay */
	XOSC_STARTUP = (XOSC_HZ / 1000u + 128u) / 256u;
	XOSC_CTRL = XOSC_RANGE_1_15MHZ;
	XOSC_CTRL = XOSC_RANGE_1_15MHZ | XOSC_ENABLE;
	while (!(XOSC_STATUS & XOSC_STABLE)) {
	}
	CLK_REF_DIV = 1u << 8;
	CLK_REF_CTRL = (CLK_REF_CTRL & ~3u) | CLK_REF_SRC_XOSC;
	while (CLK_REF_SELECTED != (1u << CLK_REF_SRC_XOSC)) {
	}
	CLK_SYS_DIV = 1u << 8;
	CLK_SYS_CTRL &= ~1u; /* clk_sys from clk_ref */
	while (CLK_SYS_SELECTED != 1u) {
	}
	CLK_PERI_CTRL = CLK_PERI_ENABLE; /* AUXSRC 0: clk_sys */
	bf_clock_selected = CLK_REF_SELECTED;
}

uint32_t bf_core_hz(void)
{
	return XOSC_HZ;
}

static void bf_unreset(uint32_t bits)
{
	CLR(RESETS_RESET) = bits;
	while ((RESETS_DONE & bits) != bits) {
	}
}

/* The clock: the TIMER's 64-bit microsecond count, which the watchdog's tick
 * generator drives from clk_ref (the 12 MHz XOSC), not from clk_sys, so a
 * program that changes clk_sys keeps the time. The start-up resets put the
 * count to 0; bf_timer_init only starts the tick. */
static void bf_timer_init(void)
{
	WATCHDOG_TICK = WATCHDOG_TICK_ENABLE | (XOSC_HZ / 1000000u); /* clk_ref cycles in 1 us */
}

uint64_t bf_board_us(void)
{
	uint32_t hi, lo, hi2;

	do { /* a carry between the two halves is read again */
		hi = TIMER_TIMERAWH;
		lo = TIMER_TIMERAWL;
		hi2 = TIMER_TIMERAWH;
	} while (hi != hi2);
	return ((uint64_t)hi << 32) | lo;
}

void bf_console_init(void)
{
	/* The resets of pico-sdk's runtime_init: every block but RESET_KEEP
	 * into reset; out of it, before the clocks, every block but those on
	 * clk_peri, clk_adc, clk_rtc and clk_usb (so DMA, PIO0/1, PWM, I2C0/1,
	 * TIMER, IO_BANK0, PADS_BANK0, BUSCTRL, JTAG, SYSINFO, TBMAN, and the
	 * PLLs, left as they were); after them, those on clk_peri. The SDK then
	 * releases the rest; here clk_adc, clk_rtc and clk_usb are not started,
	 * so ADC and RTC stay in reset, and USBCTRL, never put into it, stays as
	 * it was (out of reset after the boot ROM). */
	SET(RESETS_RESET) = RESET_ALL & ~RESET_KEEP;
	bf_unreset(RESET_ALL & ~(RESET_PERI | RESET_UNCLOCKED));
	bf_clocks_init();
	bf_unreset(RESET_PERI);
	GPIO_CTRL(BF_BOARD_CONSOLE_TX) = FUNCSEL_UART;
	GPIO_CTRL(BF_BOARD_CONSOLE_RX) = FUNCSEL_UART;
	UART_IBRD = UART_BAUD_DIV >> 7;
	UART_FBRD = (UART_BAUD_DIV & 0x7fu) >> 1;
	UART_LCR_H = (3u << 5) | 0x10u; /* 8 bits, FIFOs on; latches the divisor */
	UART_CR = 0x301u;               /* UARTEN, TXE, RXE */
	bf_timer_init();
}

void bf_putc(char c)
{
	while (UART_FR & UART_FR_TXFF) {
	}
	UART_DR = (uint32_t)(unsigned char)c;
}

void bf_board_report(void)
{
	bf_puts("BAREFULL\tCLOCK\t" BF_STR(BF_BOARD_CLOCK_CRYSTAL_HZ) "\tCLK_REF_SELECTED=");
	bf_putx(bf_clock_selected);
	bf_puts("\n");
}
