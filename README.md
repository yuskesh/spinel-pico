# spinel-pico

The Raspberry Pi Pico (RP2040) from [Spinel](https://github.com/matz/spinel), the Ruby ahead-of-time compiler:
Ruby programs, with the runtime and its collector, on the bare chip. No SDK and no RTOS.

- **PIO in Ruby.** Write a PIO program as durations (`sleep 2.us`) or one instruction at a time; get the 16-bit
  instruction words, a pico-sdk C header, and a program object to load on the device.
- **Drivers** with pico-sdk's names: GPIO, clocks and PLLs, timer and alarms, interrupts, UART, SPI, I2C, PWM, ADC,
  DMA, flash, USB device.
- **The RP2040 chip family** for [spinel-modular](https://github.com/yuskesh/spinel-modular)'s bare-metal build:
  start-up, clocks, console, the second-stage boot and the Pico's board file (`port/`).

## A program

```ruby
require_relative "lib/pico"

pico = Pico.rp2040
g = pico.gpio
g.init(25)                               # the Pico's LED
g.set_dir(25, true)
t = pico.timer
10.times do
  g.xor_mask(1 << 25)
  t.busy_wait_ms(200)
end
puts "done"                              # the console is UART0 (GP0 / GP1, 115200 8N1)
```

```sh
sh tools/pico.sh build blink.rb blink.elf    # also writes blink.elf.bin and blink.elf.uf2
sh tools/pico.sh flash blink.elf             # over SWD, through a Debug Probe
sh tools/pico.sh run blink.rb                # build, flash, and print the console until the program ends
```

`blink.elf.uf2` is the image for the Pico's BOOTSEL drive (see what has been checked, below). `BOARD=<name>` builds for another board file.

## Setting up

You need a [spinel-modular](https://github.com/yuskesh/spinel-modular) checkout with its Spinel built, and the
Cortex-M0+ toolchain its `tools/bare-full/README.md` describes.

| Variable | Meaning |
|---|---|
| `SPINEL_MODULAR` | the spinel-modular checkout |
| `BF_RUNTIME` | `libspinel_rt_bare.a`, from `$SPINEL_MODULAR/tools/bare-full/spinel-bare-full runtime --cpu m0plus DIR` |
| `LLVM_PREFIX`, `BAREMETAL_PICOLIBC`, `BAREMETAL_BUILTINS` | LLVM, and picolibc and compiler-rt's builtins for Cortex-M0+ |
| `OPENOCD_PREFIX` | for `flash` and `run`: the directory with `bin/openocd` and `share/openocd/scripts` |

`Integer` is 32 bits on the device. There are no files, processes, threads or `Fiber`.

## PIO

A program written as time. The builder chooses the instructions, and `report` shows the cycles of each segment:

```ruby
require_relative "lib/pico/pio"

class WS2812 < Pico::PIO::TimedProgram
  clock 20_000_000                         # 50 ns per cycle
  output :data
  def main
    loop do
      inbox.each_bit(24) do |bit|          # 24 bits at a time from the TX FIFO, MSB first
        data.on
        sleep bit.pick(800.ns, 400.ns)     # 800 ns for a 1, 400 ns for a 0
        data.off
        sleep bit.pick(450.ns, 850.ns)
      end
    end
  end
end

prog = WS2812.assemble
prog.report                                # cycles per segment
puts prog.to_c                             # a pico-sdk header, with <name>_program_init
puts prog.assembled.to_ruby("WS2812_PROG") # a Pico::PIO::Program for the device
```

The same thing one instruction at a time, with pioasm's names:

```ruby
require_relative "lib/pico/pio/asm"

code = Pico::PIO.asm(:ws2812, side_set: 1) do
  wrap_target
  label :bitloop
  out :x, 1, side: 0, delay: 3
  jmp :not_x, :do_zero, side: 1, delay: 2
  jmp :bitloop, side: 1, delay: 2
  label :do_zero
  nop side: 0, delay: 2
  wrap
end
puts code.to_c
```

On the device (programs are assembled on the host, because the timing arithmetic needs more than 32 bits):

```ruby
pico.clocks.set_sys_clock_khz(120_000)                        # the program wants 20 MHz: clk_sys / 6
pio = pico.pio(0)
pio.reset!
offset = pio.add_program(WS2812_PROG)
sm = pio.sm(0)
WS2812_PROG.init_sm(sm, offset, 25, -1, -1, -1, 120_000_000)  # the data pin (a SET pin) is GPIO 25
sm.set_enabled(true)
sm.put_hl(0x00ff, 0x0000)                                     # green; bits 31-8 are the 24 bits sent
```

The time layer also has inputs (`wait_high`, `sample`, `pick` and `branch` on a pin), side-set and OUT pins,
`repeat`, IRQ flags, and values from the CPU (`inbox.current`, `inbox.take`, `inbox.preset`). The instruction layer
covers every pioasm instruction and directive, including the RP2350's. [docs/pio.md](docs/pio.md) is the
reference.

## Drivers

`Pico.rp2040` gives the board; each driver follows pico-sdk's function names without the prefix
(`gpio_put` is `gpio.put`, `uart_init` is `uart(1).init`).

| | |
|---|---|
| `pico.gpio`, `pico.resets`, `pico.clocks` | pins and their interrupts, block resets, clk_sys from the PLL, the frequency counter |
| `pico.timer`, `Pico::IRQ` | microsecond time, alarms, waiting for an interrupt |
| `pico.uart(n)`, `pico.spi(n)`, `pico.i2c(n)` | serial buses |
| `pico.pwm`, `pico.adc`, `pico.dma` | PWM slices, the ADC and temperature sensor, DMA channels with pacing and chaining |
| `pico.flash`, `Pico.reset_usb_boot` | erase and program the flash beyond the image; reboot into BOOTSEL |
| `pico.pio(n)` | PIO blocks and state machines |
| `pico.usb_device(...)`, `pico.usb_cdc(...)` | a USB device: control requests and bulk endpoints; a CDC serial port |

[docs/board.md](docs/board.md) lists every method and the things to know about each driver.

## Another RP2040 board

A board is a file of values, not code. Copy `port/board/rp2040-pico.yaml`, change the crystal, the flash size and
the console's pins, and build with `BOARD=<its name>` (spinel-modular's `docs/platform/board-file.md` describes
the file). The chip family's code in `port/chip/rp2040/` is shared by every RP2040 board.

Not there yet: a console on UART1, a longer crystal start-up delay (some boards need one), and a second stage
faster than the generic `03h` read.

## What has been checked

- On a Raspberry Pi Pico, through a Debug Probe: `sh tools/rp2040_selftest.sh all` runs three self-tests (111
  checks) of the PIO layers and the drivers, with nothing wired to the board.
- On the host: `sh test/check.sh` compares the assembler with pioasm (pico-examples' programs and this
  repository's own), runs the time layer's programs on a simulator, compares CRuby's output with Spinel's, checks
  the register values the drivers write, and checks every register number against pico-sdk's headers.
- **Not checked on hardware:** USB with a host (enumeration and transfers were checked against a model only),
  copying a UF2 to the BOOTSEL drive, and the RP2350 (`Pico.rp2350` has the chip's register table, checked
  against pico-sdk's headers; nothing can be built for it yet).

[docs/checks.md](docs/checks.md) has the commands and the measurements;
[docs/spinel-notes.md](docs/spinel-notes.md) the things about Spinel that shaped this code.

## Licence

Apache-2.0 WITH LLVM-exception: see [LICENSE](LICENSE) and [NOTICE](NOTICE). The RP2040's second-stage boot is
derived from pico-sdk (BSD-3-Clause): [THIRD_PARTY.md](THIRD_PARTY.md).
