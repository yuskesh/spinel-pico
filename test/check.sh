#!/bin/sh
# Checks: (1) examples and cases produce the same output on CRuby and Spinel (2) instructions and wrap match pioasm
#   (3 timing-layer examples, instruction-layer variants, all of pico-examples, error rejection) (3) sim.py periods
#   SPINEL=<spinel executable>  PIOASM=<pico-sdk pioasm>  PICO_EXAMPLES=<pico-examples checkout>
#   PICO_SDK, CLANG: check the register numbers against pico-sdk's headers (tools/regs_check.sh)
#   PICO_SDK, CLANG, BAREMETAL_PICOLIBC: compile the emitted C headers (tools/c_header_check.sh)
#   (stages whose tool is missing are skipped)
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
fail=0
for f in examples/tick.rb examples/square.rb examples/two_clocks.rb examples/ws2812_asm.rb examples/ws2812.rb test/cases.rb test/bits_cases.rb test/timed_ext_cases.rb test/runtime_regs.rb test/board_regs.rb test/usb_model.rb; do
  b=$(basename "$f" .rb)
  ruby "$f" > "$out/$b.cruby"
  if [ -n "${SPINEL:-}" ]; then
    "$SPINEL" "$f" -o "$out/$b.sp" > /dev/null
    "$out/$b.sp" > "$out/$b.spinel"
    if cmp -s "$out/$b.cruby" "$out/$b.spinel"; then echo "Spinel = CRuby: $b"; else echo "DIFF: $b"; fail=1; fi
  fi
done
[ -n "${SPINEL:-}" ] || echo "SPINEL not set: skipped comparison with CRuby"
if [ -n "${PIOASM:-}" ]; then
  for p in square tick first_in_loop ws2812_timed two_pins ws2812_side pulse sampler irq_tick handshake phases nibbles follow burst spi_tx manchester gate preset_pwm parallel8 confirm groups two_reads two_words double_pulse two_inputs pick_second; do "$PIOASM" -o hex "test/pioasm/$p.pio" > "$out/$p.hex"; done
  ruby test/pioasm_compare.rb "$out" | tee "$out/cmp"
  grep -q "MISMATCH" "$out/cmp" && fail=1
  ruby test/asm_vs_pioasm.rb "$PIOASM" test/pioasm/extra/*.pio || fail=1
  if [ -n "${PICO_EXAMPLES:-}" ]; then
    ruby test/asm_vs_pioasm.rb "$PIOASM" $(find "$PICO_EXAMPLES" -name '*.pio' | sort) || fail=1
  else
    echo "PICO_EXAMPLES not set: skipped comparison with pico-examples"
  fi
  ruby test/asm_errors.rb "$PIOASM" | tail -1
  ruby test/asm_errors.rb "$PIOASM" > /dev/null || fail=1
else
  echo "PIOASM not set: skipped comparison with pioasm"
fi
ruby test/bits_cases.rb | tail -1
ruby test/timed_ext_cases.rb | tail -1
ruby test/timed_ext_cases.rb > /dev/null || fail=1
ruby test/encode_vs_asm.rb | tail -1
ruby test/encode_vs_asm.rb > /dev/null || fail=1
ruby test/runtime_regs.rb | tail -1
ruby test/runtime_regs.rb > /dev/null || fail=1
ruby test/board_regs.rb | tail -1
ruby test/board_regs.rb > /dev/null || fail=1
ruby test/usb_model.rb | tail -1
ruby test/usb_model.rb > /dev/null || fail=1
if [ -n "${PICO_SDK:-}" ] && [ -n "${CLANG:-}" ]; then
  sh tools/regs_check.sh || fail=1
else
  echo "PICO_SDK or CLANG not set: skipped checking the register numbers against pico-sdk"
fi
if [ -n "${PICO_SDK:-}" ] && [ -n "${CLANG:-}" ] && [ -n "${BAREMETAL_PICOLIBC:-}" ]; then
  sh tools/c_header_check.sh || fail=1
else
  echo "PICO_SDK, CLANG or BAREMETAL_PICOLIBC not set: skipped compiling the C headers"
fi
ruby tools/export_selftest.rb | cmp -s - examples/rp2040/selftest_programs.rb && echo "selftest_programs.rb matches generated output" ||
  { echo "examples/rp2040/selftest_programs.rb differs from tools/export_selftest.rb output"; fail=1; }
ruby test/bits_cases.rb > /dev/null || fail=1
python3 tools/sim.py "8080 a027 e001 a241 0084 e000 a041 0087" 0 7 "5,10" 400
python3 tools/sim.py "f701 e000 e046 0d83" 0 3 "" 600
exit $fail
