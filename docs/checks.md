# Checks and measurements

## Checking

```sh
SPINEL=../spinel-modular/vendor/spinel/spinel PIOASM=/path/to/pioasm sh test/check.sh
```

Use the Spinel that spinel-modular pins (`git -C ../spinel-modular submodule status vendor/spinel` shows the pin; a checkout whose `vendor/spinel` is shown as modified is on another commit), and a runtime built from the same Spinel (`spinel-bare-full runtime --cpu m0plus DIR`): the runtime must come from the same Spinel as the compiler.

`test/check.sh` checks three things:

1. The examples, `test/cases.rb`, and the other test scripts give the same output on CRuby and Spinel.
2. Comparison with pioasm (pico-sdk 2.3.1).
   - Time layer: instructions and wrap match `test/pioasm/*.pio` (10 programs, 6 of them using side-set, `wait`, `in` and `irq`).
   - Instruction layer: `tools/pio2rb.rb` converts each `.pio` into `Pico::PIO.asm` Ruby, runs it, and compares against pioasm `-o json`. Compared: instruction words, wrap, origin, pio_version, side-set settings, public labels and defines. Targets: `test/pioasm/extra/` (all instruction variants, side-set edge values, RP2350 instructions) and every `.pio` in pico-examples.
   - `test/asm_errors.rb`: 24 invalid programs; checks that both Ruby and pioasm reject them.
3. Periods when run in `tools/sim.py`.

It also runs `test/runtime_regs.rb` (see the runtime layer section) and `test/board_regs.rb` (see [Board support](board.md)).

Steps whose requirement among `SPINEL`, `PIOASM`, and `PICO_EXAMPLES` (a pico-examples checkout) is missing are skipped.

Results:
- pico-examples (commit 0d62f75): all 26 files / 36 programs matched.
- `extra`: all 6 programs matched.
- 24 invalid programs: Ruby rejected all of them. pioasm rejected all 23 that can be fed to it.

`tools/sim.py` is a simulator that models only the instructions the generator emits (`jmp y--`, `pull noblock`, `mov`, `set`). It stops on any other instruction.

## Measuring on hardware

`tools/measure_hw.py` measures on an RP2040 behind a Debugprobe (CMSIS-DAP). It uses OpenOCD and writes the PIO0 registers directly over SWD. It does not write flash. When done, it puts PIO0 into reset and restores the original firmware with `reset run`.

Method:
- SM0 runs the program under test at clkdiv 8.
- SM1 and SM2 count the pin's High and Low durations (resolution 1/4 cycle). Their RX FIFOs are joined to 8 entries, and 8 samples are read.
- The pin is GPIO25.

```sh
python3 tools/measure_hw.py "8080 a027 e001 a241 0084 e000 a041 0087" 0 7 "5"
#   args: instructions (hex)  wrap_target  wrap  values for the TX FIFO (comma-separated, 0x allowed)  [SM0 SHIFTCTRL (hex)]
```

`OPENOCD_PREFIX` sets the OpenOCD location (the directory containing `bin/openocd` and `share/openocd/scripts`). The default is the hosttools of Zephyr SDK 1.0.1.

Calibration:
- With 4 programs of known length, High matched the true value and Low read 0.25 short. The script adds 0.25 to Low.
- OpenOCD `reset halt` does not reset the PIO, so the script puts PIO0 into reset every time.

Results (in PIO cycles):

| Program | Expected | Hardware High / Low |
|---|---|---|
| Square, n=0 / 5 / 20 | n+5 / n+5 | 5/5, 10/10, 25/25 |
| Square, 5 then 10 | 10 → 15 | 10, 15, 15, 15 / 10, 15, 15, 15 |
| Square before length equalization, n=5 | n+3 / n+5 | 8 / 10 |
| Tick | 24 / 100 | 24 / 100 |
| Example with a sleep at the top of the loop | 2 / 3 | 2 / 3 |

WS2812 (`examples/ws2812.rb`, SHIFTCTRL autopull, threshold 24, MSB first = `30060000`):

| Word sent | Expected (bit 1 is 16/9, bit 0 is 8/17) | Hardware High / Low (first 8 bits) |
|---|---|---|
| `0xAACCF000` (1010 1010 …) | 16, 8, 16, 8 … / 9, 17, 9, 17 … | 16, 8, 16, 8, 16, 8, 16, 8 / 9, 17, 9, 17, 9, 17, 9, 17 |
| `0xCCAA0000` (1100 1100 …) | 16, 16, 8, 8 … / 9, 9, 17, 17 … | 16, 16, 8, 8, 16, 16, 8, 8 / 9, 9, 17, 17, 9, 9, 17, 17 |
| three 4-bit words `A`, `5`, `F` (crossing word boundaries) | 1010 \| 0101 | 16, 8, 16, 8, 8, 16, 8, 16 / 9, 17, 9, 17, 17, 9, 17, 9 |

Lengths did not change at word boundaries.

If only two words are sent, the FIFO runs empty after the 8th bit and the pin stays Low. This is by design. That Low never ends, so it cannot be counted, and the measuring SM's FIFO does not fill all 8 entries. Reading an empty entry returns the previous value, so the script prints a warning in this case.

What was verified is cycle counts. The actual PIO clock frequency in Hz was not measured.
