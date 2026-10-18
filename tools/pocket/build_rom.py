#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally 2 for the Analogue Pocket — the ROM image builder.
"""Build the Pocket's SDRAM image (<set>.rom) for World Rally 2 from MAME zips.

    python3 -I tools/pocket/build_rom.py wrally2b ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py all      ~/Downloads build/pocket
    python3 -I tools/pocket/build_rom.py wrally2b ~/Downloads build/roms --regions

THE CONTRACT is the SDRAM layout in LAYOUT below. One file per set,
0x1200000 bytes, every part at its fixed base, every gap zero. The Pocket
loads the file at bridge address 0 and the shell writes byte n to SDRAM
byte n; SDRAM word w is {byte[2w+1], byte[2w]}.

  maincpu  0x0000000  0x100000  68000 program, MAME's region as it is: byte 0
                                is the high byte of the first word
  ds5002   0x0100000  0x008000  the DS5002FP's SRAM image (its program, and
                                its MOVX data 0x0000-0x7fff), as MAME's
                                gaelco_ds5002fp:sram region
  gfx      0x0200000  0x1000000 MAME's 10 MB gfx region (graphics and samples)
                                rewritten as 64-bit fetch lines, below

FETCH LINES. The gfx region is five 2 MB planes (tilelayout16: plane p of
the 5 bpp pixel at p * 2 MB, p = 0 the least significant bit). Within a
plane, byte o = t*32 + h*16 + r is tile t, row r, left (h = 0) or right
(h = 1) eight pixels. The image keeps one 8-byte line per o:

    SDRAM byte 0x200000 + 8*o + p  =  gfx[p * 0x200000 + o]   (p = 0..4)
    SDRAM byte 0x200000 + 8*o + 5..7 = 0

so one 64-bit read is the five planes of an 8-pixel run (plane p in bits
[8p+7:8p] of the line), and a GAE1 sample byte at gfx offset A < 4 MB (the
sound banks are planes 0 and 1) is SDRAM byte 0x200000 + 8*(A & 0x1fffff) +
(A >> 21).

wrally2a: three mask ROMs where the other sets have 14 EPROMs.
init_wrally2 (gaelco2_m.cpp) splits ic69 and ic70 into even and odd bytes
(ROM16_split_gfx) and ic68 loads at 0x800000; this builder does the same, so
the image holds the gfx region MAME's driver init leaves, which is wrally2b's.

FILES ARE FOUND BY CRC32, NOT BY NAME OR PATH. A merged wrally2.zip keeps the
clones' own files under wrally2a/ .. wrally2d/; a split set keeps them in
their own zips. Every zip in ZIPDIR is indexed (central directory only,
nothing decompressed until needed), the set's own zip and its parent's are
preferred, and a directory ZIPDIR/<set>/ of loose files is accepted too.
Size and CRC pick the file; zipfile re-checks the CRC as it decompresses,
and the SHA1 is checked against MAME's before anything is written.

--regions writes OUTDIR/<set>_<region>.bin for MAME's three regions
(maincpu, ds5002 = gaelco_ds5002fp:sram, gfx) at MAME's sizes, for the
Verilator harness.

This reads ROMs named on the command line and writes only where told —
build/ by convention, which is gitignored. No ROM data is in this file.
"""

import argparse
import hashlib
import os
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# --------------------------------------------------------------------- layout
# (region, base, slot size). gfx's slot holds the fetch lines, not the region.
LAYOUT = [
    ("maincpu", 0x0000000, 0x0100000),
    ("ds5002",  0x0100000, 0x0008000),
    ("gfx",     0x0200000, 0x1000000),
]
IMAGE_SIZE = 0x1200000
GFX_SIZE = 0x0a00000          # MAME's region
PLANE = 0x0200000             # one bit plane of the gfx region
PLANES = 5
LINE = 8                      # bytes per fetch line

