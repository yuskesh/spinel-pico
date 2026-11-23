# PIO: the instruction layer, the time layer and the runtime layer

## Layers

Everything lives under the `Pico` module: `Pico::PIO` for PIO (files under `lib/pico/pio`), and `Pico::GPIO`, `Pico::Clocks`, ... for the rest of the chip (`lib/pico/*.rb`). The only global addition is `Integer#us`, `#ns` and `#cycles` for the time layer.

- **Time layer** (`lib/pico/pio.rb`, `Pico::PIO::TimedProgram`): write durations such as `sleep 2.us`, and it builds the instruction sequence for you. Described below.
- **Instruction layer** (`lib/pico/pio/asm.rb`, `Pico::PIO.asm`): write one instruction at a time. Names follow pioasm and pico-sdk (`pio_instructions.h`).
- **Runtime layer** (`lib/pico/pio/program.rb`, `lib/pico/pio/runtime.rb`): loads programs and configures state machines on the microcontroller. See [Runtime layer (on the microcontroller)](pio.md#runtime-layer-on-the-microcontroller).
- **Board layer** (`lib/pico`): everything else on the chip, shared by the PIO runtime (chip table, register bus, resets, GPIO). See [Board support](board.md).

Both the time layer and the instruction layer produce the same artifact, `Pico::PIO::Assembled` (instruction words, wrap, side-set settings). From the time layer, get it with `#assembled`.

```ruby
require_relative "lib/pico/pio/asm"

code = Pico::PIO.asm(:ws2812, side_set: 1) do
  t1 = define(:T1, 3, public: true)        # .define public T1 3
  t2 = define(:T2, 3, public: true)
  t3 = define(:T3, 4, public: true)
  wrap_target
  label :bitloop
  out :x, 1, side: 0, delay: t3 - 1
  jmp :not_x, :do_zero, side: 1, delay: t1 - 1
  label :do_one
  jmp :bitloop, side: 1, delay: t2 - 1
  label :do_zero
  nop side: 0, delay: t2 - 1
  wrap
end
puts code.to_c      # same shape as pioasm's c-sdk output (with get_default_config)
```

**Mapping from pioasm**

| pioasm | `Pico::PIO.asm` |
|---|---|
| `.side_set 1 opt pindirs` | `Pico::PIO.asm(:name, side_set: 1, side_set_opt: true, side_set_pindirs: true)` |
| `.origin 0` / `.pio_version 1` | `origin: 0` / `pio_version: 1` |
| `.define public T1 3` | `t1 = define(:T1, 3, public: true)` (a plain Ruby variable also works) |
| `public entry:` / `.wrap_target` / `.wrap` | `label :entry, public: true` / `wrap_target` / `wrap` |
| `jmp x-- loop` / `jmp loop` | `jmp :x_dec, :loop` / `jmp :loop` (conditions use the `pio_encode_jmp_<condition>` names) |
| `wait 1 irq 2 rel` / `wait 1 jmppin + 3` | `wait 1, :irq, 2, rel: true` / `wait 1, :jmppin, 3` |
| `in pins, 8` | `in_ :pins, 8` (`in` is a Ruby reserved word) |
| `out x, 1 side 0 [3]` | `out :x, 1, side: 0, delay: 3` |
| `push iffull noblock` / `pull ifempty` | `push iffull: true, block: false` / `pull ifempty: true` |
| `mov x, ~osr` / `mov isr, ::isr` | `mov :x, :osr, op: :invert` / `mov :isr, :isr, op: :reverse` |
| `irq wait 0 rel` / `irq clear 4` | `irq :wait, 0, rel: true` / `irq :clear, 4` |
| `set pindirs, 1` / `nop` | `set :pindirs, 1` / `nop` |

**Errors it rejects** (the same ones pioasm rejects)
- More than 32 instructions.
- Delay above its limit. The limit drops with the number of side-set bits.
- Missing side value with a non-opt side-set.
- Side value does not fit in the side-set bits.
- Label missing or defined twice.
- Value, bit count, or index out of range.
- Destination or source not allowed for that instruction.
- RP2350 instructions used with `pio_version: 0`.

RP2350 (`pio_version: 1`) instructions, all matching pioasm (`test/pioasm/extra/v1*.pio`):
- `wait 1, :jmppin, n` and `mov :pindirs, :x`.
- `irq :set, 3, pio: :prev` / `pio: :next` and `wait 1, :irq, 3, pio: :prev`: the flag of the previous / next PIO block.
- `Pico::PIO.asm(:name, pio_version: 1, fifo: :txput)` (`.fifo`: `:txrx`, `:tx`, `:rx`, `:txput`, `:txget`, `:putget`), then `mov rxfifo(:y), :isr` / `mov :osr, rxfifo(2)`. The mode goes into the C header (`sm_config_set_fifo_join`) and the runtime's `Program` (the RP2350's `FJOIN_RX_PUT` / `FJOIN_RX_GET`).

