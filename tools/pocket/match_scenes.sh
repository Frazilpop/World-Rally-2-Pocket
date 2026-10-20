#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally 2 (Pocket) — draw MAME dumps on the board and compare.
#
#   tools/pocket/match_scenes.sh SET.rom DUMPDIR... [--rom-lat N]
#
# Each DUMPDIR is one frame of tools/mame_wrally2_dump.lua (vram.bin,
# vram_buffer.bin, palette.bin, vregs.bin, screen.png). The harness
# (build/obj_wrally2/tb_wrally2, sim/wrally2/build.sh) draws it in scene
# mode – board time paused, the dump written into the video memories – and
# the picture is set against MAME's screen.png: the renderer checked on any
# game state MAME reaches, whether or not the harness's own run has parted
# from it. Also prints the sprite engine's longest line in 48 MHz clocks
# (of 3,072), lines cut short and the most cells on a line, at the SDRAM
# latency given (default 10 clocks). TB names another harness build, OUT
# the folder for its pictures (build/sim/scenes).
set -eu
[ $# -ge 2 ] || { sed -n '4,15p' "$0"; exit 2; }
rom=$1; shift
lat=10
dirs=""
while [ $# -gt 0 ]; do
  case $1 in
    --rom-lat) lat=$2; shift 2 ;;
    *) dirs="$dirs $1"; shift ;;
  esac
done
tb=${TB:-build/obj_wrally2/tb_wrally2}
out=${OUT:-build/sim/scenes}; mkdir -p "$out"
for d in $dirs; do
  n=$(basename "$d")
  mkdir -p "$out/$n"
  spr=$("$tb" "$rom" 4 "$out/$n" 3 --scene "$d" --rom-lat "$lat" 2>&1 | sed -n 's/^sprites: //p')
  px=$(python3 -I - "$d/screen.png" "$out/$n/frame_00003.ppm" <<'EOF'
import sys
sys.path.insert(0, "tools/pocket")
import match_frames as mf
m, s = mf.read_png(sys.argv[1]), mf.read_ppm(sys.argv[2])
print(sum(1 for i in range(0, len(s), 3) if s[i:i + 3] != m[i:i + 3]))
EOF
)
  echo "$d: $px px differ; sprites: $spr"
done
