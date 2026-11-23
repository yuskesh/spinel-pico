# Board support and USB

## Board support (`lib/pico`)

Drivers for the rest of the RP2040, written against the same register bus as the PIO runtime. Names follow pico-sdk without the library prefix (`gpio_put` → `gpio.put`, `uart_init` → `uart(1).init`). Every driver keeps no state of its own: frequencies, directions and so on are read back from the registers each time.

```ruby
require_relative "lib/pico"

pico = Pico.rp2040                      # Board: MMIOBus + the RP2040 chip table
g = pico.gpio
g.init(25)
g.set_dir(25, true)
pico.clocks.set_sys_clock_khz(125_000)  # clk_sys from the PLL; clk_peri stays on the 12 MHz crystal
t = pico.timer
5.times do
  g.xor_mask(1 << 25)
  t.busy_wait_ms(100)
end
u = pico.uart(1)
g.set_function(4, :uart)                # GPIO 4 = UART1 TX
u.init(115_200)
u.puts("hello")
```

| File | Class | Contents |
|---|---|---|
| `lib/pico/chip.rb` | `Pico::Chip`, `Pico::RP2040` | port data: base addresses, reset bits, GPIO function numbers, SIO offsets |
| `lib/pico/mmio.rb` | `Pico::MMIOBus` | register bus on the device (Spinel FFI): `read32`, `write32`, `write32_hl`, `set_bits`, `clear_bits`, `xor_bits`, `write_masked` |
| `lib/pico/board.rb` | `Pico::Board` | `resets`, `gpio`, `clocks`, `timer`, `uart(n)`, `pwm`, `adc`, `spi(n)`, `i2c(n)`, `dma`, `pio(n)`; `flash` is added by `lib/pico.rb` |
| `lib/pico/resets.rb` | `Pico::Resets` | `reset_block`, `unreset_block`, `unreset_block_wait`, `reset_unreset_block_wait`, `in_reset?` (blocks as symbols: `[:pio0, :uart1]`) |
| `lib/pico/gpio.rb` | `Pico::GPIO` | `init`, `deinit`, `set_function` (`:sio`, `:uart`, `:pio0`, ...), `get_function`, `set_dir`, `put`, `get`, `get_all`, `set_mask` / `clr_mask` / `xor_mask` / `put_masked`, `pull_up` / `pull_down` / `disable_pulls` / `set_pulls`, `set_drive_strength`, `set_slew_rate`, `set_input_enabled`, `set_input_hysteresis_enabled`, `set_outover` / `set_oeover` / `set_inover` / `set_irqover`, `set_irq_enabled` (`IRQ_LEVEL_LOW`, `IRQ_LEVEL_HIGH`, `IRQ_EDGE_FALL`, `IRQ_EDGE_RISE`), `acknowledge_irq`, `get_irq_event_mask`, `get_raw_irq_event_mask` |
| `lib/pico/clocks.rb` | `Pico::Clocks` | `get_hz(:ref / :sys / :peri / :pll_sys ...)`, `frequency_count_khz`, `check_sys_clock_khz`, `set_sys_clock_khz`, `set_sys_clock_pll`, `set_sys_clock_from_ref`, `set_peri_source`, `pll_init`, `pll_deinit` |
| `lib/pico/timer.rb` | `Pico::Timer` | `time_us_32`, `time_us_31`, `us_since`, `busy_wait_us_32`, `busy_wait_ms`, `start_tick`, `alarm_set_target`, `alarm_set_in_us`, `alarm_cancel`, `alarm_is_armed?`, `alarm_fired?`, `alarm_acknowledge`, `alarm_set_irq_enabled` |
| `lib/pico/irq.rb` | `Pico::IRQ` | `set_enabled`, `is_enabled?`, `fired?`, `acknowledge`, `count`, `wait_for_interrupt`, `wait(n, timer, timeout_us)`, `set_pending`, `clear_pending`, `is_pending?`, `set_priority`, `get_priority`, `line_on?`; numbers from `chip.irq(:timer_irq_0)` and so on (device only) |
| `lib/pico/uart.rb` | `Pico::UART` | `init`, `deinit`, `set_baudrate`, `set_format`, `set_fifo_enabled`, `putc_raw`, `write`, `puts`, `getc`, `getc_timeout`, `is_readable?`, `is_writable?`, `tx_wait_blocking`, `set_loopback`, `drain_rx` |
| `lib/pico/pwm.rb` | `Pico::PWM` | `gpio_to_slice_num`, `gpio_to_channel`, `init`, `set_wrap`, `set_chan_level`, `set_both_levels`, `set_gpio_level`, `set_clkdiv_int_frac`, `set_phase_correct`, `set_output_polarity`, `set_clkdiv_mode`, `set_enabled`, `set_mask_enabled`, `get_counter`, `set_counter`, `get_irq_status_mask`, `clear_irq`, `set_irq_enabled` |
| `lib/pico/adc.rb` | `Pico::ADC` | `init`, `gpio_init`, `select_input`, `get_selected_input`, `set_temp_sensor_enabled`, `set_round_robin`, `read`; `ADC.to_mv`, `ADC.temp_c10` |
| `lib/pico/spi.rb` | `Pico::SPI` | `init`, `deinit`, `set_baudrate`, `get_baudrate`, `set_format`, `set_slave`, `set_loopback`, `write_read_blocking`, `write_blocking`, `read_blocking`, `is_writable?`, `is_readable?`, `is_busy?` |
| `lib/pico/dma.rb` | `Pico::DMA`, `DMA::Channel`, `DMA::ChannelConfig` | `claim_unused_channel`, `channel_claim`, `channel_unclaim`, `channel(n)`, `get_default_config`, `start_channel_mask`, `timer_set_fraction`, `get_timer_dreq`, `sniffer_enable` (`:crc32`, `:crc32_bitrev`, `:crc16`, `:crc16_bitrev`, `:xor`, `:sum`), `sniffer_get_data_accumulator`, `irqn_get_status`, `intr`; channel: `configure`, `set_config`, `set_read_addr`, `set_write_addr`, `set_trans_count`, `start`, `is_busy?`, `wait_for_finish_blocking`, `abort`, `get_trans_count`, `get_read_addr`, `get_write_addr`, `set_irq0_enabled`, `get_irq0_status`, `acknowledge_irq0` (and irq1); config: `set_read_increment`, `set_write_increment`, `set_dreq`, `set_chain_to`, `set_transfer_data_size` (1, 2, 4), `set_ring`, `set_bswap`, `set_irq_quiet`, `set_high_priority`, `set_enable`, `set_sniff_enable` |
| `lib/pico/ram_buffer.rb` | `Pico::RAMBuffer` | `new(size, align)`, `addr`, `size`, `read8` / `write8`, `read16` / `write16`, `read32` / `write32`, `words(n)`, `free` (device only) |
| `lib/pico/i2c.rb` | `Pico::I2C` | `init`, `deinit`, `set_baudrate`, `set_slave_mode`, `write_blocking`, `read_blocking`, `write_timeout_us`, `read_timeout_us`, `last_abort_reason`; `ERROR_GENERIC`, `ERROR_TIMEOUT` |
| `lib/pico/flash.rb` | `Pico::Flash` | `read_u32`, `read`, `range_erase`, `range_program`, `image_end_offset`, `first_free_offset` |
| `lib/pico/flash_rom.rb` | `Pico::FlashROM` | the part that runs from RAM with XIP off (Spinel FFI) |
| `lib/pico/bootrom.rb` | `Pico::BootROM` | `reset_usb_boot` (also `Pico.reset_usb_boot`) |

