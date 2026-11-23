#!/bin/sh
# Compile tools/regs_check.rb's _Static_asserts against pico-sdk's register headers for RP2040 and RP2350:
# every base address, register offset, bit and number spinel-pico uses must equal pico-sdk's.
#   PICO_SDK=<pico-sdk checkout (2.3.1)>  CLANG=<clang>
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
for chip in rp2040 rp2350; do
  ruby "$HERE/tools/regs_check.rb" $chip > "$out/$chip.c"
  def=""
  [ $chip = rp2350 ] && def="-DPICO_RP2350A=1"
  "$CLANG" -fsyntax-only -std=c11 -ferror-limit=0 $def -include stdint.h \
    -I"$PICO_SDK/src/$chip/hardware_regs/include" -I"$PICO_SDK/src/$chip/hardware_structs/include" \
    -I"$PICO_SDK/src/rp2_common/hardware_base/include" -I"$PICO_SDK/src/common/pico_base_headers/include" \
    -D__ASSEMBLER__=0 -Dstatic_assert=_Static_assert "$out/$chip.c"
  echo "registers: $(head -1 "$out/$chip.c" | sed 's/.*(\(.*\) values)/\1/') values match pico-sdk for $chip"
done
