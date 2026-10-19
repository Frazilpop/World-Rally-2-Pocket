#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# World Rally 2 (Pocket): tools/mame_wrally2_inputs.lua's INPUTS schedule as
# the harness's --inputs plan, so the two run the same drive.
#
#   python3 -I tools/wrally2_inputs_plan.py race <frames> > build/sim/race.txt
#
# One line a frame where something changes, "<frame> coin=1 start=0 ...":
# the Lua script sets frame n's inputs in MAME's notifier n, seen from frame
# n's vblank on; the harness applies line n at its own vblank IRQ n.
import sys


def race(n):
    acc = (800 <= n < 1400 and n % 60 < 10) or n >= 1400
    return {
        "coin": int(600 <= n < 610),
        "start": int(700 <= n < 710),
        "b1": int(acc),                                    # P1 Acc.
        "left": int(n >= 1600 and n % 240 < 30),
        "right": int(n >= 1600 and 120 <= n % 240 < 150),
    }


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("none", "race"):
        sys.exit("usage: wrally2_inputs_plan.py none|race <frames>")
    mode, frames = sys.argv[1], int(sys.argv[2])
    prev = None
    print(f"# INPUTS={mode}, tools/mame_wrally2_inputs.lua's schedule")
    for n in range(0, frames + 1):
        cur = race(n) if mode == "race" else {k: 0 for k in race(0)}
        changed = {k: v for k, v in cur.items() if prev is None or prev[k] != v}
        if changed:
            print(n, " ".join(f"{k}={v}" for k, v in changed.items()))
        prev = cur


if __name__ == "__main__":
    main()
