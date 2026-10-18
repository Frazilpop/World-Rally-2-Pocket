#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally 2 (Pocket) — after the Kaneko 16-bit core's match_frames.py,
# standard library only.
"""Compare the harness's frames with MAME's.

    match_frames.py SIMDIR MAMEDIR [--same] [frames...]

SIMDIR holds sim/wrally2/tb_wrally2's frame_NNNNN.ppm, MAMEDIR
tools/mame_wrally2_screens.lua's mNNNNN.png (both 384 x 240). For each
simulated frame: the MAME frame it matches best and how many pixels differ
there, and with --same the count against MAME's frame of the same number.
A frame is pixel-exact when the count is 0.
"""
import glob
import os
import struct
import sys
import zlib

W, H = 384, 240


def read_ppm(path):
    d = open(path, "rb").read()
    parts = d.split(maxsplit=4)
    w, h = int(parts[1]), int(parts[2])
    assert (w, h) == (W, H), f"{path}: {w} x {h}"
    return parts[4][:w * h * 3]


def read_png(path):
    """8-bit RGB or RGBA, not interlaced: what MAME's snapshot writes."""
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, ihdr = 8, b"", None
    while pos < len(d):
        n, t = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        if t == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif t == b"IDAT":
            idat += body
        pos += 12 + n
    w, h, depth, ctype, _, _, interlace = ihdr
    assert depth == 8 and ctype in (2, 6) and not interlace, f"{path}: {ihdr}"
    bpp = 3 if ctype == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 0xff
            elif f == 2:
                line[i] = (line[i] + b) & 0xff
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xff
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xff
        prev = line
        if bpp == 3:
            out += line
        else:
            for i in range(0, stride, 4):
                out += line[i:i + 3]
    assert (w, h) == (W, H), f"{path}: {w} x {h}"
    return bytes(out)


def differ(a, b):
    return sum(1 for i in range(0, W * H * 3, 3) if a[i:i + 3] != b[i:i + 3])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    same = "--same" in sys.argv
    sim, mame = args[0], args[1]
    want = {int(a) for a in args[2:]}
    M = {int(os.path.basename(p)[1:6]): read_png(p)
         for p in sorted(glob.glob(os.path.join(mame, "m*.png")))}
    if not M:
        print(f"no mNNNNN.png in {mame}", file=sys.stderr)
        return 2
    worst = 0
    for p in sorted(glob.glob(os.path.join(sim, "frame_*.ppm"))):
        f = int(os.path.basename(p)[6:11])
        if want and f not in want:
            continue
        S = read_ppm(p)
        if same:
            if f not in M:
                continue
            n = differ(M[f], S)
            worst = max(worst, n)
            print(f"sim {f:5d} = mame {f:5d}: {n:6d} px differ of {W * H}")
        else:
            scores = {k: differ(v, S) for k, v in M.items()}
            best = min(scores, key=scores.get)
            worst = max(worst, scores[best])
            print(f"sim {f:5d} ~ mame {best:5d}: {scores[best]:6d} px differ of {W * H}")
    return 0 if worst == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
