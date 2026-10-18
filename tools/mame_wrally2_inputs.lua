-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally 2 (Pocket): the DIPs and inputs every oracle script runs with,
-- loaded by tools/mame_wrally2_{bus_trace,dump,screens}.lua with dofile.
--
-- DIPs, set at machine time 0 before the program reads them:
--   Monitors (SW2:6)            One   (MAME's default is Two)
--   Cabinet 1 Control (SW2:4)   Joystick
-- Every other DIP stays at MAME's default: IN0 high byte 0xDD, IN1 0xFF.
-- This is what the core's DIP words hold.
--
-- INPUTS (environment):
--   none   (default) nothing pressed: power-on, then the attract
--   race   a coin at frame 600, start at 700, accelerate tapped from 800
--          (the menus take it as select) and held from 1400, steering left
--          and right from 1600 – the drive of the scoping runs
--
-- Frame n is the nth machine frame notification from power-on (frame 1 is
-- the first picture MAME renders); an input set in notifier n is seen by the
-- program from frame n's vblank on. The Verilator harness applies the same
-- schedule at the same vblanks.
--
-- Returns a table: wr2.frame(n) applies frame n's inputs (call it first in
-- the script's own frame notifier), wr2.mode is the INPUTS value.

local mach  = manager.machine
local ports = mach.ioport.ports
local function field(port, name)
  local f = ports[port] and ports[port].fields[name]
  assert(f, "mame_wrally2_inputs.lua: no field " .. port .. " " .. name)
  return f
end

field(":IN0", "Monitors").user_value = 0x0000
field(":IN0", "Cabinet 1 Control Configuration").user_value = 0x0800

local mode = os.getenv("INPUTS") or "none"
assert(mode == "none" or mode == "race", "INPUTS must be none or race, not " .. mode)

local P = {
  coin  = field(":IN2", "Coin 1"),
  start = field(":IN0", "1 Player Start"),
  acc   = field(":IN0", "P1 Acc."),
  left  = field(":IN0", "P1 Left"),
  right = field(":IN0", "P1 Right"),
}

local wr2 = { mode = mode }

function wr2.frame(n)
  if mode ~= "race" then return end
  P.coin:set_value((n >= 600 and n < 610) and 1 or 0)
  P.start:set_value((n >= 700 and n < 710) and 1 or 0)
  local acc = (n >= 800 and n < 1400 and (n % 60) < 10) or n >= 1400
  P.acc:set_value(acc and 1 or 0)
  P.left:set_value((n >= 1600 and (n % 240) < 30) and 1 or 0)
  P.right:set_value((n >= 1600 and (n % 240) >= 120 and (n % 240) < 150) and 1 or 0)
end

print(string.format("wrally2 inputs: Monitors One, Cabinet 1 Joystick, INPUTS=%s", mode))
return wr2
