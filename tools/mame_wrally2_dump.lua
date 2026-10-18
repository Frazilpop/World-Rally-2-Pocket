-- SPDX-License-Identifier: GPL-3.0-or-later
-- World Rally 2 (Pocket): dump the board's video state at chosen frames,
-- with MAME's own picture of the left screen, as the oracle for the RTL.
--
--   tools/pocket/mame_oracle.sh tools/mame_wrally2_dump.lua wrally2b \
--       DUMP_DIR=build/mame/dump/wrally2b DUMP_FRAME=600,2400 INPUTS=race
--
-- Environment:
--   DUMP_DIR    output directory. One frame: files go straight in it. Several
--               (DUMP_FRAME=600,1800,...): one subdirectory f<NNNNN> each.
--   DUMP_FRAME  frame number(s), counted as MAME frame notifications from
--               power-on: frame 1 is the first picture MAME renders.
--   DUMP_SET    optional; checked against the running set.
--   INPUTS      none (default) | race, mame_wrally2_inputs.lua (which also
--               sets Monitors One and Cabinet 1 Joystick)
--
-- Files (16-bit data as little-endian u16 words, as Mille Miglia's dumps):
--   vram.bin          200000-20ffff, the live video RAM (tilemaps, scroll and
--                     linescroll tables, sprite lists), 32K words
--   vram_buffer.bin   the BUFFERED_SPRITERAM16 copy (m_buffered) as it stands
--                     at the dump: the live VRAM of frame N-1's vblank, which
--                     the sprites of picture N were drawn from (see below)
--   palette.bin       210000-211fff, 4096 xRGB 555 words
--   vregs.bin         218004-218009, the 3 video registers
--   extraram.bin      212000-213fff
--   workram.bin       fe0000-fe7fff
--   shareram.bin      fe8000-feffff, the 68000's words (the DS5002FP's bytes
--                     8000-ffff, big-endian within each word)
--   ds5002_sram.bin   the DS5002FP's 32 KB SRAM, bytes
--   sndregs.bin       the GAE1's 56 registers (202890-2028ff), the chip's copy
--   screen.png        MAME's picture of the left screen, 384 x 240
--                     (screen:snapshot of :lscreen, with -snapview native)
--   frame.json        frame numbers, time, the vregs, the scroll words
--
-- FRAME ALIGNMENT. Everything is captured in the frame notifier, which MAME
-- calls at the left screen's vblank_begin right after picture N was
-- rendered and before either CPU runs again. The tilemaps of picture N were
-- drawn from vram.bin, palette.bin and vregs.bin as dumped (one
-- screen_update a frame; nothing here forces a partial update). The sprites
-- (draw_sprites reads the list AND the cell pointers from the buffer) were
-- drawn from vram_buffer.bin: the right screen's vblank (vblank_copy_rising)
-- refreshes the buffer at the same instant as the left's, but after this
-- notifier – measured 18 Oct 2026, wrally2b: the buffer at frame 2401's
-- notifier equals the live VRAM at frame 2400's, and at 2400 it differs from
-- the live VRAM. So a picture's sprites are one frame behind its tilemaps.

local DIR = os.getenv("DUMP_DIR") or "."
local SET = os.getenv("DUMP_SET")
if DIR:sub(1, 1) ~= "/" then DIR = (os.getenv("PWD") or ".") .. "/" .. DIR end

local wr2 = dofile((os.getenv("WR2_TOOLS") or debug.getinfo(1, "S").source:match("^@(.*)/"))
                   .. "/mame_wrally2_inputs.lua")

