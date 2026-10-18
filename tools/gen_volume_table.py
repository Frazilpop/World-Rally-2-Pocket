#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally 2 for the Analogue Pocket — the GAE1's volume table.
"""Write volume_table.mem, which rtl/sound/wrally2_gae1_sound.v $readmemh's.

    python3 -I tools/gen_volume_table.py [build/gen/volume_table.mem]

4096 lines of 16-bit two's-complement hex, entry vol*256 + d for volume
vol = 0..15 and sample byte d = 0..255 (offset binary, 0x80 is silence):

    (vol * (d - 128) * 256) / 15, rounded toward zero

which is the table the GAE1's device_start builds in MAME's
sound/gaelco.cpp (m_volume_table[vol][(j ^ 0x80) & 0xff] = vol*j*256/15,
j = -128..127, C integer division). It is a formula, not ROM data, so the
file is a build product: the simulation and the Quartus build make it.
"""

import os
import sys

VOLUME_LEVELS = 16


def entry(vol, d):
    j = d - 128
    q = abs(vol * j * 256) // (VOLUME_LEVELS - 1)
    return -q if vol * j < 0 else q


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join("build", "gen", "volume_table.mem")
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with open(out, "w") as f:
        for vol in range(VOLUME_LEVELS):
            for d in range(256):
                f.write(f"{entry(vol, d) & 0xffff:04x}\n")
    print(f"{out}: {VOLUME_LEVELS * 256} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