# ------------------------------------------------------------------ ROM_START
# Transcribed from MAME's gaelco2.cpp, ROM_START( wrally2 ) .. ( wrally2d ),
# in source order within each region. The plds region is left out: it is not
# on the board's buses.
#
#   ("L", name, crc, sha1, offset, length)   ROM_LOAD
#   ("B", name, crc, sha1, offset, length)   ROM_LOAD16_BYTE: byte k -> offset+2k
#   ("F", offset, length, value)             ROM_FILL
#   ("S", name, crc, sha1, length, dest1, dest2)
#        a gfx_temp ROM split as init_wrally2's ROM16_split_gfx does: its even
#        bytes to dest1.., its odd bytes to dest2..
#
# Region: (size, ops). Every region here has flag 0 and the image starts
# each from zeros; wrally2a's gfx has three 1 MB stretches nothing loads
# (0x500000, 0x700000, 0x900000), ROM_FILL 0 on the other sets, and
# verify_rom.py reports what MAME holds there.


def L(n, c, h, o, s): return ("L", n, c, h, o, s)
def B(n, c, h, o, s): return ("B", n, c, h, o, s)
def F(o, s, v): return ("F", o, s, v)
def S(n, c, h, s, d1, d2): return ("S", n, c, h, s, d1, d2)


def _program(even, odd):
    return (0x100000, [B(*even, 0x000000, 0x080000), B(*odd, 0x000001, 0x080000)])


def _gfx14(roms):
    """The 14-EPROM boards: (name, crc, sha1) in ROM_LOAD order, 512 KB each,
    at 0x000000 .. 0x480000, then 0x600000, 0x680000, 0x800000, 0x880000."""
    offs = [0x000000, 0x080000, 0x100000, 0x180000, 0x200000, 0x280000, 0x300000,
            0x380000, 0x400000, 0x480000, 0x600000, 0x680000, 0x800000, 0x880000]
    ops = [L(*r, o, 0x080000) for r, o in zip(roms, offs)]
    ops[10:10] = [F(0x500000, 0x100000, 0)]
    ops[13:13] = [F(0x700000, 0x100000, 0)]
    ops.append(F(0x900000, 0x100000, 0))
    return (GFX_SIZE, ops)


# 14 Jun 1995 graphics (wrally2, wrally2b) and 04 Jun 1995 (wrally2c,
# wrally2d), which share nine of the fourteen: 17, the four sound ROMs, 10,
# 02, 13 and 14.
_SND = [("wr2.18d", 0xe3617814, "9f9514052bb07d7e243f33b11bae409a444b7d9f"),
        ("wr2.19d", 0x2dae988c, "a585e10b0e1519b828738b0b90698f8600082250"),
        ("wr2.11d", 0xae66b97c, "bd0eba0b1c77864e06a9e136cfd834b35f200683"),
        ("wr2.12d", 0x6dbdaa95, "f23df65e3df92d79f7b1e99d611c067a79fc849a")]
