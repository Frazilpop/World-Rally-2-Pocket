-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally 2 (Pocket): MAME's left-screen picture for every frame in a
-- range, as PNGs, with the oracle's DIPs and inputs
-- (tools/mame_wrally2_inputs.lua).
--   tools/pocket/mame_oracle.sh tools/mame_wrally2_screens.lua wrally2b \
--       SCREENS_DIR=build/mame/screens/wrally2b FROM=200 TO=700 STEP=1 INPUTS=race
-- Frame N is the Nth frame notification from power-on, as in
-- mame_wrally2_dump.lua; the picture is screen:snapshot() of :lscreen
-- (384 x 240), not pixels(), which lags a frame inside the notifier.
-- RIGHT=1 also writes the right screen as r<N>.png.
local DIR   = os.getenv("SCREENS_DIR") or "."
local FROM  = tonumber(os.getenv("FROM") or "1")
local TO    = tonumber(os.getenv("TO") or "600")
local STEP  = tonumber(os.getenv("STEP") or "1")
local RIGHT = (os.getenv("RIGHT") or "0") ~= "0"
local wr2   = dofile((os.getenv("WR2_TOOLS") or debug.getinfo(1, "S").source:match("^@(.*)/"))
                     .. "/mame_wrally2_inputs.lua")
local lscr, rscr = manager.machine.screens[":lscreen"], manager.machine.screens[":rscreen"]
local n = 0
_G.wr2_screens_notifier = emu.add_machine_frame_notifier(function()
  n = n + 1
  wr2.frame(n)
  if n >= FROM and n <= TO and ((n - FROM) % STEP) == 0 then
    lscr:snapshot(string.format("%s/m%05d.png", DIR, n))
    if RIGHT then rscr:snapshot(string.format("%s/r%05d.png", DIR, n)) end
  end
  if n % 300 == 0 then print(n .. " of " .. TO) end
  if n >= TO then manager.machine:exit() end
end)
