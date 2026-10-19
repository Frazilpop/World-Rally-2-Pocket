#!/bin/sh
# World Rally 2 for Analogue Pocket — build the bitstream.
#
#   pocket/build.sh            build
#   pocket/build.sh --clean    empty db/ and incremental_db/ first, so smart
#                              recompilation cannot skip a stage
#
# Runs Quartus Prime Lite 21.1 in Docker (raetro/quartus:21.1, linux/amd64),
# here under Colima with Rosetta. The WHOLE repository is mounted, because the
# project in pocket/src/fpga reaches ../../../rtl, ../../../third_party and
# ../../../build/gen. Colima shares $HOME only — a checkout under /tmp would
# mount as empty.
#
# Before Quartus, on the Mac: jt8051's microcode (tools/gen_jt8051.sh, which
# needs Go, not in the Docker image) and the GAE1's volume table
# (tools/gen_volume_table.py) are made into build/gen, and the files the RTL
# reads with $readmem relative to the project directory -- jt8051.uc,
# volume_table.mem and fx68k's microrom.mem and nanorom.mem -- are copied
# next to ap_core.qpf (gitignored).
#
# Generated files stay under build/ (the repo's rule): db/, incremental_db/
# and output_files/ in the project directory are symlinks into
# build/pocket/quartus/, made here on first use. The one exception is Analogue's
# own pre-flow script, which writes apf/build_id.mif with the build date at the
# start of every compile; it is ignored, not tracked, so a build leaves the
# tree clean.
#
# Afterwards: the fit, the RAM blocks by instance and the worst slack per
# clock are printed, and only if every clock meets timing is the
# bit-reversed bitstream the Pocket loads written to
# pocket/dist/Cores/frazilpop.World Rally 2/bitstream.rbf_r. On negative slack
# the script fails and leaves dist alone; the bitstream it made is kept as
# build/pocket/quartus/bitstream.rbf_r.failed for a look.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
fpga=$repo/pocket/src/fpga
qb=$repo/build/pocket/quartus
dist="$repo/pocket/dist/Cores/frazilpop.World Rally 2"
image=raetro/quartus:21.1

clean=0
for arg in "$@"; do
    case "$arg" in
        --clean) clean=1 ;;
        -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
        *) echo "build.sh: unknown argument '$arg'" >&2; exit 2 ;;
    esac
done