local FRAMES, WANT = {}, {}
for s in (os.getenv("DUMP_FRAME") or "600"):gmatch("[^,]+") do
  local n = assert(tonumber(s), "bad DUMP_FRAME")
  FRAMES[#FRAMES + 1] = n; WANT[n] = true
end
table.sort(FRAMES)
local LAST = FRAMES[#FRAMES]

local mach    = manager.machine
local romname = emu.romname()
local KNOWN = { wrally2 = 1, wrally2a = 1, wrally2b = 1, wrally2c = 1, wrally2d = 1 }
assert(KNOWN[romname], "mame_wrally2_dump.lua is for World Rally 2, not " .. romname)
assert(not SET or SET == romname, "DUMP_SET=" .. tostring(SET) .. " but running " .. romname)

local space  = mach.devices[":maincpu"].spaces["program"]
local scr    = mach.screens[":lscreen"]
local shares = mach.memory.shares
local vram, pal, vregs = shares[":spriteram"], shares[":paletteram"], shares[":vregs"]
local shram, sram = shares[":shareram"], shares[":gaelco_ds5002fp:sram"]

local function item(tag, name)
  local idx = mach.devices[tag].items[name]
  assert(idx, "no save item " .. tag .. " " .. name)
  return emu.item(idx)
end
local it_buffered = item(":spriteram", "0/m_buffered")
local it_sndregs  = item(":gaelco", "0/m_sndregs")

-- ------------------------------------------------------------ writers
local outdir = DIR
local function words_le(get, n)
  local t, out = {}, {}
  for i = 0, n - 1 do
    local v = get(i)
    t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
    if #t >= 4096 then out[#out + 1] = table.concat(t); t = {} end
  end
  out[#out + 1] = table.concat(t)
  return table.concat(out)
end
local function write(name, data)
  local f = assert(io.open(outdir .. "/" .. name, "wb"))
  f:write(data); f:close()
end
local function share16(sh) return words_le(function(i) return sh:read_u16(i * 2) end, sh.size // 2) end
local function bus(base, bytes) return words_le(function(i) return space:read_u16(base + i * 2) end, bytes // 2) end
local function itm(it) return words_le(function(i) return it:read(i) end, it.count) end
local function bytes(sh)
  local t = {}
  for i = 0, sh.size - 1 do t[#t + 1] = string.char(sh:read_u8(i)) end
  return table.concat(t)
end

local function json_str(s) return '"' .. tostring(s):gsub('[%c"\\]', function(c)
  return string.format("\\u%04x", c:byte()) end) .. '"' end

local frame = 0

local function dump_frame(n)
  outdir = (#FRAMES > 1) and string.format("%s/f%05d", DIR, n) or DIR
  os.execute('mkdir -p "' .. outdir .. '"')

  local live, buf = share16(vram), itm(it_buffered)
  write("vram.bin", live)
  write("vram_buffer.bin", buf)
  write("palette.bin", share16(pal))
  write("vregs.bin", share16(vregs))
  write("extraram.bin", bus(0x212000, 0x2000))
  write("workram.bin", bus(0xfe0000, 0x8000))
  write("shareram.bin", share16(shram))
  write("ds5002_sram.bin", bytes(sram))
  write("sndregs.bin", itm(it_sndregs))
  local err = scr:snapshot(outdir .. "/screen.png")

  local f = assert(io.open(outdir .. "/frame.json", "w"))
  local function kv(k, v, last) f:write(string.format('  %s: %s%s\n', json_str(k), v, last and "" or ",")) end
  local function hex16(sh, off) return string.format('"%04x"', sh:read_u16(off)) end
  f:write("{\n")
  kv("set", json_str(romname))
  kv("inputs", json_str(wr2.mode))
  kv("frame", n)
  kv("lscreen_frame_number", scr:frame_number())
  kv("machine_time", string.format("%.9f", mach.time:as_double()))
  kv("captured_in", json_str("frame notifier N = the left screen's vblank_begin, right after picture N was rendered"))
  kv("vreg0", hex16(vregs, 0)); kv("vreg1", hex16(vregs, 2)); kv("vreg2", hex16(vregs, 4))
  kv("scroll0y", hex16(vram, 0x2800)); kv("scroll0x", hex16(vram, 0x2802))
  kv("scroll1y", hex16(vram, 0x2804)); kv("scroll1x", hex16(vram, 0x2806))
  kv("buffer_equals_live_vram", tostring(buf == live))
  kv("picture", json_str("screen.png = picture " .. n .. (err and (" (snapshot error " .. tostring(err) .. ")") or "")))
  kv("width", scr.width); kv("height", scr.height, true)
  f:write("}\n")
  f:close()
  print(string.format("dump: frame %d (lscreen frame %d) -> %s", n, scr:frame_number(), outdir))
end

_G.wr2_dump_frame_sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  wr2.frame(frame)
  if WANT[frame] then dump_frame(frame) end
  if frame >= LAST then mach:exit() end
end)