Host code (tests, tools) requires the files it needs; programs for the device require `lib/pico.rb`, which adds the FFI parts.

**Notes**
- Verified on RP2040 only. `Pico.rp2350` (RP2350A, the Pico 2) uses the same drivers with `Pico::Chip.rp2350`: base addresses, reset bits, DREQs, interrupt numbers, GPIO functions, SIO offsets, and the registers and fields that moved (GPIO overrides and interrupt registers, the TIMER's tick in the TICKS block and its INTR / INTE, the CLOCKS registers after clk_peri, the DMA CTRL fields and the registers after the channels, PWM's 12 slices, ADC's wider AINSEL, the third PIO block and its interrupt registers). `tools/regs_check.sh` (run by `test/check.sh`) turns every number the drivers use into a `_Static_assert` against pico-sdk 2.3.1's `hardware_regs` headers: 414 values for RP2040 and 461 for RP2350 match. `test/board_regs.rb` and `test/runtime_regs.rb` check that the drivers write the RP2350 registers. **Nothing has run on an RP2350**: bare-full has no RP2350 chip family, so a program cannot be built for it yet. `Pico::IRQ` (the Cortex-M0+ vector table and NVIC) and `Pico::Flash` (the RP2040 ROM routines) are RP2040 only; GPIO 0-29 only (no RP2350B).
- 32-bit Integers: addresses with bit 31 set are written as negative numbers (`sio_base = -0x3000_0000` is 0xd0000000). GPIO masks cover GPIO 0-30. There is no `time_us_64`; `time_us_31` and `us_since` handle the wrap of the low 31 bits (one wait must be under about 35 minutes).
- Clocks: frequencies are worked out from the registers. The ring oscillator and the GPIN inputs have no known frequency, so clocks running from them read as 0 (measure them with `frequency_count_khz`). clk_sys is limited to 133 MHz (the datasheet maximum at the default core voltage). Changing clk_sys first moves clk_peri from clk_sys to the crystal, so the UARTs keep their baud rates.
- `clock_gettime` (and so `Process.clock_gettime` and `sleep`) reads the TIMER, so it stays right at any clk_sys.
- At start-up the chip family's code (`port/chip/rp2040/chip.c`) resets the blocks as pico-sdk's runtime does and releases all but ADC, RTC and USBCTRL (USBCTRL is left as it was; the ADC and RTC clocks are not started). Writes to a block still in reset are silently ignored. Every driver's `init` (or constructor, for the timer and DMA) releases its block if it is in reset.
- ADC: clk_adc must be 48 MHz, so `ADC#init` starts the USB PLL (1440 MHz / 6 / 5) and runs clk_adc from it. On an RP2040 Pico the ADC registers read 0 and ignore writes while clk_sys (12 MHz) is slower than clk_adc; at clk_sys 48 and 125 MHz they work. The datasheet does not say this (erratum RP2040-E16 is the same kind of problem for USB), so `ADC#init` raises unless clk_sys is at least 48 MHz.
- Speed at clk_sys 12 MHz: bare-full's boot2 reads the flash with plain 03h commands at clk_sys / 4, so each XIP cache miss costs tens of microseconds. One register read through a driver method took about 190 us in a large program. Raise clk_sys (or add a faster second stage to the chip family, `port/chip/rp2040/boot2`) when the software around a peripheral matters.
- Interrupts: `IRQ.set_enabled` first copies bare-full's vector table into RAM with one C handler for all 32 peripheral interrupts and points VTOR at it. The handler counts the interrupt, records it and switches its line off in the NVIC (so a source that stays asserted cannot keep the core in the handler); Ruby sees it with `IRQ.fired?`, `IRQ.wait` or by sleeping in `IRQ.wait_for_interrupt`, clears the peripheral's flag, then calls `IRQ.acknowledge`, which switches the line back on. Ruby code cannot run inside the interrupt, since it may allocate. bare-full runs no periodic interrupt, so WFI sleeps until an enabled interrupt comes.
- At clk_sys 12 MHz a call such as `alarm_set_in_us` takes about 1 ms, so a short delay can already be past when the alarm is written (it then fires only after the 32-bit time wraps, about 72 minutes). Read the time first and use `alarm_set_target` for short delays.
- DMA works on plain addresses. For memory, `Pico::RAMBuffer` allocates a block with C `aligned_alloc` (never moved or collected; call `free`); peripherals give their data register (`SPI#dr_addr`, `UART#dr_addr`) and the DREQ comes from `chip.dreq(:spi0_tx)` and so on. `SPI#init` and `UART#init` enable the peripherals' DMA requests as pico-sdk does.
- DMA on an RP2040 Pico: after `abort`, TRANS_COUNT reads 0, so take the progress from `get_write_addr`. The sniffer's `:xor` mode is a reduction to one bit (1 if the data hold an odd number of 1 bits), not a word XOR. The start-up code resets the DMA, so INTR starts at 0 in every program.
- I2C follows pico-sdk, including its waits: `write_blocking` and `read_blocking` have no time limit, and a write that is refused waits for the STOP condition on the bus. If the bus cannot show one (SDA or SCL stuck), they never return; use `write_timeout_us` / `read_timeout_us` where that can happen.
- The timer: `Pico::Timer.new` releases the TIMER block if it is in reset and makes sure the watchdog tick runs at clk_ref / 1 MHz (the start-up code already does both, for `clock_gettime`). The start-up code resets the TIMER, so the time starts from 0 in every program.
- UART0 is the bare-full console. `uart(0).init` waits for the console to finish sending before it resets the block. An RX not routed to a pin sees a constant low line, which the UART receives as break characters; `drain_rx` drops them.
- Flash: erase and program use the boot ROM functions with interrupts masked, from a function placed in a `.data.*` section (bare-full's linker script copies `.data` to RAM). It calls only the ROM and a RAM copy of boot2, which puts the flash interface back into XIP mode afterwards. Offsets below `first_free_offset` (the end of the running program, rounded up to a sector) are refused.

**Tools**

```sh
sh tools/pico.sh build app.rb app.elf      # bare-full build for rp2040-pico
sh tools/pico.sh flash app.elf             # write over SWD (Debugprobe), verify, reset
sh tools/pico.sh run app.rb [timeout_s]    # build + flash + print the console until EXIT
# the build leaves app.elf.bin and app.elf.uf2 (for the BOOTSEL drive) beside app.elf
```

`Pico::Flash` reads the end of the program's image from the link script's `__image_end` (the port contract's `image` capability in spinel-modular), which bare-full's link scripts define.

The UF2 comes from the bare-full build (spinel-modular; the RP2040 chip family declares the format and its family ID): every loadable segment at its load address (`.data` goes where the startup code copies it from), 256 bytes per block, and a segment outside the flash stops the build before any image is written. A UF2 from the build, decoded by an independent script (1087 blocks, checked for magic numbers, block numbers, the RP2040 family ID and 256-byte payloads) and written to flash over SWD, in place of the ROM's USB drive, boots and runs to `BAREFULL EXIT 0`. Copying a UF2 to a real BOOTSEL drive has not been tried: `Pico.reset_usb_boot` does put the chip into BOOTSEL mode (the core runs the USB boot code), but the Pico used for these checks has no host on its own USB port.

**Checks**
- `test/board_regs.rb` runs every driver against a fake bus and checks the register values against hand-computed ones (datasheet bit positions). A small model answers the status registers (clock switch done, PLL lock, frequency counter). Flash is checked with a stand-in for the ROM part. CRuby and Spinel give the same output; `test/check.sh` runs it.
- `examples/rp2040/board_selftest.rb` runs on the device (`sh tools/rp2040_selftest.sh board`) and prints PASS / FAIL per check. It needs nothing wired: it uses the LED pin GPIO 25 and the console, and GPIO 4 and 5 for I2C only after checking that they follow both the pull-up and the pull-down (nothing attached; otherwise the I2C checks are skipped). Result on a Raspberry Pi Pico (96 checks, all passed, EXIT 0):
  - GPIO: GPIO 25 driven high/low reads back through SIO; input with pull-down reads low; pad settings read back.
  - Timer: `busy_wait_us_32(1000)` is never short: 1302 us at clk_sys 12 MHz and 1024 us at 125 MHz. At 12 MHz the code runs from flash read at 3 MHz, and how long one time round the loop takes depends on where the code lands: the same check gave 1047 us in a build with an older Spinel, and a small program gives 1033 us.
  - Clocks: at 125, 48 and 133 MHz the frequency counter measures clk_sys and pll_sys at the requested value (±1 kHz) and clk_peri at 12 MHz. SysTick core cycles per timer microsecond (two spans, subtracted; median of three) give 11996-12000, 124999-125001, 47996-48000 and 132998-133000 kHz.
  - UART: UART1 in internal loopback returns `[0x55, 0x00, 0xFF, 0x0A, 0x41]` at clk_sys 12 MHz and a byte at 125 MHz (115107 baud, the same divisor as bare-full's console). UART0 re-initialised by the driver keeps the console working.
  - PWM on GPIO 25 (wrap 99, level 30, divider 8), measured by two PIO state machines: High 240 cycles and Low 560 cycles exactly (counts 120 and 279); the wrap flag sets again after clearing.
  - PIO on SM 3 running a slow two-instruction loop: IRQ flags set by `interrupt_force` and by an exec'd `irq wait 2` (which stops the SM until `interrupt_clear(2)`) show in `irq_flags`, `intr` and `ints(0)` (enabled there) but not `ints(1)`; an exec'd `wait 1 irq 6` stalls with EXEC_STALLED until the CPU sets flag 6; a fifth word into the TX FIFO sets the overflow flag and `drain_tx_fifo` empties it; reading the empty RX FIFO sets the underflow flag; `set_pins` / `set_pins_with_mask` drive GPIO 25 high and low.
  - ADC at clk_sys 125 MHz: clk_adc measured at 48000 kHz; the temperature sensor read 25.1 C; VSYS on GPIO 29 read 4470 mV; init at clk_sys 12 MHz is refused.
  - SPI0 in internal loopback: 8-bit frames and 16-bit mode-3 frames come back unchanged; 32 bytes take 25630 us longer at 5 kHz than at 10 kHz (256 bit times x 100 us = 25600 us).
  - DMA (clk_sys 12 MHz): 256 words copied memory to memory with the completion flag in INTS0; sniffer sum and parity match; 3 bytes to an odd address; `bswap`; a read ring of 4 words over 12 transfers; a chain from one channel to another; paced by DMA timer 0 at 10 kHz, 1000 transfers take 89960-90009 us longer than 100 (90000; the shortest of 3 measurements each, three runs); `abort` stops a 1 kHz transfer after 22 of 1000 with no completion flag; 64 bytes through SPI0 loopback and 16 bytes through UART1 loopback, each with a TX and an RX channel paced by the peripheral's DREQs.
  - Interrupts (clk_sys 12 MHz): a timer alarm wakes WFI after 3007 us (3000); `IRQ.wait` sees the alarm and times out when none comes; a source left set fires again on `acknowledge`, not once cleared; `set_pending` fires by software; priority keeps the top 2 bits; DMA completion on DMA_IRQ_0 wakes WFI once; GPIO 25 rising and falling edges reach IO_IRQ_BANK0, none once disabled.
  - I2C0 on GPIO 4 / 5 with the on-chip pull-ups and nothing attached: writes and reads to 0x3c return `ERROR_GENERIC` with abort reason 0x1 (address not acknowledged); the bus time at 10 kHz is 1100 us (11 periods: START, 9 clocks, STOP), twice that at 20 kHz; with SCL forced low by an input override (the pin is not driven), `write_timeout_us(..., 5000)` returns `ERROR_TIMEOUT` after 5294 us and the controller works again after `init`.
  - Flash: the vector table reads back through XIP; erase / program two pages / read back / erase again in the last sector, at clk_sys 12 MHz and 125 MHz; erasing sector 0 is refused.

## USB device (`lib/pico/usb_device.rb`, `lib/pico/usb_cdc.rb`) — not yet run against a host

`Pico::USBDevice` drives the USB device controller at the level of pico-examples' `usb/device/dev_lowlevel`:
- The control endpoint with the standard requests: GET_DESCRIPTOR (device, configuration, strings), SET_ADDRESS, SET / GET_CONFIGURATION, GET_STATUS, SET / CLEAR_FEATURE (endpoint halt, remote wakeup), GET / SET_INTERFACE. Anything else is stalled.
- Class and vendor requests go to `class_request_in` / `class_request_out`, which a class built on it overrides; a request with an OUT data stage (up to 64 bytes) is handled when its data has arrived.
- The bulk / interrupt endpoints found in the configuration descriptor (up to 64 bytes per packet, one packet per `read` / `write`).
- Suspend and resume are followed (`suspended?`, `suspends`), and `remote_wakeup` signals resume if the host allowed it.

```ruby
usb = pico.usb_device(Pico::USBDevice.vendor_device, Pico::USBDevice.vendor_config, ["Raspberry Pi", "Pico Test Device"])
usb.init(pico.clocks, pico.resets)      # clk_usb at 48 MHz from the USB PLL, controller on, pull-up on
loop do
  usb.task                              # setup packets, finished buffers, bus resets, suspend / resume
  usb.write(2, usb.read(1)) if usb.received?(1) && !usb.write_busy?(2)
end
```

`Pico::USBCDC` is a CDC ACM virtual serial port on top of it (`/dev/ttyACM*` on Linux): the interface association, communications and data interfaces, SET / GET_LINE_CODING, SET_CONTROL_LINE_STATE (`dtr?`, `rts?`, `baud`), `print(str)` (queued, sent a packet at a time, a zero-length packet after a full last one, at most 1024 bytes kept while nobody reads) and `read_all`.

```ruby
cdc = pico.usb_cdc(0x2e8a, 0x000a, ["Raspberry Pi", "Pico", "0001"])
cdc.init(pico.clocks, pico.resets)
loop do
  cdc.task
  cdc.print("got #{cdc.read_all.size} bytes\r\n") if cdc.available > 0
end
```

- `task` can be polled, or woken by the controller's interrupt: `set_irq_enabled(true)`, `Pico::IRQ.set_enabled(chip.irq(:usbctrl_irq), true)`, then `Pico::IRQ.wait(irq, timer, timeout)`, `task`, `Pico::IRQ.acknowledge(irq)` (`examples/rp2040/usb_cdc_echo.rb`). Ruby still does not run inside the interrupt. One idle `task` takes about 80 us at clk_sys 12 MHz and the first GET_DESCRIPTOR took 25 ms there, so the examples run clk_sys at 48 MHz.
- `vendor_device` / `vendor_config` are dev_lowlevel's descriptors (vendor interface, EP1 OUT and EP2 IN, bulk), so pico-examples' `dev_lowlevel_loopback.py` is the host side for `examples/rp2040/usb_echo.rb`.
- What has been checked:
  - Every register offset and bit against pico-sdk's headers (`tools/regs_check.sh`).
  - The sequences against a model of the controller and a host (`test/usb_model.rb`, 88 checks, same output from Spinel and CRuby): bus reset, descriptors whole and cut to wLength, a descriptor longer than one packet and one that needs a closing zero-length packet, SET_ADDRESS taking effect after its status stage, stalls for unknown requests, the echo with DATA0 / DATA1 alternating, a repeated packet dropped, endpoint halt set and cleared, remote wakeup, suspend and resume, the CDC descriptors (lengths add up, 2 interfaces, 3 endpoints), SET_LINE_CODING through its OUT data stage, DTR, 150 bytes as packets of 64 / 64 / 22, 64 bytes followed by a zero-length packet. The model is written from the datasheet and the USB specifications by the same hand as the driver: it checks the logic, not the hardware.
  - On a Pico (no host attached): registers, endpoint control words and bytes in the dual-port RAM read back as written; a GET_DESCRIPTOR setup packet placed in the RAM by hand makes the driver load EP0 with the descriptor (buffer control 0xa412); a SET_LINE_CODING placed the same way arms EP0 OUT (0x2407), takes the 7 bytes and answers the status stage; the idle bus makes the controller report suspend through interrupt 5, `task` clears the source and no further interrupt comes; a forced SETUP_REQ fires the interrupt.
- What has not: **no host has talked to it.** The Pico used here has nothing on its own USB port. Enumeration, the 2 ms a host allows after SET_ADDRESS, real transfers and a host's serial driver binding to the CDC interface are untested. The same is true of copying a UF2 to the BOOTSEL drive.
