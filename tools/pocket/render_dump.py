#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally 2 (Pocket) — the left screen drawn from a MAME dump the way
# gaelco2_v.cpp's dual_update draws it, standard library only.
"""Draw the left screen from tools/mame_wrally2_dump.lua's files.

    render_dump.py DUMPDIR SET.rom OUT.ppm [--pixel X,Y]

DUMPDIR holds vram.bin, vram_buffer.bin, palette.bin and vregs.bin; SET.rom
is tools/pocket/build_rom.py's image (its gfx fetch lines are the tiles).
The tilemap comes from the live VRAM, the sprites from the buffer, as MAME
draws picture N. If OUT matches the dump's screen.png, the renderer below is
MAME's; a frame of the harness that differs from MAME's while this one
agrees has met a different game state, not a different renderer.
--pixel X,Y lists what is drawn at one pixel, in order.
"""
import struct
import sys

W, H = 384, 240
GFX = 0x200000


def words(path):
    d = open(path, "rb").read()
    return list(struct.unpack("<%dH" % (len(d) // 2), d))


class Gfx:
    def __init__(self, rom):
        self.rom = rom

    def pen(self, code, x, y):
        """Pixel (x, y) of 16x16 tile `code`: the row half's fetch line."""
        o = (code & 0xffff) * 32 + (x >> 3) * 16 + y
        line = self.rom[GFX + 8 * o: GFX + 8 * o + 5]
        b = 7 - (x & 7)
        return sum(((line[p] >> b) & 1) << p for p in range(5))


def pal5(v):
    return (v << 3) | (v >> 2)


ADJ = [0, -8, -16, -24, -32, -40, -48, -56, 64, 56, 48, 40, 32, 24, 16, 8]


def colour(pal, idx):
    var, e = idx >> 12, pal[idx & 0xfff]
    return tuple(max(0, min(255, pal5((e >> s) & 31) + ADJ[var])) for s in (10, 5, 0))


def checkoffsets():
    return [0x02, 0x0e, 0x0a, 0x1b, 0x15, 0x13, 0x04, 0x19, 0x0c, 0x1f, 0x08, 0x1d, 0x11, 0x06, 0x17, 0x10,
            0x01, 0x0d, 0x16, 0x09, 0x1a, 0x05, 0x1e, 0x00, 0x12, 0x0b, 0x14, 0x03, 0x1c, 0x18, 0x07, 0x0f]


def render(d, gfx, watch=None):
    vram, buf, pal, vregs = d["vram"], d["buf"], d["pal"], d["vregs"]
    log = []
    bmp = [[0] * W for _ in range(512)]
    # tilemap 0
    scroll0x = vram[0x2802 // 2] + 0x14
    scroll0y = vram[0x2800 // 2] + 1
    if vregs[0] & 0x8000:
        use = 0
        for i in range(31, -1, -1):
            if vram[0x2000 // 2 + 0x40 + checkoffsets()[i] * 3 + 1] & 0x1000:
                use = 31 - i
        scroll0y += use
    sy = scroll0y & 0x1ff
    bank = ((vregs[0] >> 9) & 7) * 0x1000
    for y in range(16, 256):
        row = (y + sy) & 0x1ff
        sx = ((vram[0x2000 // 2 + row] + 0x14) if vregs[0] & 0x8000 else scroll0x) & 0x3ff
        for x in range(W):
            col = (x + sx) & 0x3ff
            t = (row >> 4) * 64 + (col >> 4)
            a, b = vram[bank + 2 * t], vram[bank + 2 * t + 1]
            fx, fy = (a >> 7) & 1, (a >> 6) & 1
            px, py = col & 15, row & 15
            if fx: px = 15 - px
            if fy: py = 15 - py
            pen = gfx.pen(b, px, py)
            if pen:
                bmp[y][x] = (((a >> 9) & 0x3f) << 5) | pen
                if watch == (x, y - 16):
                    log.append(f"tile {b:04x} colour {(a >> 9) & 0x3f:02x} pen {pen}")
    # sprites
    start = (vregs[1] & 0x10) * 0x100
    adj = (383 - 320 + 1) - (511 - 320 - 1) - ((vregs[0] >> 4) & 1)
    for j in range(start, start + 0x1000, 8):
        w0, w1, w2, w3 = buf[j // 2: j // 2 + 4]
        if w0 & 0x8000 or not (w1 & 0x200):
            continue
        sx0, sy0 = w2 & 0x3ff, w1 & 0x1ff
        xf, yf = (w1 >> 11) & 1, (w1 >> 10) & 1
        xs, ys = ((w2 >> 12) & 15) + 1, ((w1 >> 12) & 15) + 1
        for y in range(ys):
            ey = ys - 1 - y if yf else y
            for x in range(xs):
                d5 = buf[((w3 // 2) + (y * xs + x)) & 0x7fff]
                num = ((w0 & 0x1ff) << 10) + (d5 & 0xfff)
                col = ((w0 >> 9) & 0x7f) + ((d5 >> 12) & 15)
                fxe = (col & 0x3f) == 0x3f
                ex = xs - 1 - x if xf else x
                for py in range(16):
                    ypos = (sy0 + ey * 16 + py) & 0x1ff if fxe else ((sy0 + ey * 16) & 0x1ff) + py
                    if ypos < 16 or ypos > 255:
                        continue
                    gpy = 15 - py if yf else py
                    for px in range(16):
                        if fxe:
                            xpos = (((sx0 + ex * 16 + px) & 0x3ff) + adj) & 0x3ff
                        else:
                            xpos = ((sx0 + ex * 16) & 0x3ff) + adj + px
                        if xpos < 0 or xpos >= W:
                            continue
                        gpx = 15 - px if xf else px
                        pen = gfx.pen(num, gpx, gpy)
                        if fxe:
                            if pen == 0 or pen >= 16:
                                continue
                            bmp[ypos][xpos] = (bmp[ypos][xpos] & 0xfff) | (0x1000 * pen)
                        else:
                            if pen == 0:
                                continue
                            bmp[ypos][xpos] = (col * 32 + pen) & 0xffff
                        if watch == (xpos, ypos - 16):
                            log.append(f"sprite {(j - start) // 8} cell {x},{y} num {num:05x} colour {col:02x}"
                                       f" pen {pen}{' (shadow/highlight)' if fxe else ''} -> {bmp[ypos][xpos]:04x}")
    img = bytearray()
    for y in range(16, 256):
        for x in range(W):
            img += bytes(colour(pal, bmp[y][x] & 0xffff))
    return img, log


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    dd, rom_path, out = argv[1], argv[2], argv[3]
    watch = None
    if "--pixel" in argv:
        x, y = argv[argv.index("--pixel") + 1].split(",")
        watch = (int(x), int(y))
    d = {"vram": words(dd + "/vram.bin"), "buf": words(dd + "/vram_buffer.bin"),
         "pal": words(dd + "/palette.bin"), "vregs": words(dd + "/vregs.bin")}
    img, log = render(d, Gfx(open(rom_path, "rb").read()), watch)
    with open(out, "wb") as f:
        f.write(b"P6\n384 240\n255\n" + bytes(img))
    for line in log:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