case "$repo" in
    "$HOME"/*) ;;
    *) echo "build.sh: the repository must be under \$HOME ($HOME); Colima shares nothing else." >&2
       exit 1 ;;
esac

for f in "$repo/third_party/pocket-utils/ip/data_loader.sv" "$repo/third_party/jtcores/modules/jt8051/hdl/jt8051.v" \
         "$repo/third_party/fx68k/hdl/fx68k.sv"; do
    [ -f "$f" ] || { echo "build.sh: missing $f (run tools/bootstrap.sh?)" >&2; exit 1; }
done

# ------------------------------------------------------------ one at a time
# Two Quartus runs in one project write the same db/ and the same log, and
# neither finishes cleanly. More than one thing can start this script, so it
# takes a lock (mkdir is atomic) and refuses while another build holds it. A
# lock left by a killed build is cleared once its pid is gone.
lock=$repo/build/pocket/build.lock
mkdir -p "$repo/build/pocket"
if ! mkdir "$lock" 2>/dev/null; then
    other=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
        echo "build.sh: another build is running (pid $other); not starting a second." >&2
        exit 1
    fi
    rm -rf "$lock"; mkdir "$lock"
fi
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT INT TERM

# ------------------------------------------- generated sources -> build/gen
gen=$repo/build/gen
j8=$repo/third_party/jtcores/modules/jt8051
mkdir -p "$gen"
if [ ! -f "$gen/jt8051/jt8051.vh" ] || [ "$j8/ucode/8051.yaml" -nt "$gen/jt8051/jt8051.vh" ]; then
    echo "== jt8051 microcode (tools/gen_jt8051.sh)"
    "$repo/tools/gen_jt8051.sh" "$gen/jt8051" > "$repo/build/pocket/gen_jt8051.log" 2>&1 || {
        echo "build.sh: tools/gen_jt8051.sh failed; see build/pocket/gen_jt8051.log" >&2; exit 1; }
fi
[ -f "$gen/volume_table.mem" ] || python3 -I "$repo/tools/gen_volume_table.py" "$gen/volume_table.mem"
for f in "$gen/jt8051/jt8051.uc" "$gen/volume_table.mem" \
         "$repo/third_party/fx68k/hdl/microrom.mem" "$repo/third_party/fx68k/hdl/nanorom.mem"; do
    cmp -s "$f" "$fpga/$(basename "$f")" || cp "$f" "$fpga/"
done

# ---------------------------------------------------- generated -> build/
mkdir -p "$qb/db" "$qb/incremental_db" "$qb/output_files"
for d in db incremental_db output_files; do
    if [ -L "$fpga/$d" ]; then
        :
    elif [ -e "$fpga/$d" ]; then
        echo "build.sh: $fpga/$d is a real directory; move it aside so it can be a link into build/." >&2
        exit 1
    else
        # Relative, so it resolves the same inside the container (/build/...).
        ln -s "../../../build/pocket/quartus/$d" "$fpga/$d"
    fi
done

if [ "$clean" = 1 ]; then
    echo "== clean: emptying $qb/db and $qb/incremental_db"
    find "$qb/db" "$qb/incremental_db" -mindepth 1 -delete
fi

log=$qb/compile.log
echo "== Quartus 21.1 ($image)"
echo "   log: $log"
start=$(date +%s)
if ! docker run --rm --platform linux/amd64 \
        -v "$repo":/build -w /build/pocket/src/fpga \
        "$image" quartus_sh --flow compile ap_core > "$log" 2>&1; then
    echo "== COMPILE FAILED"
    grep -E "^Error|^ *Error \(" "$log" | head -40
    exit 1
fi
echo "   compiled in $(( $(date +%s) - start )) s"

# Critical warnings are worth a look every time; they are where a wrong pin or
# an ignored constraint shows up.
crit=$(grep -c "^Critical Warning" "$log" || true)
if [ "$crit" != "0" ]; then
    echo "== $crit critical warning(s):"
    grep "^Critical Warning" "$log" | sort -u | head -20
fi

# ------------------------------------------------------------- bitstream
rbf=$qb/output_files/ap_core.rbf
[ -f "$rbf" ] || { echo "build.sh: no $rbf" >&2; exit 1; }
rbf_r=$qb/bitstream.rbf_r.new
python3 -I - "$rbf" "$rbf_r" <<'EOF'
import sys
# APF wants every byte of the .rbf bit-reversed (Analogue: Packaging a Core).
src, dst = sys.argv[1], sys.argv[2]
table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
data = open(src, "rb").read()
open(dst, "wb").write(data.translate(table))
print(f"== bitstream: {len(data)} bytes")
EOF

# ------------------------------------------------------------- reports
status=0
python3 -I - "$qb/output_files" <<'EOF' || status=$?
import os, re, sys
out = sys.argv[1]

fit = open(os.path.join(out, "ap_core.fit.summary")).read()
print("== fit (5CEBA4F23C8)")
for key in ("Logic utilization (in ALMs)", "Total registers", "Total pins",
            "Total block memory bits", "Total RAM Blocks", "Total DSP Blocks",
            "Total PLLs"):
    m = re.search(re.escape(key) + r"\s*:\s*(.+)", fit)
    if m:
        print(f"   {key:<28} {m.group(1).strip()}")

# M10K blocks by memory, so a RAM that came out as logic, or twice, shows.
rpt = open(os.path.join(out, "ap_core.fit.rpt"), encoding="latin-1").read()
if "; Fitter RAM Summary" in rpt:
    hdr, rows = None, []
    for l in rpt[rpt.index("; Fitter RAM Summary"):].split("\n")[1:]:
        if l.startswith("; Name"):
            hdr = [c.strip() for c in l.split(";")]
        elif hdr and l.startswith(";"):
            rows.append(dict(zip(hdr, [c.strip() for c in l.split(";")])))
        elif hdr and not l.startswith("+"):
            break
    k = next(h for h in hdr if "M10K" in h)
    groups = {}
    for r in rows:
        path, _, ram = r["Name"].partition("|altsyncram:")
        path = re.sub(r"\w+:", "", path.split("|altshift_taps:")[0].split("|dcfifo:")[0])
        path = path.replace("ic|u_board|", "").replace("ic|", "")
        ram = re.sub(r"(_rtl_\d+|__\d+|\[\d+\])", "", ram.split("|")[0])
        n = re.sub(r"\[\d+\]", "[*]", re.sub(r"\|u_(hi|lo)$", "", path)) + " " + ram
        groups[n] = groups.get(n, 0) + int(r[k] or 0)
    print("   M10K by memory:")
    for n, b in sorted(groups.items(), key=lambda x: -x[1]):
        if b >= 4:
            print(f"     {b:4}  {n}")
    print(f"     {sum(b for b in groups.values() if b < 4):4}  the rest")

sta = open(os.path.join(out, "ap_core.sta.summary")).read()
worst = {}
for typ, slack in re.findall(r"Type\s*:\s*(.+?)\nSlack\s*:\s*(-?[\d.]+)", sta):
    m = re.match(r"(.+?) Model (Setup|Hold|Recovery|Removal|Minimum Pulse Width) '(.+)'", typ)
    if not m:
        continue
    corner, kind, clk = m.groups()
    k = (clk, kind)
    s = float(slack)
    if k not in worst or s < worst[k][0]:
        worst[k] = (s, corner)

names = {
    "general[0]": "clk_core 48",
    "general[1]": "clk_sdram 96",
    "general[2]": "clk_sdram_ps 96/180",
    "general[3]": "clk_vid 8",
    "general[4]": "clk_vid90 8/90",
}
def label(clk):
    for k, v in names.items():
        if k in clk:
            return v
    return clk

print("== timing: worst slack per clock over all corners (ns)")
fail = False
for clk in sorted({c for c, _ in worst}, key=label):
    row = []
    for kind in ("Setup", "Hold", "Recovery", "Removal"):
        if (clk, kind) in worst:
            s, corner = worst[(clk, kind)]
            row.append(f"{kind.lower()} {s:+.3f}")
            if s < 0:
                fail = True
    if row:
        print(f"   {label(clk):<22} " + "  ".join(row))
if fail:
    print("== NEGATIVE SLACK: timing is not met")
    sys.exit(1)
print("== timing met")
EOF

# ------------------------------------------------------------- dist
# A bitstream that misses timing never reaches dist, so deploy.sh cannot put
# it on the card.
if [ "$status" != 0 ]; then
    mv "$rbf_r" "$qb/bitstream.rbf_r.failed"
    echo "== bitstream NOT written to dist" >&2
    exit 1
fi
mkdir -p "$dist"
mv "$rbf_r" "$dist/bitstream.rbf_r"
echo "== written: $dist/bitstream.rbf_r"
