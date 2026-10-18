#!/usr/bin/env bash
# World Rally 2 for the Analogue Pocket — fetch the upstream dependencies.
#
#   tools/bootstrap.sh              read-only clones into third_party/
#   tools/bootstrap.sh --fork       fork to your GitHub account first (needs gh)
#   tools/bootstrap.sh --no-mame    skip the MAME sparse checkout
#   tools/bootstrap.sh --update     re-pin deps.lock to current upstream HEADs
#
# Everything lands in third_party/, which is gitignored and never committed.
# Nothing is copied into rtl/ automatically: licence terms differ per
# dependency. Read the licence report this prints before lifting any code.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party"
LOCK="$ROOT/deps.lock"

DO_FORK=0
DO_MAME=1
DO_UPDATE=0

for a in "$@"; do
  case "$a" in
    --fork)    DO_FORK=1 ;;
    --no-mame) DO_MAME=0 ;;
    --update)  DO_UPDATE=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------- dependencies
#
# name | repo | branch | role | licence | forkable | sparse paths (optional)
#
# gaelco-fpga is the board: jlrh's World Rally 2 MiSTer core (cores/wrally2),
# which carries its own fx68k copy and the GHDL-synthesised mc8051 netlist for
# the DS5002FP. Its jtframe use is jtframe_dual_ram alone, so of jtcores only
# the RAM primitives are fetched, with jt8051 beside them as the other
# candidate for the DS5002.
#
# fx68k: jtfpga/fx68k, whose hdl/verilator/ flattens the s_nanod struct that
# Verilator cannot simulate in upstream's fx68k.sv (BLKANDNBLK on 'Nanod').
# Synthesis takes hdl/, simulation hdl/verilator/.

DEPS=(
  "gaelco-fpga|jlrh/gaelco-fpga|main|the board: GAE1 video and sound, 68000 bus, DS5002 glue|GPL-3.0|yes|"
  "jtcores|jotego/jtcores|master|jtframe RAM primitives; jt8051|GPL-3.0-or-later|no|/LICENSE /modules/jtframe/LICENSE /modules/jtframe/hdl/ram/* /modules/jt8051/*"
  "fx68k|jtfpga/fx68k|master|68000 main CPU (Verilator variant)|GPL-3.0-only|yes|"
  "pocket-utils|agg23/analogue-pocket-utils|master|Pocket shell IP: data loader, PSRAM, I2S audio, sync FIFO|MIT|yes|"
)

# --------------------------------------------------------------------- helpers

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

have() { command -v "$1" >/dev/null 2>&1; }

pin() { # repo dir -> sha
  git -C "$1" rev-parse HEAD 2>/dev/null || echo "UNKNOWN"
}

pinned_sha() { # name -> sha recorded in the existing deps.lock, empty if none
  [ -f "$LOCK" ] || return 0
  awk -v n="$1" '$1 == n { print $3 }' "$LOCK"
}

# Move a fresh clone back onto its recorded pin.
#
# Without this the lock is decorative: every clone takes branch HEAD and then
# deps.lock is overwritten with whatever arrived, so the file records what you
# happened to get instead of constraining what you got. MAME is the oracle this
# project verifies against — it silently moving between two machines, or between
# two runs on the same machine, undermines every comparison made against it.
#
# GitHub permits fetching a reachable SHA directly, so this stays a shallow
# fetch rather than deepening the clone.
#
# Written with explicit if/return rather than `test && return 0` guards: this
# script runs under `set -e`, where a bare failing test as the final command of
# a && list is a well-known way to abort the whole run.
checkout_pin() { # name dir -> checks out the pinned sha if one is recorded
  local name="$1" dir="$2" want have
  if [ "$DO_UPDATE" = 1 ]; then return 0; fi
  want="$(pinned_sha "$name")"
  if [ -z "$want" ] || [ "$want" = "UNKNOWN" ]; then return 0; fi
  have="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
  if [ "$have" = "$want" ]; then return 0; fi
  if git -C "$dir" fetch --depth 1 -q origin "$want" 2>/dev/null; then
    git -C "$dir" checkout -q FETCH_HEAD
    echo "  $name: pinned to $want"
  else
    warn "  $name: pinned $want not fetchable, left at branch HEAD ($(pin "$dir"))"
    warn "  $name: rerun with --update to re-pin deliberately"
  fi
}

# ------------------------------------------------------------------ toolchain

say "== toolchain"
need git
for t in verilator yosys; do
  if have "$t"; then echo "  $t        $(command -v $t)"
  else warn "  $t        MISSING — the simulation in sim/wrally2/ will not build"; fi
