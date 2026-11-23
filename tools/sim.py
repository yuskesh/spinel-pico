# Emulates, per the datasheet, only the instructions we generate (jmp y--, pull noblock, mov x/y <- x/y/osr, set pins/x/y).
# Any other instruction, condition, or field raises (never silently continues)
import sys
M = 0xFFFFFFFF
class Unsupported(Exception): pass
def run(words, wrap_to, wrap_from, fifo, cycles):
    for v in fifo:
        if not 0 <= v <= M: raise ValueError(f"FIFO value {v} is not a uint32")
    pc, x, y, osr, pin, t = 0, 0, 0, 0, 0, 0
    edges = []
    while t < cycles:
        w = words[pc]; d = (w >> 8) & 31; op = w >> 13
        jumped = None
        if op == 0:                                   # jmp
            cond, addr = (w >> 5) & 7, w & 31
            if cond != 4: raise Unsupported(f"{pc}: jmp condition {cond}")
            if y != 0: jumped = addr
            y = (y - 1) & M                           # decrements even at 0
        elif op == 4:
            if (w & 0xFF) != 0x80: raise Unsupported(f"{pc}: push, pull block or if_empty ({w:#06x})")
            if fifo: osr = fifo.pop(0)
            else: osr = x                             # noblock: copies X if empty
        elif op == 5:                                 # mov
            dst, mop, src = (w >> 5) & 7, (w >> 3) & 3, w & 7
            if mop != 0 or dst not in (1, 2) or src not in (1, 2, 7):
                raise Unsupported(f"{pc}: mov ({w:#06x})")
            v = {1: x, 2: y, 7: osr}[src]
            if dst == 1: x = v
            else: y = v
        elif op == 7:                                 # set
            dst, v = (w >> 5) & 7, w & 31
            if dst == 0:
                if v not in (0, 1): raise Unsupported(f"{pc}: set pins supports 1 pin only")
                if v != pin: edges.append((t, v))
                pin = v
            elif dst == 1: x = v
            elif dst == 2: y = v
            else: raise Unsupported(f"{pc}: set destination {dst}")
        else:
            raise Unsupported(f"{pc}: instruction type {op}")
        t += 1 + d
        if jumped is not None: pc = jumped
        elif pc == wrap_from: pc = wrap_to
        else: pc += 1
    return edges
if __name__ == "__main__":
    words = [int(v, 16) for v in sys.argv[1].split()]
    wt, wf = int(sys.argv[2]), int(sys.argv[3])
    fifo = [int(v) for v in sys.argv[4].split(",")] if sys.argv[4] else []
    e = run(words, wt, wf, fifo, int(sys.argv[5]))
    hi = [b[0] - a[0] for a, b in zip(e, e[1:]) if a[1] == 1]
    lo = [b[0] - a[0] for a, b in zip(e, e[1:]) if a[1] == 0]
    print("  High:", hi[:6], " Low:", lo[:6])
