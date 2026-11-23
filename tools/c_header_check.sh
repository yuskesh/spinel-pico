#!/bin/sh
# Compile the C headers the time layer emits (instructions, default config, <name>_program_init) against pico-sdk,
# syntax only, for RP2040 with clang.
#   PICO_SDK=<pico-sdk checkout (2.3.1)>  CLANG=<clang>  BAREMETAL_PICOLIBC=<picolibc sysroot for Cortex-M0+>
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/gen/pico"
echo '#include "boards/pico.h"' > "$out/gen/pico/config_autogen.h"      # what pico-sdk's cmake generates
printf '#define PICO_SDK_VERSION_MAJOR 2\n#define PICO_SDK_VERSION_MINOR 3\n#define PICO_SDK_VERSION_REVISION 1\n#define PICO_SDK_VERSION_STRING "2.3.1"\n' \
  > "$out/gen/pico/version.h"
ruby -e '
  require ARGV[0] + "/test/timed_ext_programs"
  progs = [TwoPins, WS2812Side, Pulse, Sampler, IrqTick, Handshake, Phases, Nibbles, Follow, Burst, SpiTx, LongPick, Manchester, Gate, SideJoin, PresetPwm, Parallel8, Confirm, Groups, TwoReads, TwoWords, DoublePulse, TwoInputs, PickSecond]
  main = +"#include \"pico/stdlib.h\"\n#include \"hardware/pio.h\"\n"
  calls = +""
  progs.each_with_index do |c, i|
    a = c.assemble
    File.write("#{ARGV[1]}/#{a.name}.pio.h", "#pragma once\n#include \"hardware/pio.h\"\n" + a.to_c)
    main << "#include \"#{a.name}.pio.h\"\n"
    as = a.assembled
    n = [as.set_count, as.side_set_count, as.out_count, as.in_count].count { |k| k > 0 }
    pins = (0...n).map { |k| (2 + k).to_s }
    pio = "pio#{i / 4 % 2}"
    calls << "    { uint o = pio_add_program(#{pio}, &#{a.name}_program); #{a.name}_program_init(#{([pio, (i % 4).to_s, "o"] + pins).join(", ")}); }\n"
    calls << "    #{a.name}_load_preset(#{pio}, #{i % 4}, 1000);\n" if a.to_c.include?("_load_preset")
  end
  File.write("#{ARGV[1]}/main.c", main + "int main(void) {\n" + calls + "    return 0;\n}\n")
' "$HERE" "$out"
inc="-I$out -I$out/gen"
for d in "$PICO_SDK"/src/common/*/include "$PICO_SDK"/src/rp2_common/*/include "$PICO_SDK"/src/rp2040/*/include "$PICO_SDK"/src/boards/include; do
  inc="$inc -I$d"
done
# -Wno-macro-redefined: picolibc and pico-sdk both define __weak
"$CLANG" --target=armv6m-none-eabi -mcpu=cortex-m0plus -mthumb -fsyntax-only -Wall -Wextra -Werror -Wno-macro-redefined \
  -std=gnu11 -DPICO_RP2040=1 -DPICO_ON_DEVICE=1 -DPICO_NO_HARDWARE=0 --sysroot="$BAREMETAL_PICOLIBC" \
  -isystem "$BAREMETAL_PICOLIBC/include" $inc "$out/main.c"
echo "C headers: 24 programs compile against pico-sdk"