done
# pocket/build.sh runs Quartus Prime Lite 21.1 in Docker (raetro/quartus:21.1,
# linux/amd64; Colima on a Mac), so no Quartus install is needed here.
if have docker && docker info >/dev/null 2>&1; then
  echo "  docker     $(command -v docker) (pocket/build.sh: Quartus 21.1 in raetro/quartus:21.1)"
else
  warn "  docker     MISSING or not running — pocket/build.sh runs Quartus in Docker."
fi
if have mame; then echo "  mame       $(command -v mame)"
else warn "  mame       MISSING — the oracle. Every open question here is answered by running it."; fi
if [ "$DO_FORK" = 1 ]; then
  need gh
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login'"
  echo "  gh         $(gh api user --jq .login) (fork mode)"
fi
echo

# -------------------------------------------------------------------- vendors

mkdir -p "$VENDOR"
: > "$LOCK.tmp"
echo "# Pinned upstream revisions. Regenerate with tools/bootstrap.sh --update" >> "$LOCK.tmp"
echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOCK.tmp"

say "== dependencies"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name repo branch role lic forkable sparse <<< "$entry"
  dest="$VENDOR/$name"
  url="https://github.com/$repo.git"

  if [ "$DO_FORK" = 1 ] && [ "$forkable" = "yes" ]; then
    user="$(gh api user --jq .login)"
    if gh repo view "$user/$(basename "$repo")" >/dev/null 2>&1; then
      echo "  $name: fork already exists at $user/$(basename "$repo")"
    else
      echo "  $name: forking $repo -> $user"
      gh repo fork "$repo" --clone=false --remote=false >/dev/null
    fi
    url="https://github.com/$user/$(basename "$repo").git"
  elif [ "$DO_FORK" = 1 ]; then
    warn "  $name: not forked ($lic licence — see licence report below)"
  fi

  if [ -d "$dest/.git" ]; then
    if [ "$DO_UPDATE" = 1 ]; then
      echo "  $name: updating"
      git -C "$dest" fetch --depth 1 origin "$branch" -q
      git -C "$dest" checkout -q FETCH_HEAD
    else
      echo "  $name: present, skipping (use --update to re-pin)"
      want="$(pinned_sha "$name")"
      if [ -n "$want" ] && [ "$want" != "UNKNOWN" ] \
         && [ "$(pin "$dest")" != "$want" ]; then
        warn "  $name: DRIFT — on disk $(pin "$dest"), lock says $want"
      fi
    fi
  else
    echo "  $name: cloning $repo"
    if [ -n "$sparse" ]; then
      # A large repository of which a few directories are wanted: blobless,
      # no checkout until the sparse patterns are set, then the pin.
      git clone --filter=blob:none --no-checkout --depth 1 --branch "$branch" -q "$url" "$dest"
      git -C "$dest" sparse-checkout init --no-cone
      # shellcheck disable=SC2086
      git -C "$dest" sparse-checkout set $sparse
      checkout_pin "$name" "$dest"
      git -C "$dest" checkout -q
    else
      git clone --depth 1 --branch "$branch" -q "$url" "$dest"
      checkout_pin "$name" "$dest"
    fi
    # Keep upstream reachable even when working from a fork.
    git -C "$dest" remote add upstream "https://github.com/$repo.git" 2>/dev/null || true
  fi

  printf '%-14s %s %s\n' "$name" "$repo" "$(pin "$dest")" >> "$LOCK.tmp"

  # Local patches: tools/patches/<name>-*.patch, made with `git -C
  # third_party/<name> diff`, applied on top of the pin. The clone stays
  # upstream's plus a diff that is committed here, so a fresh checkout builds
  # the same core. Already applied (reverse applies cleanly) is skipped; one
  # that no longer applies after --update is a warning to go and rebase it.
  for patch in "$ROOT"/tools/patches/"$name"-*.patch; do
    [ -f "$patch" ] || continue
    if git -C "$dest" apply --reverse --check "$patch" 2>/dev/null; then
      echo "  $name: $(basename "$patch") already applied"
    elif git -C "$dest" apply --check "$patch" 2>/dev/null; then
      git -C "$dest" apply "$patch"
      echo "  $name: applied $(basename "$patch")"
    else
      warn "  $name: $(basename "$patch") does not apply to $(pin "$dest") — rebase it"
    fi
  done
done

# ------------------------------------------------------------------ MAME
#
# MAME is enormous. Blobless partial clone plus a non-cone sparse checkout
# pulls only the reference sources this project reads, a few MB rather than
# several GB: the gaelco2 driver and its video, the DS5002FP wrapper, the GAE1
# sound device and the CPU cores the board runs.