State machine settings (pioasm's directives), written inside the block:
- `in_pins 32, :left, auto: true, threshold: 24` (`.in`), `out_pins 5, :right, threshold: 16` (`.out`), `set_pins 2` (`.set`), `mov_status :txfifo, 3` / `:rxfifo, n` / `:irq, n, pio: :next` (`.mov_status`), `clock_div 2.5` (`.clock_div`).
- They go into the C header's `get_default_config` in pioasm's order (the `sm_config_set_*` lines are compared with pioasm's for `test/pioasm/extra/*.pio`). All of them also reach the runtime's `Program` (`to_ruby`), whose `default_config` sets the shifts, `mov_status` (EXECCTRL `STATUS_SEL` / `STATUS_N`, at the chip's positions) and the clkdiv. On a Pico: with `mov_status :txfifo, 1` STATUS reads all ones while the TX FIFO is empty and 0 with a word in it, and `clock_div 2.5` gives CLKDIV 0x28000.

## Time layer: choose the waveform per bit

```ruby
class WS2812 < Pico::PIO::TimedProgram
  clock 20_000_000            # 50 ns per cycle
  output :data
  def main
    loop do
      inbox.each_bit(24) do |bit|          # 24 bits at a time, ignoring word boundaries (MSB first)
        data.on
        sleep bit.pick(800.ns, 400.ns)     # 800 ns if the bit is 1, 400 ns if 0
        data.off
        sleep bit.pick(450.ns, 850.ns)
      end
    end
  end
end
```

**Two ways to write it**
- `inbox.each_bit(n) { |bit| ... }`: streams bits without word boundaries. Uses autopull with threshold n. This must be the only statement in the `loop`. Each iteration shifts out its bit at the start of the iteration, so when it stalls on an empty FIFO, the pin stays at the last level of the previous iteration.
- `word = inbox.take; word.each_bit(n) { |bit| ... }`: does a `pull` per word. After the last bit of a word, the time for the next `inbox.take` is added (+1 cycle, longer while waiting for a word). `report` shows this too.
- Both accept `order: :lsb` to send LSB first.

**How it is assembled**
- At the first use of the bit in an iteration it emits `out y, 1`, and a `bit.pick` wait branches with `jmp !y`. The two paths are padded with delay and `nop` to the lengths you wrote.
- The bit count is checked with `jmp !osre` (has the number of bits shifted out of the OSR reached the threshold), so no counter register is used.
- The OSR settings go into the artifact's `out_shift_right`, `pull_threshold`, and `autopull`, and `get_default_config` in `to_c` emits `sm_config_set_out_shift`.

**Register roles**

| Register | Role |
|---|---|
| X | value received with `inbox.current` |
| Y | wait counter. Inside `each_bit`, the bit of the current iteration |
| OSR | word received with `inbox.take` |

**Errors it rejects**
- The instructions between already exceed a `bit.pick` wait.
- `bit.pick` used outside `each_bit`.
- `each_bit` written twice (an SM has only one OSR threshold).
- The bit is not used inside `each_bit`.
- Statements before or after `inbox.each_bit`.
- `inbox.current` and `inbox.take` used together.

**Verified**
- `examples/ws2812.rb` is 8 instructions. It matches the hand-written `test/pioasm/ws2812_timed.pio` run through pioasm.
- `test/bits_cases.rb` runs on `lib/pico/pio/sim.rb` (a Ruby simulator) and checks High/Low per bit. The per-word version for 47 bits and the boundary-free version for 15 bits matched the written lengths. The +1 at word boundaries also matched `report`.
- `test/bits_cases.rb` gives the same output on Spinel and CRuby.

## Time layer: allowed error (`tolerance` / `within:`)

Depending on the PIO clock, a written duration may not be a whole number of cycles. For example, one cycle at 12 MHz is 83.33… ns. So you can state how much error is acceptable.

```ruby
class WS2812 < Pico::PIO::TimedProgram
  clock 12_000_000
  tolerance 150.ns                         # tolerance from the WS2812 datasheet (±150ns)
  output :data
  def main
    loop do
      inbox.each_bit(24) do |bit|
        data.on
        sleep bit.pick(800.ns, 400.ns)
        data.off
        sleep bit.pick(450.ns, 850.ns)
      end
    end
  end
end
```

**Rules**
- A segment's length is the sum of its `sleep`s, rounded to the nearest cycle count.
- If the error exceeds the tolerance, it is rejected. Rounding to 0 cycles is also rejected.
- `sleep 700.ns, within: 50.ns` sets a tolerance for that segment only. If a segment has several, the narrowest wins. It takes precedence over `tolerance`.
- With neither, no error is allowed. A duration that is not a whole number of cycles is rejected, and the error message shows the nearest cycle count and how to write it.
- `report` and `to_c` print rounded segments as "written length → cycles = actual length (deviation, tolerance)". With `each_bit`, they also print the actual length of one bit.
- Durations written with `.cycles` are not rounded.

**Results per clock** (WS2812. Each bit is shown as 1 / 0. Hardware matched the simulator lengths.)

| PIO clock | Instructions | High (cycles) | Low (cycles) | 1 bit |
|---|---|---|---|---|
| 12 MHz | 8 | 10 / 5 (+33.3 / +16.7 ns) | 5 / 10 (−33.3 / −16.7 ns) | 1250 ns |
| 20 MHz | 8 | 16 / 8 (error 0) | 9 / 17 (error 0) | 1250 ns |
| 125 MHz | 10 | 100 / 50 (error 0) | 56 / 106 (−2 ns) | 1248 ns |

- On hardware, with `0xA5C30000` sent, High and Low of the first 8 bits (1010 0101) were measured.
- At 125 MHz the delay exceeds 31, so `nop`s are added, giving 10 instructions.
- The rejected cases are checked in `test/bits_cases.rb` (no tolerance, over tolerance, `within:` narrower, 0 cycles).

## Time layer: pins, inputs, repeat, the RX FIFO and IRQ flags

```ruby
class Sampler < Pico::PIO::TimedProgram
  clock 1_000_000
  input :din                       # IN pins in the order declared: din is the IN base, sclk the next pin
  input :sclk
  output :busy, side: true         # a side-set pin
  def main
    outbox.autopush(8)             # 8 bits per word, MSB first, pushed to the RX FIFO by themselves
    loop do
      busy.off                     # rides on the wait: the pin is Low while the SM stalls
      sclk.wait_high               # wait 1 pin 1
      busy.on                      # rides on the next instruction
      din.sample                   # in pins, 1
      sleep 2.us
      sclk.wait_low                # wait 0 pin 1
    end
  end
end
```

| Statement | Instruction | Notes |
|---|---|---|
| `output :led`, then `led.on` / `led.off` | `set pins, v` | up to 5 SET outputs, from the SET base in the order declared. Each `set pins` carries the other SET pins' levels; changes with no sleep between them share one `set pins` |
| `output :clk, side: true`, then `clk.on` / `clk.off` | side-set on another statement's instruction | up to 5 side-set outputs, from the side-set base in the order declared |
| `output :data, out: true, width: 8`, then `data.write(inbox.next(8))` | `out pins, 8` | n OUT pins at once from the received words, pulled by themselves (autopull every `word:` bits, default 32, `order: :msb`). Stalls while the TX FIFO is empty. Not with `inbox.current`, `take` or `each_bit` |
| `output :mosi, out: true`, then `mosi.put(bit)` | `mov pins, y` | the OUT pin (one), inside `each_bit`. `mosi.on` / `mosi.off` are `mov pins, ~null` / `mov pins, null` |
| `input :din`, then `din.wait_high` / `din.wait_low` | `wait 1 pin n` / `wait 0 pin n` | n = position among the inputs |
| `din.sample`, `din.sample(4)` | `in pins, 1`, `in pins, 4` | first input only (`in` reads from the IN base); the width takes the inputs declared after it |
| `sleep din.pick(when high, when low)` | `jmp pin` | the first input a program picks or branches on becomes the JMP pin. Any other input is read into Y instead (`mov osr, pins`, `out null, k`, `out y, 1`, then `jmp !y`: 2-3 more instructions; not with `inbox`, inside `each_bit` or inside a repeat that counts in Y). The pin is read by the first instruction of the wait; `report` says how many cycles after the previous statement |
| `din.branch { \|high\| ... }`, `bit.branch { \|one\| ... }` | `jmp pin` / `jmp !y`, `jmp` to the end | different statements per path: the block runs once per path, with `high` (`one`) true in one and false in the other. The sleep before it leads to each path's first statement (a sleep at the head of a path adds to it); each path's last sleep leads to the statement after the branch (both paths end with a sleep, or neither). Branches nest (a `bit.branch` inside a `bit.branch` is refused) and go inside `repeat` |
| `repeat(n) { ... }` | `set x, n-1` ... `jmp x--` | n = 1-32, counted in X (not with `inbox.current`). A repeat inside a repeat counts in Y (`set y` ... `jmp y--`; waits inside it use `nop`s only, and it cannot hold `each_bit` or a sleep on a received value); no third level. Branches and `take.each_bit` go inside a repeat, and a repeat goes inside `each_bit` or a branch. The body's last sleep leads to the next pass and, after the last pass, to the next statement; a sleep written after the repeat adds to it |
| `period = inbox.preset`, then `sleep period` | `mov y, isr` + `jmp y--` | a second value, which the CPU puts in the ISR before the start: `StateMachine#load_isr` on the device, `<name>_load_preset` in the C header (as pico-examples' PWM keeps its period). No instruction of its own. The ISR is then not free for `sample`, `push` or `autopush`. `report` writes it as m (and `inbox.current` as n) |
| `outbox.autopush(n, order: :msb)` | ISR shift and autopush in the artifact | once per program. With `order: :lsb` the ISR shifts right, so the n bits arrive in the top of the word (read `word >> (32 - n)`) |
| `outbox.push` | `push block` | |
| `irq(n).set` / `irq(n).clear` | `irq set n` / `irq clear n` | `irq(n, rel: true)` for pioasm's `rel` |
| `irq(n).set_and_wait` | `irq wait n` | raise the flag and stall until something clears it |
| `irq(n).wait` | `wait 1 irq n` | stall until the flag is raised, then clear it |

**Side-set**
- A side-set change takes no instruction of its own. It happens at the start of an instruction:
  - It rides on the next statement's instruction (`busy.on` above rides on `din.sample`).
  - When a sleep follows it, it rides on the previous statement's instruction if no sleep came in between; otherwise on the first instruction the sleep makes (a branch, a `nop`, `set y`).
  - At the end of a loop, it rides on the previous statement's instruction or gets a `nop`.
- It never rides back onto a wait: a wait's time is when it ends, but side-set acts when it starts. Riding forward onto a wait is how a pin keeps a level while the SM stalls (`busy.off` above).
- Before its first change in the loop, a side-set pin holds the level it has at the end of the loop.
- Side-set bits take the top of the delay field: with s side-set outputs the delay limit is 2^(5−s) − 1 (15 with one). Longer waits use `nop`s or `set y` + `jmp y--` as before; waits longer than one `set y` + `jmp y--` pair can hold chain several pairs.
- Side-set is not optional (`opt`): every instruction drives the side-set pins.

**Waits**
- `wait_high`, `wait_low`, `set_and_wait` and `irq(n).wait` stall without an upper bound. Times after them count from when they end.
- A loop with a wait has no fixed period. `report` lists the segments instead, as it does for bit loops.

**Verified**
- Branches: a pin the two paths leave at different levels must be set again before an instruction drives it (for side-set, the instruction right after the branch; for SET pins, the next `set pins` that does not change it). Manchester, where each bit ends at the level it encodes, is fine with a SET pin.
- `test/timed_ext_cases.rb` runs 25 programs on `lib/pico/pio/sim.rb` (which models side-set, all SET pins, the OUT pin, `wait`, `in`, `push`, `irq` and `jmp pin`) and checks edges, sampled words and IRQ flags cycle by cycle: two SET pins changing together, 4 inputs sampled at once, a wait that follows an input, a burst of 21 pulses with `repeat`, SPI transmit with `put`, a long pick read when it begins, Manchester with `bit.branch`, statements per path with `din.branch`, side-set set again after a branch, a PWM with `inbox.preset`, an 8-bit parallel bus with `inbox.next`, nested branches. It also checks the errors: a side-set pin changed twice at one point, sampling an input other than the first or wider than the inputs, two `autopush`, IRQ flag 8, six side-set outputs, picks on two inputs, nested `repeat`, `repeat` with `inbox.current`, a `repeat` body starting with a sleep, `put` outside `each_bit` or on a SET pin, a low wait shorter than the `jmp pin` branch, side-set left at different levels by the paths, nested branches, a branch inside `repeat`, a sleep at the end of only one path, a branch on a second input, `bit.branch` outside `each_bit`, a path's last sleep shorter than the instructions to the next bit, `inbox.preset` with `sample`, `inbox.next(4)` onto 8 OUT pins, `inbox.next` with `inbox.current`, a `bit.branch` inside a `bit.branch`.
- 22 of them match hand-written `test/pioasm/*.pio` run through pioasm.
- `examples/rp2040/timed_selftest.rb` runs on a Pico using GPIO 25, and GPIO 4 for SCK if it floats (`sh tools/rp2040_selftest.sh timed`; 15 checks, all passed, twice). Ten of them set up their SMs with `Program#init_sm`:
  - WS2812 with the data pin on side-set gives the same 16 High / Low counts as the SET-pin version.
  - `wait_high` / `wait_low` on a pin driven by the CPU raise IRQ flag 0 on the rise and 1 on the fall.
  - One SM makes 4 cycles High / 4 Low and another samples it every 2 cycles with `autopush(8)`: every byte is 0x33.
  - `set_and_wait` holds with no pulse until the CPU clears flag 1; then the 20-cycle side-set pulse counts 80 at clkdiv 8 (20 x 4).
  - `irq(2).set` every 10 ms (built for 100 kHz): flags every 9996-9999 us (median of 5 intervals).
  - `repeat(3)`: every pulse 5 cycles, Low 10, 10, 40 cycles in turn (counts 20; 39, 39, 159).
  - `mode.pick(10 ms, 30 ms)` on GPIO 25 driven by the CPU: flags every 9995-9996 us while high, 29998 us while low (median of 5).
  - `bit.branch` Manchester of 0xA5 with 4-cycle halves: High 8, 8, 4, 8 cycles and Low 8, 4, 8, 8 (counts 32, 32, 16, 32; 31, 15, 31, 31).
  - `din.branch` on GPIO 25 driven by the CPU: flag 0 every 9995 us while high, flag 1 every 9995-9996 us while low, and never the other flag.
  - `inbox.preset`: ISR 30 loaded with `load_isr`, 10 received: High 13 cycles, Low 35 (counts 52, 139).
  - `write(inbox.next(1))` on GPIO 25 (out pins with autopull), word 0xB40F0000: High 4, 8, 4 cycles and Low 4, 4, 24.
  - A repeat inside a repeat: every pulse 2 cycles; Low 3, 3, 13, 3, 3, 33 cycles in turn (counts 8; 11, 11, 51, 11, 11, 131).
  - Branches on two inputs, GPIO 25 (the JMP pin) and GPIO 26 (through the OSR), driven by the CPU: only flag 0, 1 or 2 is raised, by the levels.
  - `put(bit)` with MOSI on GPIO 25 and SCK on GPIO 4: bytes 0xB4, 0x0F give MOSI High 4, 8, 4 cycles and Low 4, 4, 24.

**SM setup**
- The artifact carries the pin roles (SET, side-set, OUT and IN pin counts, the JMP input). `to_c` adds `<name>_program_init(pio, sm, offset, <a base per role>)` in the style of pico-examples (pins, GPIO functions, pin directions, clkdiv from `clock_get_hz(clk_sys)`), and on the device `Program#init_sm(sm, offset, set_base, side_base, out_base, in_base, sys_hz)` does the same (pass -1 for a role the program does not use). Both leave the SM stopped. `tools/c_header_check.sh` (run by `test/check.sh` when `PICO_SDK`, `CLANG` and `BAREMETAL_PICOLIBC` are set) compiles the headers of 24 programs and calls to their `_program_init` (and `_load_preset`) against pico-sdk 2.3.1 with clang, `-Wall -Wextra -Werror`, syntax only.

## What the time layer can do

- `sleep 2.us`, `sleep 100.cycles`: based on the wait length, it picks the delay of the previous instruction, `nop`, or `set y` + `jmp y--`.
- Several SET pins, side-set pins, the OUT pin, inputs (`wait_high`, `wait_low`, `sample`, `pick`, `branch`), `repeat`, the RX FIFO (`outbox.push`, `outbox.autopush`) and IRQ flags (see the section above).
- `inbox.current` and `sleep received`: wait for the received value. The received value stays in X, and the wait is counted in Y (because when the FIFO is empty, `pull noblock` copies X into the OSR).
- Segments that wait on the same received value are equalized automatically. In `Square`, both High and Low are n+5.
- Cycles per loop and per segment are printed by `report` and `to_c`.
- Invalid code stops with an error. These cases are covered:
  - Receiving written twice.
  - No loop, or two loops.
  - Instructions after the loop.
  - A sleep before the first instruction (a side-set change before it gets a `nop` to count from).
  - More than 32 instructions.
  - A wait that is too long.
  - A duration that is not a whole number of cycles.

## Not yet supported

- One value received while running (`inbox.current`) plus one preset (`inbox.preset`), and one loop (the program's wrap); `repeat` nests once.
- A second input to pick or branch on costs 2-3 instructions and the OSR (see `pick`).
- One OUT output (one pin for `put`, or `width:` pins for `write`).
- The side-set WS2812 is 6 instructions; pioasm's hand-written version is 4 (it puts the bit branch on the side-set instruction and lets wrap join the paths).
- Board drivers: RP2040 only; no USB yet. Interrupts are recorded by a C handler and seen from Ruby by polling or WFI; Ruby code does not run inside an interrupt. I2C has been tried only with nothing attached (refused addresses, timeouts), not with a real target. Copying a UF2 to a real BOOTSEL drive has not been tried.

The recommended structure and the order of extensions come from a separate survey of PIO programming styles (kept outside this repository, in `../reports/`).

## Runtime layer (on the microcontroller)

The runtime layer loads assembled programs into a PIO block and configures and drives state machines from Ruby compiled by Spinel. It is ported to RP2040, accesses registers through MMIO via Spinel FFI, and was verified on hardware under Spinel's bare-full route.

Files:

| File | Contents |
|---|---|
| `lib/pico/pio/program.rb` | `Pico::PIO::Program` and `Pico::PIO::SMConfig` (chip-independent) |
| `lib/pico/pio/runtime.rb` | `Pico::PIO::Block` and `Pico::PIO::StateMachine` (chip-independent steps) |
| `lib/pico/pio/encode.rb` | `Pico::PIO::Encode`: single instructions built on the device, for `StateMachine#exec` |
| `lib/pico/chip.rb` | port: `Pico::Chip` data for RP2040 (shared with the other drivers) |
| `lib/pico/resets.rb` | `Pico::Resets` (used by `Block#reset!`) |
| `lib/pico/mmio.rb` | bus: `Pico::MMIOBus` |
| `tools/export_selftest.rb` | assembles the self-test programs on the host and writes `examples/rp2040/selftest_programs.rb` |
| `examples/rp2040/selftest.rb` | on-device self-test (WS2812 plus two measuring SMs) |
| `examples/rp2040/timed_selftest.rb` | on-device self-test of the time layer's side-set, `wait`, `in` and `irq` (PASS / FAIL) |
| `tools/rp2040_selftest.sh` | builds, flashes, and runs the self-test |
| `test/runtime_regs.rb` | register values checked with a fake bus |
| `test/encode_vs_asm.rb` | every `Encode` encoder checked against the assembler layer (272 cases) |

**API** (names mirror pico-sdk)

| Class | Methods |
|---|---|
| `Program` | `#default_config(offset)` |
| `SMConfig` | `set_wrap`, `set_sideset`, `set_out_shift`, `set_in_shift`, `set_out_pins`, `set_set_pins`, `set_in_pins`, `set_sideset_pins`, `set_jmp_pin`, `set_fifo_join`, `set_clkdiv_int_frac`, `set_clkdiv_for(sys_hz, clock_hz, fractional:)` |
| `Block` | `#reset!`, `#gpio_init`, `#add_program` (top-down allocation, `jmp` relocation), `#remove_program`, `#enable_in_sync`; IRQ flags: `#interrupt_get`, `#interrupt_clear`, `#interrupt_clear_mask`, `#interrupt_force`, `#irq_flags`; interrupt sources: `#set_irq0_source_enabled`, `#set_irq1_source_enabled`, `#set_irqn_source_enabled`, `#set_irqn_source_mask_enabled`, `#intr`, `#ints(n)` (sources `PIS_SM0_RX_FIFO_NOT_EMPTY + n`, `PIS_SM0_TX_FIFO_NOT_FULL + n`, `PIS_INTERRUPT0 + n`); `#fdebug`, `#clear_fdebug` |
| `StateMachine` | `#init`, `#set_enabled`, `#restart`, `#clkdiv_restart`, `#set_clkdiv_int_frac`, `#set_wrap`, `#set_out_pins`, `#set_set_pins`, `#set_in_pins`, `#set_sideset_pins`, `#exec`, `#exec_wait_blocking`, `#is_exec_stalled?`, `#get_pc`, `#set_consecutive_pindirs`, `#set_pins`, `#set_pins_with_mask`, `#set_pindirs_with_mask`, `#clear_fifos`, `#drain_tx_fifo`, `#put`, `#put_hl`, `#get`, `#tx_full?`, `#tx_empty?`, `#rx_full?`, `#rx_empty?`, `#tx_level`, `#rx_level` |
| `Encode` | `jmp` (and `jmp_not_x`, `jmp_x_dec`, ...), `wait_gpio`, `wait_pin`, `wait_irq`, `in_`, `out`, `push`, `pull`, `mov`, `mov_not`, `mov_reverse`, `irq_set`, `irq_wait`, `irq_clear`, `set`, `nop` |

- `put` and `get` wait (pico-sdk's `pio_sm_put_blocking` / `pio_sm_get_blocking`); there are no non-blocking versions yet.
- There is no interrupt handling yet: poll `ints(n)` or the IRQ flags.
- On an RP2040 Pico an `irq wait` given to `exec` stops the state machine but does not set EXECCTRL EXEC_STALLED (a `wait` does), although the datasheet says any exec'd instruction that stalls sets it. So `is_exec_stalled?` reads false and `exec_wait_blocking` returns at once for `irq wait`.
- `set_clkdiv_for` derives clkdiv from the clk_sys Hz and the clock the program was built for (`Program#clock_hz`). A fractional divider makes cycle lengths jitter, so it is rejected unless `fractional: true` is given.

**Port and bus**
- Port = `Chip` data. RP2040 addresses come from the pico-sdk 2.3.1 headers. Register offsets were checked against the RP2040 datasheet section 3.7.
- Bus = `MMIOBus`. It uses `ffi_source` for volatile `read32` / `write32` / `write32_hl`. Set, clear and XOR use the atomic aliases at +0x2000 / +0x3000 / +0x1000.

**32-bit limits on the device**
- In bare-full, `Integer` is 32-bit signed. Values with bit 31 set are written as hi/lo 16-bit halves (`write32_hl`, `StateMachine#put_hl`). `1 << 31` raises `RangeError`. Reading 0x80000000 returns -2147483648.
- Programs are assembled on the host and exported with `Assembled#to_ruby`, because ns × Hz overflows 32 bits on the device. `tools/export_selftest.rb` does this; `tools/rp2040_selftest.sh` fails if `examples/rp2040/selftest_programs.rb` differs from its output.

**Register test without hardware**

`test/runtime_regs.rb` runs the runtime layer against a fake bus that only records writes, and compares register values with values computed by hand from the bit positions in RP2040 datasheet section 3.7. CRuby and Spinel give the same output. `test/check.sh` runs it.

**Self-test on hardware**

```sh
sh tools/rp2040_selftest.sh pio      # or timed, board, all
```

Required environment variables are listed in the header of `tools/pico.sh`:

| Variable | Meaning |
|---|---|
| `SPINEL_MODULAR` | spinel-modular checkout (its `tools/bare-full` and a built `vendor/spinel`) |
| `BF_RUNTIME` | `libspinel_rt_bare.a` built with `spinel-bare-full runtime --cpu m0plus` |
| `OPENOCD_PREFIX` | directory containing `bin/openocd` and `share/openocd/scripts` |
| `LLVM_PREFIX`, `BAREMETAL_PICOLIBC`, `BAREMETAL_BUILTINS` | Cortex-M0+ toolchain (`tools/bare-full/README.md` in spinel-modular) |
| `OUT` (optional) | work directory (default: a temporary directory) |
| `CONSOLE` (optional) | console tty |

The script builds `examples/rp2040/selftest.rb` with bare-full for `rp2040-pico` (through `tools/pico.sh run`), flashes it through a Debugprobe (CMSIS-DAP), and reads the UART console up to the `EXIT` line.

On the device:
- SM0 runs WS2812 built for 12 MHz (SET pin = GPIO25). SM1 counts High durations and SM2 counts Low durations on the same PIO block (RX FIFOs joined to 8 entries).
- It sends `0xA5C30000` (first 8 bits 1010 0101) and reads 8 counts each.
- Run 1: clkdiv derived from the program clock (12 MHz / 12 MHz = 1). Run 2: clkdiv 8, to resolve single cycles.

Result on a Raspberry Pi Pico with bare-full (clk_sys from the 12 MHz crystal):

| clkdiv | High counts | Low counts | Meaning |
|---|---|---|---|
| 1 | [5,2,5,2,2,5,2,5] | [2,4,2,4,4,2,4,2] | 2-cycle resolution |
| 8 | [40,20,40,20,20,40,20,40] | [19,39,19,39,39,19,39,19] | High = 10/5 cycles (count = cycles × 4); Low = 5/10 cycles (count = cycles × 4 − 1) |

GC 0, EXIT 0. This matches the 12 MHz row of the table above (High 10 / 5, Low 5 / 10). Cycles were measured; the absolute ns were not measured with an external instrument.
