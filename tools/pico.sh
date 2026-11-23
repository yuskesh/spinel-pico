#!/bin/sh
# Build a Spinel program for the Raspberry Pi Pico (RP2040) with spinel-modular's bare-full route, write it to flash
# through a Debugprobe (CMSIS-DAP), and read the UART console.
#   pico.sh build <app.rb> <app.elf>     compile, link, and make the flash images
#   pico.sh flash <app.elf>              write flash over SWD, verify, reset
#   pico.sh run <app.rb> [timeout_s]     build, flash, print the console until BAREFULL EXIT (exit status 0 only on EXIT 0)
# build also leaves <app.elf>.bin (the flash image) and <app.elf>.uf2 (for the BOOTSEL drive) beside the ELF: the
# bare-full build makes both
# The RP2040 chip family and the rp2040-pico board file are this repository's own (port/); the build finds them
# through --port-dir.
# BOARD names another board file under port/board/ (default rp2040-pico).
# Env vars: SPINEL_MODULAR (a spinel-modular checkout with tools/bare-full and a built vendor/spinel), BF_RUNTIME (libspinel_rt_bare.a built with spinel-bare-full runtime --cpu m0plus),
#   LLVM_PREFIX, BAREMETAL_PICOLIBC, BAREMETAL_BUILTINS (for Cortex-M0+; see tools/bare-full/README.md in spinel-modular),
#   OPENOCD_PREFIX (directory containing bin/openocd and share/openocd/scripts).
#   Optional: OUT (work directory for run, defaults to a temp dir), CONSOLE (console tty)
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)

build() {
  : "${SPINEL_MODULAR:?}" "${BF_RUNTIME:?}"
  "$SPINEL_MODULAR/tools/bare-full/spinel-bare-full" build --runtime "$BF_RUNTIME" --port-dir "$HERE/port" --board "${BOARD:-rp2040-pico}" "$1" "$2" > /dev/null
}

flash() {
  : "${OPENOCD_PREFIX:?}"
  olog=${OUT:-$(dirname "$1")}/openocd.log
  "$OPENOCD_PREFIX/bin/openocd" -s "$OPENOCD_PREFIX/share/openocd/scripts" -f interface/cmsis-dap.cfg \
    -f target/rp2040.cfg -c "adapter speed 5000" -c "program $1 verify reset exit" > "$olog" 2>&1 ||
    { tail -20 "$olog"; exit 1; }
}

run() {
  OUT=${OUT:-$(mktemp -d)}
  limit=${2:-20}
  CONSOLE=${CONSOLE:-$(ls /dev/serial/by-id/*Debugprobe*if01 2>/dev/null | head -1)}
  [ -n "$CONSOLE" ] || { echo "console tty not found (set CONSOLE)"; exit 2; }
  elf=$OUT/$(basename "$1" .rb).elf
  build "$1" "$elf"
  stty -F "$CONSOLE" 115200 raw -echo
  log=$OUT/console.txt
  : > "$log"
  timeout "$limit" cat "$CONSOLE" > "$log" &
  p=$!
  sleep 0.3
  flash "$elf"
  i=0
  # wait for the whole EXIT / FATAL line: the status after EXIT can arrive a moment after the word
  while [ $i -lt $((limit * 10)) ] && ! finished "$log"; do sleep 0.1; i=$((i + 1)); done
  kill $p 2>/dev/null || true
  tr -d '\r' < "$log"
  tr -d '\r' < "$log" | grep -q '^BAREFULL.EXIT.0$'
}

# the console shows a complete BAREFULL EXIT <status> or BAREFULL FATAL line
finished() {
  tr -d '\r' < "$1" | grep -q '^BAREFULL.\(EXIT.-\{0,1\}[0-9][0-9]*\|FATAL.*\)$' && [ -z "$(tail -c 1 "$1" | tr -d '\r')" ]
}

case "${1:-}" in
  build) build "$2" "$3" ;;
  flash) flash "$2" ;;
  run) run "$2" "${3:-20}" ;;
  *) sed -n '2,12p' "$0"; exit 64 ;;
esac