if [ "$DO_MAME" = 1 ]; then
  echo
  say "== mame (sparse reference checkout)"
  dest="$VENDOR/mame"
  if [ -d "$dest/.git" ]; then
    echo "  present, skipping"
  else
    git clone --filter=blob:none --no-checkout --depth 1 -q \
      https://github.com/mamedev/mame.git "$dest"
    git -C "$dest" sparse-checkout init --no-cone
    git -C "$dest" sparse-checkout set \
      '/src/mame/gaelco/gaelco2*' \
      '/src/mame/gaelco/gaelco_ds5002fp.*' \
      '/src/devices/sound/gaelco.*' \
      '/src/devices/cpu/mcs51/*' \
      '/src/devices/cpu/m68000/m68000.h' \
      '/src/devices/cpu/m68000/m68kcpu.*' \
      '/src/devices/cpu/m68000/m68kmusashi.*' \
      '/src/devices/cpu/m68000/m68kcommon.*' \
      '/src/devices/machine/74259.*' \
      '/src/emu/tilemap.*' \
      '/src/emu/drawgfx.*' \
      '/src/emu/digfx.*' \
      '/src/emu/emupal.*' \
      '/src/emu/video/generic.*' \
      '/src/emu/video.*' \
      '/src/emu/screen.*' \
      '/src/frontend/mame/luaengine.cpp' \
      '/LICENSE.md'
    # Pin only AFTER sparse-checkout is configured: checking out a ref before
    # the patterns exist would materialise every file of the tree.
    checkout_pin "mame" "$dest"
    git -C "$dest" checkout -q
    echo "  checked out $(find "$dest/src" -type f 2>/dev/null | wc -l) reference files"
  fi
  printf '%-14s %s %s\n' "mame" "mamedev/mame" "$(pin "$dest")" >> "$LOCK.tmp"
fi

# Preserve pins for anything vendored by hand rather than by this script.
if [ -f "$LOCK" ]; then
  while read -r name repo sha; do
    case "$name" in \#*|"") continue ;; esac
    if ! awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$LOCK.tmp"; then
      if [ -d "$VENDOR/$name/.git" ]; then
        printf '%-14s %s %s\n' "$name" "$repo" "$(pin "$VENDOR/$name")" >> "$LOCK.tmp"
      fi
    fi
  done < "$LOCK"
fi

mv "$LOCK.tmp" "$LOCK"

# --------------------------------------------------------------------- report

# fx68k reads its microcode with $readmemb at RUN time, relative to the working
# directory rather than to the source file. Symlinked into the root so a
# harness started from there finds them; without these fx68k executes an
# all-X microcode, which looks like a CPU that fetches once and stops.
if [ -f "$VENDOR/fx68k/hdl/microrom.mem" ]; then
    ln -sf third_party/fx68k/hdl/microrom.mem "$ROOT/microrom.mem"
    ln -sf third_party/fx68k/hdl/nanorom.mem  "$ROOT/nanorom.mem"
fi

cat <<'REPORT'

================================ LICENCE REPORT ================================

Read this before copying a single line out of third_party/.

  gaelco-fpga  GPL-3.0 — José Luis Rodríguez (jlrh). The board this core is
               built on, credited as such. Its fx68k copy and the mc8051
               netlist (Oregano Systems' mc8051, LGPL, through GHDL) carry
               their own terms: check each file's header.

  jtcores      GPL-3.0-or-later — Jose Tejada (jotego). jtframe_dual_ram and
               jt8051. Re-check the headers on every --update.

  fx68k        GPL-3.0-only — Jorge Cwik. No or-later grant, so taking it
               makes the whole core GPL-3.0-only.

  pocket-utils MIT — Adam Gastineau (agg23), 2022. Keep the notice.

  mame         Mixed. Read the header of every file: the gaelco/ drivers and
               the device models carry their own licences (mostly BSD-3).

================================================================================
REPORT

cat <<'NEXT'
Useful paths now available:

  third_party/gaelco-fpga/cores/wrally2/hdl/          the board (jlrh)
  third_party/mame/src/mame/gaelco/gaelco2.cpp        board, clocks, memory map
  third_party/mame/src/mame/gaelco/gaelco2_v.cpp      GAE1 video
  third_party/mame/src/devices/sound/gaelco.cpp       GAE1 sound
  third_party/mame/src/mame/gaelco/gaelco_ds5002fp.*  the DS5002FP
  third_party/fx68k/hdl/verilator/                    68000 (simulation)
  third_party/pocket-utils/ip/                        the Pocket shell's IP
NEXT