GFX_14JUN = _gfx14([
    ("wr2.16d", 0xad26086b, "487ffaaca57c9d030fc486b8cae6735ee40a0ac3"),
    ("wr2.17d", 0xc1ec0745, "a6c3ce9c889e6a53f4155f54d6655825af34a35b"),
    _SND[0], _SND[1],
    ("wr2.09d", 0x372d70c8, "a6d8419765eab1fa20c6d3ddff9d026adaab5cd9"),
    ("wr2.10d", 0x5db67eb3, "faa58dafa26befb3291e5185ee04c39ce3b45b3f"),
    _SND[2], _SND[3],
    ("wr2.01d", 0x753a138d, "b05348af6d25e95208fc39007eb2082b759384e8"),
    ("wr2.02d", 0x9c2a723c, "5259c8fa1ad73518e89a8df6e76a565b8f8799e3"),
    ("wr2.20d", 0x4f7ade84, "c8efcd4bcb1f2ad6ab8104ec0daea8324cefd3fd"),
    ("wr2.13d", 0xa4cd32f8, "bc4cc73b7a58aecd735bf55bb5062baa6dd22f83"),
    ("wr2.21d", 0x899b0583, "a313e679980cc4da22bc70f2c7c9685af4f3d6df"),
    ("wr2.14d", 0x6eb781d5, "d5c13db88e6de606b34805391cef9f3fbf09fac4"),
])
GFX_04JUN = _gfx14([
    ("wr2_16_00_c846_4-6_27c040.bin", 0x76b9e7a4, "164b68a15b0e23b2a14e4b9763ca2f9fc517aa95"),
    ("wr2_17_01_7913_4-6_27c040.bin", 0xc1ec0745, "a6c3ce9c889e6a53f4155f54d6655825af34a35b"),
    _SND[0], _SND[1],
    ("wr2_9_10_3334_4-6_27c040.bin", 0xabf2c077, "3b505f2b6a008d96e7a10f1641d3d51802bedadd"),
    ("wr2_10_11_8573_4-6_27c040.bin", 0x5db67eb3, "faa58dafa26befb3291e5185ee04c39ce3b45b3f"),
    _SND[2], _SND[3],
    ("wr2_1_20_b950_4-6_27c040.bin", 0x0e089410, "b2ad3b8be486017ec7bfc96c7a79974cfd9ea42f"),
    ("wr2_2_21_fdc3_4-6_27c040.bin", 0x9c2a723c, "5259c8fa1ad73518e89a8df6e76a565b8f8799e3"),
    ("wr2_20_30_452c_4-6_27c040.bin", 0xf8108c1a, "915876ceebb6ea4eac26754341b6524c68808ffe"),
    ("wr2_13_31_cddf_4-6_27c040.bin", 0xa4cd32f8, "bc4cc73b7a58aecd735bf55bb5062baa6dd22f83"),
    ("wr2_21_40_b704_4-6_27c040.bin", 0x2214c465, "3a119ffb9ecf4e9bcd34888e9fd025a9a9d716ae"),
    ("wr2_14_41_999d_4-6_27c040.bin", 0x6eb781d5, "d5c13db88e6de606b34805391cef9f3fbf09fac4"),
])
GFX_MASK = (GFX_SIZE, [
    L("wr2_ic68.ic68", 0x4a75ffaa, "ffae561ad4fa100398ab6b94d8dcb13e9fae4272", 0x800000, 0x100000),
    S("wr2_ic69.ic69", 0xa174d196, "4a7da1cd288e73518143a027782f3140e6582cf4",
      0x400000, 0x000000, 0x200000),
    S("wr2_ic70.ic70", 0x8d1e43ba, "79eed51788c6c55a4347be70a3be4eb14a0d1747",
      0x200000, 0x400000, 0x600000),
])

PROG_2607 = _program(("wr2_64.ic64", 0x4cdf4e1e, "a3b3ff4a70336b61c7bba5d518527bf4bd901867"),
                     ("wr2_63.ic63", 0x94887c9f, "ad09f1fbeff4c3ba47f72346d261b22fa6a51457"))


def _sram(name, crc, sha1):
    return (0x8000, [L(name, crc, sha1, 0x0000, 0x8000)])


SRAM_DUMPED = _sram("wrally2_ds5002fp_sram.bin", 0x4c532e9e,
                    "d0aad72b204d4abd3b8d7d5bbaf8d2d2f78edaa6")

