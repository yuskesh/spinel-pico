#!/bin/sh
# Hardware selftests on an RP2040 Pico behind a Debugprobe (see tools/pico.sh for the env vars).
#   rp2040_selftest.sh [pio|timed|board|all]   (default all)
#   pio:   examples/rp2040/selftest.rb (WS2812 on PIO0, measured by two more SMs)
#   timed: examples/rp2040/timed_selftest.rb (time layer side-set, wait, in, irq on GPIO 25)
#   board: examples/rp2040/board_selftest.rb (GPIO, clocks, timer, UART, flash)
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
what=${1:-all}
ruby "$HERE/tools/export_selftest.rb" | cmp -s - "$HERE/examples/rp2040/selftest_programs.rb" ||
  { echo "examples/rp2040/selftest_programs.rb differs from tools/export_selftest.rb output"; exit 1; }
if [ "$what" = pio ] || [ "$what" = all ]; then
  sh "$HERE/tools/pico.sh" run "$HERE/examples/rp2040/selftest.rb"
fi
if [ "$what" = timed ] || [ "$what" = all ]; then
  sh "$HERE/tools/pico.sh" run "$HERE/examples/rp2040/timed_selftest.rb" 60
fi
if [ "$what" = board ] || [ "$what" = all ]; then
  sh "$HERE/tools/pico.sh" run "$HERE/examples/rp2040/board_selftest.rb" 60
fi
