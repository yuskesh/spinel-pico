# Run a PIO program on a real RP2040 and have PIO itself measure the pin's High and Low widths.
# Only writes registers via OpenOCD (CMSIS-DAP / SWD); flash is not written. Afterwards reset run returns to the original firmware.
#   SM0: program under test (clkdiv D, SET pin = PIN)
#   SM1: counts High width (clkdiv 1, one count per 2 cycles) -> RX FIFO (joined to 8 deep)
#   SM2: counts Low width
# The program under test runs D times slower, so 1 of its cycles = D/2 counts. width = count * 2 / D
import os, re, subprocess, sys
O = os.path.expanduser(os.environ.get("OPENOCD_PREFIX", "~/zephyr-sdk-1.0.1/hosttools/sysroots/x86_64-pokysdk-linux/usr"))  # directory containing bin/openocd and share/openocd/scripts
PIN, D = 25, 8
PIO0 = 0x50200000
def sampler(base, pin):
    hi = [0x2000 | pin, 0x2080 | pin, 0xA02B,          # wait 0 / wait 1 gpio, mov x ~null
          0x0040 | (base + 4), 0x00C0 | (base + 3),     # jmp x-- next / jmp pin loop
          0xA0C9, 0x8000]                               # mov isr ~x / push noblock
    lb = base + 7
    lo = [0x2080 | pin, 0x2000 | pin, 0xA02B,
          0x00C0 | (lb + 5), 0x0040 | (lb + 3),         # jmp pin done / jmp x-- loop
          0xA0C9, 0x8000]
    return hi, lo
def measure(words, wrap_to, wrap_from, fifo, shiftctrl=None):
    L = len(words)
    hi, lo = sampler(L, PIN)
    prog = words + hi + lo
    assert len(prog) <= 32
    c = ["init", "reset halt",
         "mww 0x4000e000 0x400", "sleep 1",           # put PIO0 into reset (reset halt does not reset it)
         "mww 0x4000f000 0x520",                       # RESETS clear: io_bank0, pads_bank0, pio0
         "sleep 10", "mdw 0x4000c008",
         f"mww {0x40014004 + 8 * PIN:#x} 6"]           # GPIO function = PIO0
    for i, w in enumerate(prog): c.append(f"mww {PIO0 + 0x48 + 4 * i:#x} {w:#x}")
    sm = lambda n, off: PIO0 + 0xC8 + 0x18 * n + off  # CLKDIV 0, EXECCTRL 4, SHIFTCTRL 8, ADDR c, INSTR 10, PINCTRL 14
    c += [f"mww {sm(0,0):#x} {D << 16:#x}",
          f"mww {sm(0,4):#x} {(wrap_from << 12) | (wrap_to << 7):#x}",
          f"mww {sm(0,0x14):#x} {(1 << 26) | (PIN << 5):#x}",
          *( [f"mww {sm(0,8):#x} {shiftctrl:#x}"] if shiftctrl is not None else [] ),   # SHIFTCTRL (autopull, threshold, direction)
          f"mww {sm(0,0x10):#x} 0xe081",               # set pindirs, 1
          f"mww {sm(0,0x10):#x} 0x0"]                  # jmp 0
    for n, lw in ((1, L), (2, L + 7)):
        c += [f"mww {sm(n,0):#x} {1 << 16:#x}",
              f"mww {sm(n,8):#x} {1 << 31:#x}",        # FJOIN_RX: make the RX FIFO 8 deep
              f"mww {sm(n,4):#x} {(PIN << 24) | ((lw + 6) << 12) | (lw << 7):#x}",
              f"mww {sm(n,0x10):#x} {lw:#x}"]          # jmp lw
    for v in fifo: c.append(f"mww {PIO0 + 0x10:#x} {v:#x}")
    c += [f"mww {PIO0:#x} 0x777", "sleep 100", f"mdw {PIO0 + 4:#x}"]   # start all three together
    c += [f"mdw {PIO0 + 0x24:#x}"] * 8 + [f"mdw {PIO0 + 0x28:#x}"] * 8
    c += [f"mdw {sm(0,0xc):#x}", "mww 0x4000e000 0x400", "reset run", "exit"]   # stop PIO0 and release the pin
    args = [f"{O}/bin/openocd", "-s", f"{O}/share/openocd/scripts", "-f", "interface/cmsis-dap.cfg",
            "-f", "target/rp2040.cfg", "-c", "adapter speed 5000"]
    for x in c: args += ["-c", x]
    out = subprocess.run(args, capture_output=True, text=True, timeout=60)
    vals = [int(m, 16) for m in re.findall(r"^0x[0-9a-f]+: ([0-9a-f]{8})", out.stdout + out.stderr, re.M)]
    if len(vals) < 19: sys.exit("could not read:\n" + out.stderr[-1500:])
    fstat, his, los = vals[1], vals[2:10], vals[10:18]
    w = lambda k: k * 2 / D
    return fstat, [w(k) for k in his], [w(k) + 0.25 for k in los]   # Low measurement reads 0.25 short (calibrated: checked with 4,10,1)
if __name__ == "__main__":
    words = [int(v, 16) for v in sys.argv[1].split()]
    fifo = [int(v, 0) for v in sys.argv[4].split(",")] if sys.argv[4] else []
    shift = int(sys.argv[5], 16) if len(sys.argv) > 5 else None
    fs, h, l = measure(words, int(sys.argv[2]), int(sys.argv[3]), fifo, shift)
    print(f"  FSTAT {fs:#010x}  High {h}  Low {l}")
    # RXFULL (bits 0-3): if a measuring SM's FIFO did not fill all 8 entries, the trailing values are stale data from empty entries
    for sm_no, what in ((1, "High"), (2, "Low")):
        if not fs & (1 << sm_no):
            print(f"  warning: {what} FIFO did not fill all 8 entries; trailing values are stale from a previous run (e.g. pin stuck)")