SETS = {
    # version 20-07, checksum B1B8: program 31 Jul 1995, Gaelco's bug-fixed
    # DS5002FP code. The parent.
    "wrally2": {"parent": None, "regions": {
        "maincpu": _program(
            ("dallas_usa_wr-2_2_64_usa_e47e_31-7.bin", 0x5e6a364a,
             "c1124f40c71f663ddac07c3d55a188692e8b65dc"),
            ("dallas_usa_wr-2_1_63_usa_c584_31-7.bin", 0x5c106494,
             "a8b93fad5b2e6d88b9a671ac44d7278abc8ea872")),
        "ds5002": _sram("wrally2_ds5002fp_sram_new.bin", 0xbcf47f69,
                        "8d2d5df2b2ed5ebc5c96241381ba687101dea834"),
        "gfx": GFX_14JUN}},
    # version 26-06, checksum 3EDB, mask ROM board; the older DS5002FP dump.
    "wrally2a": {"parent": "wrally2", "regions": {
        "maincpu": PROG_2607,
        "ds5002": _sram("wrally2_ds5002fp_sram_old.bin", 0xb0e25571,
                        "9afc51d9366ee0ae0bc0818516fe1c5ac5c390b0"),
        "gfx": GFX_MASK}},
    # version 26-06, checksum 3EDB.
    "wrally2b": {"parent": "wrally2", "regions": {
        "maincpu": PROG_2607, "ds5002": SRAM_DUMPED, "gfx": GFX_14JUN}},
    # version 09-06, checksum 7BE1: program 12 Jun 1995, graphics 04 Jun.
    "wrally2c": {"parent": "wrally2", "regions": {
        "maincpu": _program(
            ("wr2_e_ab01_12-6_27c040.bin", 0xc1c5ab6a, "9a49aa9bbf22dc069b540eaf981d300d95dfacf1"),
            ("wr2_o_7f46_12-6_27c040.bin", 0xddbcc45b, "c903451099d36a26336d65a54850530dc9bc912a")),
        "ds5002": SRAM_DUMPED, "gfx": GFX_04JUN}},
    # version 09-06, checksum 50A2: program 09 Jun 1995. MAME marks its four
    # sound ROMs BAD_DUMP (they are the parent's) and the set imperfect sound.
    "wrally2d": {"parent": "wrally2", "regions": {
        "maincpu": _program(
            ("wr2_e_f1d9_9-6_27c040.bin", 0x3de4dbfe, "2e278ba06ded2de7880703220d3c87ae4b3b17d9"),
            ("wr2_o_080e_9-6_27c040.bin", 0x6652ebd9, "0714cfdaa0b50c74eae4eb863994e2053f1799c8")),
        "ds5002": SRAM_DUMPED, "gfx": GFX_04JUN}},
}
REGION_ORDER = ["maincpu", "ds5002", "gfx"]
# MAME's tag for each region, for the region dump and verify_rom.py.
MAME_REGION = {"maincpu": ":maincpu", "ds5002": ":gaelco_ds5002fp:sram", "gfx": ":gfx"}


# --------------------------------------------------------------- ROM finding
class RomIndex:
    """Every ROM file under ZIPDIR, keyed by (size, crc32).

    Zips: the central directory gives both without decompressing anything.
    Loose files: only under ZIPDIR/<set>/ for the sets asked about (and their
    parents), hashed on demand — a whole Downloads folder is not read.
    """

    def __init__(self, zipdir):
        self.zipdir = zipdir
        self.entries = {}        # (size, crc) -> [(stem, kind, path, member)]
        self._loose_done = set()
        for name in sorted(os.listdir(zipdir)):
            path = os.path.join(zipdir, name)
            if name.lower().endswith(".zip") and os.path.isfile(path):
                try:
                    zf = zipfile.ZipFile(path)
                except (zipfile.BadZipFile, OSError):
                    continue
                stem = os.path.splitext(name)[0]
                for info in zf.infolist():
                    if info.is_dir():
                        continue
                    self.entries.setdefault((info.file_size, info.CRC), []).append(
                        (stem, "zip", path, info.filename))
                zf.close()

    def _add_loose(self, setname):
        if setname in self._loose_done:
            return
        self._loose_done.add(setname)
        d = os.path.join(self.zipdir, setname)
        if not os.path.isdir(d):
            return
        for root, _, files in os.walk(d):
            for f in files:
                p = os.path.join(root, f)
                with open(p, "rb") as fh:
                    data = fh.read()
                self.entries.setdefault((len(data), zlib.crc32(data)), []).append(
                    (setname, "file", p, None))

    def find(self, size, crc, prefer):
        for s in prefer:
            self._add_loose(s)
        cands = self.entries.get((size, crc), [])
        if not cands:
            return None
        rank = {s: i for i, s in enumerate(prefer)}
        return sorted(cands, key=lambda c: (rank.get(c[0], len(prefer)), c[0]))[0]

    def read(self, size, crc, sha1, prefer, name):
        hit = self.find(size, crc, prefer)
        if hit is None:
            raise SystemExit(f"missing ROM {name} (size {size:#x}, crc {crc:08x}) "
                             f"in {self.zipdir}: looked in every zip, preferring "
                             f"{', '.join(p + '.zip' for p in prefer)}")
        _, kind, path, member = hit
        if kind == "zip":
            with zipfile.ZipFile(path) as zf:
                data = zf.read(member)      # zipfile checks the CRC as it reads
        else:
            with open(path, "rb") as fh:
                data = fh.read()
        where = f"{os.path.basename(path)}:{member}" if member else path
        if len(data) != size or zlib.crc32(data) != crc:
            raise SystemExit(f"{name}: {where} does not match its CRC")
        if hashlib.sha1(data).hexdigest() != sha1:
            raise SystemExit(f"{name}: {where} has MAME's CRC but not its SHA1")
        return data, where


