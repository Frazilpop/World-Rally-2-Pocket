#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally 2 (Pocket) — after the Kaneko 16-bit core's diff_bus_trace.py
# (alphanu1), with World Rally 2's map and the DS5002FP's side.
"""Diff the core's bus traces against MAME's.

    diff_bus_trace.py <core.txt> <mame.txt> <setname>

Both files are in tools/mame_wrally2_bus_trace.lua's format; the DS5002FP's
are beside them with ".mcu" added (sim/wrally2/tb_wrally2.cpp writes the
same pair). Exit status 0 only if every compared stream matches.

THE 68000. Two comparisons over the same accesses:

  * every access, in order, instruction fetches included. fx68k and MAME's
    m68000 agree on the prefetch on this board, so this is the strict one;
  * every WRITE and every READ outside the program ROM, in order -- what the
    program asked for, as opposed to how the CPU fetched it. Where the first
    fails and this holds, the difference is in the fetching.

Only the lanes both sides drove are compared: a byte write has an undefined
value on the idle half of the bus.

THE DS5002FP. Every MOVX to the shared RAM in order (address, direction,
data), then where each falls among the 68000's accesses (the n68k column):
MAME runs the two CPUs in lockstep, so a handshake that drifts shows there
first. The n68k figures are reported as the largest drift, not diffed: the
core's 8051 does not take the real chip's cycles per instruction.
"""
import sys
from collections import Counter

ROM_END = 0x100000       # wrally2_addr_decode.v: cs_rom = addr[23:20] == 0


def load(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 4:
                continue
            out.append((int(p[0], 16), p[1], int(p[2], 16), int(p[3], 16)))
    return out


def load_mcu(path):
    out = []
    try:
        f = open(path)
    except OSError:
        return None
    with f:
        for line in f:
            p = line.split()
            if len(p) != 5:
                continue
            out.append((int(p[0]), int(p[1]), int(p[2], 16), p[3], int(p[4], 16)))
    return out


def fmt(rec):
    a, rw, d, m = rec
    lane = {0xffff: "w", 0xff00: "hi", 0x00ff: "lo"}.get(m, f"{m:04x}")
    return f"{a:06x} {rw} {d:04x} .{lane}"


# gaelco2.cpp, wrally2_map -- one map serves all five sets.
MAPS = {
    "wrally2": [
        (0x202890, 0x202900, "gae1 sound 202890-2028ff"),
        (0x200000, 0x210000, "vram      200000-20ffff"),
        (0x210000, 0x212000, "palette   210000-211fff"),
        (0x212000, 0x214000, "extra ram 212000-213fff"),
        (0x218004, 0x21800a, "vregs     218004-218009"),
        (0x300000, 0x300008, "inputs    300000-300007"),
        (0x400000, 0x400040, "ls259     400000-40003f"),
        (0xfe0000, 0xfe8000, "work ram  fe0000-fe7fff"),
        (0xfe8000, 0xff0000, "shared    fe8000-feffff"),
    ],
}
ALIAS = {s: "wrally2" for s in ("wrally2a", "wrally2b", "wrally2c", "wrally2d")}


def region_for(setname):
    """Return a namer for this set. Raises rather than defaulting."""
    name = ALIAS.get(setname, setname)
    if name not in MAPS:
        raise SystemExit(f"diff_bus_trace: no memory map for {setname!r}. "
                         f"Known: {', '.join(sorted(MAPS) + sorted(ALIAS))}.")
    windows = MAPS[name]

    def region(a):
        if a < ROM_END:
            return f"rom       000000-{ROM_END - 1:06x}"
        for lo, hi, n in windows:
            if lo <= a < hi:
                return n
        return f"OTHER     {a & 0xff0000:06x}"

    return region


def first_diff(a, m):
    for i in range(min(len(a), len(m))):
        aa, mm = a[i], m[i]
        if aa[0] != mm[0] or aa[1] != mm[1] or aa[3] != mm[3]:
            return i
        if (aa[2] & aa[3]) != (mm[2] & mm[3]):
            return i
    return None


def show(a, m, first):
    print(f"  {'core':<22} {'mame':<22}")
    for i in range(max(0, first - 6), min(len(a), len(m), first + 7)):
        mark = "<<" if i == first else "  "
        print(f"  {i:8d} {fmt(a[i]):<22} {fmt(m[i]):<22} {mark}")


def compare68(name, a, m):
    n = min(len(a), len(m))
    first = first_diff(a[:n], m[:n])
    print(f"\n  68000, {name}: core {len(a)}, mame {len(m)}")
    if first is None:
        print(f"  MATCH over all {n} compared accesses")
        return True
    print(f"  FIRST DIVERGENCE at access {first} of {n}")
    show(a, m, first)
    return False


def compare_mcu(a, m, n68):
    """a, m: DS5002 records; n68: 68000 accesses both traces cover."""
    a = [r for r in a if r[0] < n68]
    m = [r for r in m if r[0] < n68]
    n = min(len(a), len(m))
    print(f"\n  DS5002FP shared-RAM MOVX within the first {n68} 68000 accesses: "
          f"core {len(a)}, mame {len(m)}")
    first = None
    drift = 0
    for i in range(n):
        if a[i][2:] != m[i][2:]:
            first = i
            break
        drift = max(drift, abs(a[i][0] - m[i][0]))
    if first is None and len(a) == len(m):
        print(f"  MATCH over all {n} accesses; largest drift against the 68000 "
              f"{drift} of its accesses")
        return True
    if first is None:
        first = n
    print(f"  FIRST DIVERGENCE at MOVX {first} (largest drift before it {drift})")
    print(f"  {'core: n68k t13 addr rw data':<32} {'mame':<32}")
    for i in range(max(0, first - 6), min(max(len(a), len(m)), first + 7)):
        fa = "%d %d %05x %s %02x" % a[i] if i < len(a) else ""
        fm = "%d %d %05x %s %02x" % m[i] if i < len(m) else ""
        print(f"  {fa:<32} {fm:<32} {'<<' if i == first else ''}")
    return False


def main():
    if len(sys.argv) < 4:
        print("usage: diff_bus_trace.py <core.txt> <mame.txt> <setname>", file=sys.stderr)
        return 2
    region = region_for(sys.argv[3])
    core, mame = load(sys.argv[1]), load(sys.argv[2])
    if not core or not mame:
        print(f"empty trace: core={len(core)} mame={len(mame)}", file=sys.stderr)
        return 2

    ok = compare68("every access", core, mame)

    def keep(r):
        return r[1] == "W" or r[0] >= ROM_END
    ok &= compare68("writes and data reads",
                    [r for r in core if keep(r)], [r for r in mame if keep(r)])

    ma, mm = load_mcu(sys.argv[1] + ".mcu"), load_mcu(sys.argv[2] + ".mcu")
    if ma is None or mm is None:
        print("\n  DS5002FP: no .mcu file beside one of the traces")
    else:
        ok &= compare_mcu(ma, mm, min(len(core), len(mame)))

    # Census: a region on one side only is the core and the driver
    # disagreeing about the map, not about behaviour.
    ca = Counter(region(r[0]) for r in core)
    cm = Counter(region(r[0]) for r in mame)
    print("\n  region                          core      mame")
    for k in sorted(set(ca) | set(cm)):
        flag = "  <- one side only" if (k not in ca) != (k not in cm) else ""
        print(f"  {k:<28} {ca.get(k, 0):8d}  {cm.get(k, 0):8d}{flag}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
