#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally 2 for the Analogue Pocket — check the ROM images against MAME.
"""Check <set>.rom byte for byte against the regions MAME itself loads.

    python3 -I tools/pocket/verify_rom.py all --zipdir ~/Downloads --romdir build/pocket

For each set: runs MAME with tools/mame_wrally2_regions.lua (dumps into
build/mame/regions/<set>/, skipped with --no-mame if they are already there),
then compares every slot of the .rom image with MAME's region:

  * maincpu, ds5002 — the slice [base, base + MAME's region size) must equal
    MAME's region exactly, and the rest of the slot must be zero.
  * gfx — the slot's fetch lines are turned back into a 10 MB region
    (build_rom.gfx_from_lines), which must equal MAME's gfx region; bytes 5-7
    of every line must be zero.
  * every byte outside the three slots must be zero.

wrally2a's gfx comes from three mask ROMs that MAME's driver init splits;
when wrally2b is in the run too, wrally2a's gfx slot must also equal
wrally2b's byte for byte (the same graphics on two kinds of chip).

Exit status 0 only if every set matches.
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_rom  # noqa: E402  (the module beside this file)

REPO = build_rom.REPO
LUA = os.path.join(REPO, "tools", "mame_wrally2_regions.lua")


def run_mame(setname, zipdir, dumpdir, mame):
    os.makedirs(dumpdir, exist_ok=True)
    # a fresh cfg and nvram every run: MAME keeps the DS5002FP's SRAM as NVRAM
    os.makedirs(os.path.join(REPO, "build", "mame", "run"), exist_ok=True)
    work = tempfile.mkdtemp(prefix=f"verify-{setname}.", dir=os.path.join(REPO, "build", "mame", "run"))
    env = dict(os.environ, DUMP_DIR=dumpdir)
    cmd = [mame, "-rompath", zipdir, setname,
           "-autoboot_script", LUA, "-skip_gameinfo", "-autoboot_delay", "0",
           "-video", "none", "-sound", "none", "-nothrottle", "-seconds_to_run", "60",
           "-cfg_directory", os.path.join(work, "cfg"),
           "-nvram_directory", os.path.join(work, "nvram"),
           "-snapshot_directory", os.path.join(work, "snap")]
    try:
        r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    finally:
        shutil.rmtree(work)
    if not os.path.exists(os.path.join(dumpdir, "regions.txt")):
        sys.stdout.write(r.stdout + r.stderr)
        raise SystemExit(f"{setname}: MAME did not dump its regions")


def first_diff(a, b):
    n = min(len(a), len(b))
    if a[:n] == b[:n]:
        return None
    lo, hi = 0, n            # binary search on equal prefixes
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if a[:mid] == b[:mid]:
            lo = mid
        else:
            hi = mid
    return lo if a[lo] != b[lo] else hi - 1


def count_diff(a, b):
    try:
        import numpy as np
        return int(np.count_nonzero(np.frombuffer(a, np.uint8) != np.frombuffer(b, np.uint8)))
    except ImportError:
        return sum(x != y for x, y in zip(a, b))


def compare(lines, name, base, mine, mame, note=""):
    d = first_diff(mine, mame)
    if d is None and len(mine) == len(mame):
        lines.append(f"  {name:<8} @{base:#09x}  {len(mame):#09x} bytes  MATCH{note}")
        return True
    if d is None:
        lines.append(f"  {name:<8} @{base:#09x}  MISMATCH: {len(mine):#x} bytes here, "
                     f"MAME's region {len(mame):#x}")
        return False
    lines.append(f"  {name:<8} @{base:#09x}  MISMATCH{note}: "
                 f"{count_diff(mine, mame)} bytes differ, first at +{d:#x} "
                 f"(rom {mine[d]:02x}, mame {mame[d]:02x})")
    return False


def verify(setname, romdir, dumpdir):
    img = open(os.path.join(romdir, f"{setname}.rom"), "rb").read()
    lines = []
    if len(img) != build_rom.IMAGE_SIZE:
        return False, [f"  image is {len(img):#x} bytes, expected {build_rom.IMAGE_SIZE:#x}"]
    ok = True
    covered = bytearray(len(img))
    for rname, base, slot in build_rom.LAYOUT:
        covered[base:base + slot] = b"\1" * slot
        mame = open(os.path.join(dumpdir, f"{rname}.bin"), "rb").read()
        if rname == "gfx":
            fetch = img[base:base + slot]
            ok &= compare(lines, rname, base, build_rom.gfx_from_lines(fetch), mame,
                          " (from the fetch lines)")
            pad = [fetch[k::build_rom.LINE] for k in range(build_rom.PLANES, build_rom.LINE)]
            if any(any(p) for p in pad):
                ok = False
                lines.append("  gfx      bytes 5-7 of the fetch lines are not all zero")
            continue
        n = len(mame)
        ok &= compare(lines, rname, base, img[base:base + n], mame)
        if any(img[base + n:base + slot]):
            ok = False
            lines.append(f"  {rname:<8} slot tail after {n:#x} is not zero")
        elif slot > n:
            lines[-1] += f", slot tail {slot - n:#x} zero"
    stray = sum(1 for i in range(0, len(img), 0x8000)
                if not covered[i] and any(img[i:i + 0x8000]))
    if stray:
        ok = False
        lines.append(f"  {stray} 32K blocks outside the slots are not zero")
    return ok, lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("--zipdir", default=os.path.expanduser("~/Downloads"))
    ap.add_argument("--romdir", default=os.path.join(REPO, "build", "pocket"))
    ap.add_argument("--dumpdir", default=os.path.join(REPO, "build", "mame", "regions"))
    ap.add_argument("--mame", default="mame")
    ap.add_argument("--no-mame", action="store_true", help="reuse existing region dumps")
    a = ap.parse_args()

    sets = build_rom.expand_sets(a.set)
    all_ok = True
    for s in sets:
        d = os.path.join(a.dumpdir, s)
        if not a.no_mame:
            run_mame(s, os.path.expanduser(a.zipdir), d, a.mame)
        ok, lines = verify(s, a.romdir, d)
        print(f"{s}: {'OK' if ok else 'FAIL'}")
        print("\n".join(lines))
        all_ok &= ok
    if "wrally2a" in sets and "wrally2b" in sets:
        base, slot = next((b, n) for r, b, n in build_rom.LAYOUT if r == "gfx")
        ga, gb = (open(os.path.join(a.romdir, f"{s}.rom"), "rb").read()[base:base + slot]
                  for s in ("wrally2a", "wrally2b"))
        same = ga == gb
        print(f"wrally2a gfx slot == wrally2b's: {'YES' if same else 'NO'}"
              + ("" if same else f", {count_diff(ga, gb)} bytes differ"))
        all_ok &= same
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