# ------------------------------------------------------------- region build
def build_regions(setname, index, log=print):
    """MAME's regions for a set, as its ROM_START and driver init leave them."""
    spec = SETS[setname]
    prefer = [setname] + ([spec["parent"]] if spec["parent"] else [])
    out = {}
    for rname in REGION_ORDER:
        size, ops = spec["regions"][rname]
        buf = bytearray(size)
        for op in ops:
            kind = op[0]
            if kind == "F":
                _, off, n, v = op
                buf[off:off + n] = bytes([v]) * n
                log(f"    {rname:<8} {off:#09x} ROM_FILL {v:#04x} len {n:#x}")
                continue
            if kind == "S":
                _, name, crc, sha1, length, d1, d2 = op
                data, where = index.read(length, crc, sha1, prefer, name)
                half = length // 2
                if max(d1, d2) + half > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[d1:d1 + half] = data[0::2]
                buf[d2:d2 + half] = data[1::2]
                log(f"    {rname:<8} {d1:#09x}/{d2:#09x} split {name:<20} {crc:08x} <- {where}")
                continue
            _, name, crc, sha1, off, length = op
            data, where = index.read(length, crc, sha1, prefer, name)
            if kind == "L":
                if off + length > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[off:off + length] = data
            elif kind == "B":
                if off + 2 * length - 1 > size:
                    raise SystemExit(f"{setname}:{rname}: {name} overruns the region")
                buf[off:off + 2 * length - 1:2] = data
            else:
                raise AssertionError(kind)
            log(f"    {rname:<8} {off:#09x} {kind} {name:<20} {crc:08x} <- {where}")
        out[rname] = bytes(buf)
    return out


def gfx_lines(gfx):
    """The 10 MB gfx region as 2M fetch lines of 8 bytes (16 MB)."""
    if len(gfx) != GFX_SIZE:
        raise SystemExit(f"gfx is {len(gfx):#x}, expected {GFX_SIZE:#x}")
    out = bytearray(PLANE * LINE)
    for p in range(PLANES):
        out[p::LINE] = gfx[p * PLANE:(p + 1) * PLANE]
    return bytes(out)


def gfx_from_lines(lines):
    """The inverse: MAME's gfx region from the fetch lines (for verify_rom.py)."""
    return b"".join(lines[p::LINE] for p in range(PLANES))


def build_image(regions):
    img = bytearray(IMAGE_SIZE)
    parts = dict(regions, gfx=gfx_lines(regions["gfx"]))
    for rname, base, slot in LAYOUT:
        data = parts[rname]
        if len(data) > slot:
            raise SystemExit(f"{rname} is {len(data):#x}, over its {slot:#x} slot")
        img[base:base + len(data)] = data
    return bytes(img)


# -------------------------------------------------------------------- main
def expand_sets(arg):
    if arg == "all":
        return list(SETS)
    names = arg.split(",")
    for n in names:
        if n not in SETS:
            raise SystemExit(f"unknown set {n!r}; known: {', '.join(SETS)}")
    return names


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("set", help="set name, comma list, or 'all'")
    ap.add_argument("zipdir", help="directory holding the MAME zips")
    ap.add_argument("outdir", help="output directory (keep it under build/)")
    ap.add_argument("--regions", action="store_true",
                    help="write <set>_<region>.bin per MAME region instead of <set>.rom")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()

    index = RomIndex(os.path.expanduser(a.zipdir))
    os.makedirs(a.outdir, exist_ok=True)
    log = (lambda *x: None) if a.quiet else print
    for s in expand_sets(a.set):
        print(f"{s}:")
        regions = build_regions(s, index, log)
        if a.regions:
            for rname in REGION_ORDER:
                p = os.path.join(a.outdir, f"{s}_{rname}.bin")
                with open(p, "wb") as f:
                    f.write(regions[rname])
                print(f"  {p}  {len(regions[rname]):#x}")
        else:
            img = build_image(regions)
            p = os.path.join(a.outdir, f"{s}.rom")
            with open(p, "wb") as f:
                f.write(img)
            print(f"  {p}  {len(img)} bytes  sha1 {hashlib.sha1(img).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
