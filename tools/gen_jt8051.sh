#!/usr/bin/env bash
# jt8051's microcode: jt8051.vh, jt8051_param.vh and jt8051.uc, expanded from
# third_party/jtcores/modules/jt8051/ucode/8051.yaml by jtframe's ucode tool
# (Go, built into build/bin on first use). Derived files: they go under
# build/, never into the repository.
#   tools/gen_jt8051.sh [outdir]      (default build/gen/jt8051)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JT="$ROOT/third_party/jtcores"
OUT="$(mkdir -p "${1:-$ROOT/build/gen/jt8051}" && cd "${1:-$ROOT/build/gen/jt8051}" && pwd)"
TOOL="$ROOT/build/bin/jtframe"
[ -f "$JT/modules/jtframe/src/jtframe/main.go" ] || { echo "jtframe's Go source is missing: run tools/bootstrap.sh" >&2; exit 1; }
if [ ! -x "$TOOL" ]; then
  command -v go >/dev/null || { echo "go is missing (brew install go)" >&2; exit 1; }
  mkdir -p "$ROOT/build/bin"
  (cd "$JT/modules/jtframe/src/jtframe" && go build -o "$TOOL" .)
fi
# jtframe wants its tree in the environment; JTBIN is only checked for.
cd "$OUT"
JTROOT="$JT" JTFRAME="$JT/modules/jtframe" MODULES="$JT/modules" CORES="$JT/cores" JTBIN="$OUT" \
  "$TOOL" ucode --output jt8051 jt8051 8051
ls "$OUT"/jt8051.vh "$OUT"/jt8051_param.vh "$OUT"/jt8051.uc >/dev/null
