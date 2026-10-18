-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally 2 (Pocket): trace the 68000's first N bus accesses from
-- power-on, and the DS5002FP's shared-RAM accesses beside them, as the
-- oracle for the core's own trace.
--
--   tools/pocket/mame_oracle.sh tools/mame_wrally2_bus_trace.lua wrally2b \
--       BUS_TRACE_OUT=build/mame/wrally2b_bus.txt BUS_TRACE_COUNT=200000
--
-- 68000, BUS_TRACE_OUT, one access per line, the format of Mille Miglia's
-- trace (tools/diff_bus_trace.py reads it):
--     <addr:06x> <R|W> <data:04x> <mask:04x>
-- addr is the byte address of the 16-bit word (even), mask the lanes the
-- 68000 drove (ffff word, ff00 even byte, 00ff odd byte). Lines starting '#'
-- mark frame boundaries ("# frame N" = MAME's frame notification N, at the
-- left screen's vblank; 3 fields, so a 4-field reader skips them).
--
-- DS5002FP, BUS_TRACE_MCU_OUT (default BUS_TRACE_OUT .. ".mcu"), one MOVX
-- access to the shared RAM per line:
--     <n68k> <t13> <addr:05x> <R|W> <data:02x>
-- n68k is the number of 68000 accesses in BUS_TRACE_OUT before this one (so
-- the two files merge in order), t13 the machine time in 13 MHz clocks from
-- power-on, addr the DS5002's MOVX address: 08000-0ffff is the shared RAM,
-- byte k of it the 68000's byte fe8000 + k (big-endian: the even address is
-- the high byte of the 68000's word). With BUS_TRACE_MCU_SRAM=1 the MOVX
-- accesses to its own SRAM (the program, used as scratch; 10000-17fff, SRAM
-- byte addr - 0x10000) are logged too.
--
-- MAME runs the two CPUs in lockstep (set_perfect_quantum on the DS5002FP),
-- so the interleaving is as close as MAME gets to the board's: where the
-- core's handshake diverges, it shows here first.
--
-- Environment:
--   BUS_TRACE_OUT        output file (default wrally2_bus_trace.txt)
--   BUS_TRACE_COUNT      68000 accesses to record (default 200000)
--   BUS_TRACE_DATA_ONLY  1 = skip instruction fetches: tap only 100000-ffffff
--                        (everything but the program ROM). ~5x fewer Lua calls.
--   BUS_TRACE_MCU_OUT    the DS5002FP file (see above); "none" to skip it
--   BUS_TRACE_MCU_SRAM   1 = the DS5002FP's SRAM accesses too
--   INPUTS               none (default) | race, mame_wrally2_inputs.lua
--
-- FROM POWER-ON, NO SYNTHETIC RESET. With -autoboot_delay 0 the script runs at
-- machine time 0, before either CPU has executed a cycle, so the first two
-- accesses are the reset vector reads at 000000/000002 and every RAM holds
-- its power-on content (MAME zero-fills).
--
-- WHAT THIS BOARD RETURNS THAT A CORE MUST MATCH
--   300000-300007  IN0-IN3 (DIPs: Monitors One, Cabinet 1 Joystick, the rest
--           MAME's defaults); IN0/IN2 bit 6 is the TLC549's serial bit.
--   202890-2028ff  GAE1 sound registers, inside the VRAM window: reads return
--           the registers, which the chip itself rewrites as a channel plays.
--   fe8000-feffff  shared RAM, written by both CPUs.
--   IRQ 6 at the left screen's vblank, autovectored: the vector read at
--   000078. There is no IACK cycle on the program bus.
--
-- Taps and notifiers are GLOBALS: a local is collected and the callback stops
-- with no error. The files are streamed, so a crashed run keeps what it had.

local MAX  = tonumber(os.getenv("BUS_TRACE_COUNT") or "200000")
local OUT  = os.getenv("BUS_TRACE_OUT") or "wrally2_bus_trace.txt"
local MOUT = os.getenv("BUS_TRACE_MCU_OUT") or (OUT .. ".mcu")
local DATA_ONLY = (os.getenv("BUS_TRACE_DATA_ONLY") or "0") ~= "0"
local MCU_SRAM  = (os.getenv("BUS_TRACE_MCU_SRAM") or "0") ~= "0"

local wr2 = dofile((os.getenv("WR2_TOOLS") or debug.getinfo(1, "S").source:match("^@(.*)/"))
                   .. "/mame_wrally2_inputs.lua")

local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]
local romname = emu.romname()
local fmt = string.format

local fh = assert(io.open(OUT, "w"))
local mh = (MOUT ~= "none") and assert(io.open(MOUT, "w")) or nil
local n, nm, done, frames = 0, 0, false, 0
local t0 = os.clock()

local function record(rw, offset, data, mask)
  if done then return end
  n = n + 1
  fh:write(fmt("%06x %s %04x %04x\n", offset & 0xffffff, rw, data & 0xffff, mask & 0xffff))
  if (n & 0x3fff) == 0 then fh:flush() end
  if n >= MAX then done = true end
end

local function mcu_record(rw, addr, data)
  if done then return end
  nm = nm + 1
  mh:write(fmt("%d %d %05x %s %02x\n", n, math.floor(mach.time:as_double() * 13e6 + 0.5),
               addr, rw, data & 0xff))
  if (nm & 0x3fff) == 0 then mh:flush() end
end

print(fmt("bus trace: %s, script at machine time %.6f, PC %06x, %s",
          romname, mach.time:as_double(), cpu.state["PC"].value,
          DATA_ONLY and "data only" or "all accesses"))

local ranges = DATA_ONLY and { { 0x100000, 0xffffff } } or { { 0x000000, 0xffffff } }
_G.wr2_taps = {}
local function keep(t) _G.wr2_taps[#_G.wr2_taps + 1] = t end
for i, r in ipairs(ranges) do
  keep(space:install_read_tap(r[1], r[2], "wr2_bt_r" .. i,
    function(offset, data, mask) record("R", offset, data, mask) end))
  keep(space:install_write_tap(r[1], r[2], "wr2_bt_w" .. i,
    function(offset, data, mask) record("W", offset, data, mask) end))
end

if mh then
  -- the shared window through gaelco_ds5002fp's hostmem space (MOVX 8000-ffff)
  local host = mach.devices[":gaelco_ds5002fp"].spaces["hostmem"]
  keep(host:install_read_tap(0x8000, 0xffff, "wr2_mcu_r",
    function(offset, data, mask) mcu_record("R", offset, data) end))
  keep(host:install_write_tap(0x8000, 0xffff, "wr2_mcu_w",
    function(offset, data, mask) mcu_record("W", offset, data) end))
  if MCU_SRAM then
    local xdata = mach.devices[":gaelco_ds5002fp:mcu"].spaces["xdata"]
    keep(xdata:install_read_tap(0x10000, 0x17fff, "wr2_sram_r",
      function(offset, data, mask) mcu_record("R", offset, data) end))
    keep(xdata:install_write_tap(0x10000, 0x17fff, "wr2_sram_w",
      function(offset, data, mask) mcu_record("W", offset, data) end))
  end
end

-- Finishing happens here, never inside a tap: exiting from a tap tears the
-- machine down under the access in flight, and taps left installed keep
-- costing a Lua call per access after the limit.
_G.wr2_bt_frame = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  wr2.frame(frames)
  if not done then fh:write(fmt("# frame %d\n", frames)) end
  if done or frames > 20000 then
    for _, t in ipairs(_G.wr2_taps) do t:remove() end
    fh:flush(); fh:close()
    if mh then mh:flush(); mh:close() end
    print(fmt("bus trace: %d 68000 accesses, %d DS5002FP, in %d frames (%.3f s emulated), "
              .. "%.1f s CPU -> %s", n, nm, frames, mach.time:as_double(), os.clock() - t0, OUT))
    mach:exit()
  end
end)
