# Third-party code and licences

This core is **GPL-3.0-only** as a whole, because jlrh's World Rally 2 core
and alphanu1's `kaneko_sdram_x2.sv` are (see below). This file lists each
dependency and what its licence asks for.

## Fetched by `tools/bootstrap.sh`

These land in `third_party/`, pinned in `deps.lock`, and are never committed.

| Component | Licence | Used for |
|---|---|---|
| [jlrh/gaelco-fpga](https://github.com/jlrh/gaelco-fpga) (`cores/wrally2`) | GPL-3.0 | The board, imported into `rtl/` (see *In the tree*); the clone is kept to compare against |
| [jotego/jtcores](https://github.com/jotego/jtcores) (`modules/jt8051`, `modules/jtframe` in part) | GPL-3.0-or-later | jt8051, the DS5002FP; jtframe's RAM blocks; jtframe's `ucode` tool, which expands jt8051's microcode at build time |
| [jotego/jtcores](https://github.com/jotego/jtcores) at `e5ac19e` (`modules/jtframe/hdl/cpu/8051` only) | LGPL-2.1-or-later | Oregano Systems' mc8051 VHDL, the source of `rtl/mcu/mc8051_regen.v`; for reference |
| [jtfpga/fx68k](https://github.com/jtfpga/fx68k) | GPL-3.0-or-later | The 68000 main CPU |
| [agg23/analogue-pocket-utils](https://github.com/agg23/analogue-pocket-utils) | MIT | Pocket shell IP: data loader, sync FIFO, I2S audio |
| [mamedev/mame](https://github.com/mamedev/mame) (`src/mame/gaelco/gaelco2*`, `gaelco_ds5002fp.*`, `src/devices/sound/gaelco.*`, and the 8051, 68000, latch, tilemap and screen sources beside them) | BSD-3-Clause (the Gaelco files) | The reference |

### jt8051 and jtframe – GPL-3.0-or-later
© Jose Tejada Gomez. The six `modules/jt8051/hdl/` files are the DS5002FP's
CPU in the bitstream, and `jtframe_dual_ram.v`, `jtframe_ram.v` and
`jtframe_ram_rst.v` hold the board's shared RAM and the 8051's internal RAM.
jt8051's microcode is `ucode/8051.yaml`, which `tools/gen_jt8051.sh` expands
with jtframe's own `ucode` tool (Go, built from the clone) into
`build/gen/jt8051/` at build time; nothing it makes is committed. The
or-later clause is in each file's header – re-read it after every
`bootstrap.sh --update`.

### fx68k – GPL-3.0-or-later
`deps.lock` pins `jtfpga/fx68k`, which is ijor's code repackaged for jtframe:
`hdl/` is the synthesis code, and the simulation takes its
`hdl/verilator/` variant, which Verilator can compile. The or-later terms
are in its `fx68k.txt`. The bootstrap symlinks `microrom.mem` and
`nanorom.mem` into the repo root, where fx68k loads them from.

### analogue-pocket-utils – MIT
© 2022 Adam Gastineau. `data_loader.sv`, `sync_fifo.sv` and `sound_i2s.sv`
are used as they are. Keep the notice.

### MAME – BSD-3-Clause (these files only)
The Gaelco files are BSD-3-Clause, © Manuel Abadia and David Haywood –
`gaelco2.cpp`, `gaelco2_m.cpp` and `gaelco2_v.cpp` (board, memory map, video),
`gaelco_ds5002fp.cpp` and the GAE1's `sound/gaelco.cpp`. They are the only
public documentation of these chips, and MAME running them is the oracle
the core is checked against (`tools/pocket/README.md`). Written from them:
`tools/pocket/build_rom.py`'s chip list (names, sizes, CRC32 and SHA-1, in
`ROM_START`'s order) and its split of wrally2a's mask ROMs, as
`init_wrally2` does; `tools/gen_volume_table.py`, which writes the GAE1's
volume table from the formula in `sound/gaelco.cpp`; and
`tools/pocket/render_dump.py`, which draws a screen as `gaelco2_v.cpp` does.

MAME as a whole is GPL-2.0, and `src/devices/` and `src/emu/` are a mix, so
check each file's header before taking anything else.

## In the tree

### jlrh/gaelco-fpga – GPL-3.0
The World Rally 2 MiSTer core this is built on, imported from
`cores/wrally2/hdl` at `85fe58b`. The files carry no headers; the
repository is GPLv3 (its `LICENSE` and README). Unchanged:
`rtl/cpu/wrally2_addr_decode.v`, `rtl/io/wrally2_inputs.v`,
`rtl/video/wrally2_video_timing.v` and `rtl/mcu/mc8051_regen.v`. Changed for
this core, between 18 and 20 Oct 2026 (the git history has each change):

- `rtl/cpu/wrally2_main.v` – the 68000 on board time, its program from an
  SDRAM line port, the work RAM in the Pocket's SRAM, IRQ 6 kept on vblank;
- `rtl/io/wrally2_adc.v` – the wheel's reading loaded at reset, as MAME's
  latch does;
- `rtl/mcu/wrally2_mcu.v` – jt8051 as the DS5002FP (`WR2_JT8051`), mc8051
  kept as the other choice;
- `rtl/mem/wrally2_vmem.v` – rewritten for one screen: one VRAM in four
  word banks, the sprite buffer and its copy, one palette;
- `rtl/sound/wrally2_gae1_sound.v` – on board time, MAME's bank offsets,
  both outputs out of the board;
- `rtl/video/wrally2_gae1_palette.v`, `wrally2_gae1_sprite.v`,
  `wrally2_gae1_tilemap.v`, `wrally2_gae1_video.v` and
  `wrally2_video_top.v` – cut to the left screen, 64-bit fetch lines, 8-bit
  colour, the sprite engine at 48 MHz with its line buffers in block RAM,
  and the sprite list taken at vblank.

Not imported: jlrh's copy of fx68k (fetched instead), `jtframe_ram_rst.v`
(fetched from jtcores), `jtwrally2_game.v` (replaced by
`rtl/top/wrally2_board.sv`), `wrally2_68kdtack.v` (replaced by
`rtl/cpu/wrally2_cpu_clk.sv`) and `wrally2_dbg_uart.v`.

### Oregano Systems' mc8051 – LGPL-2.1-or-later
`rtl/mcu/mc8051_regen.v`, from jlrh's core unchanged, is GHDL's Verilog of
Oregano Systems' mc8051 VHDL as jtframe carried it
(`jotego/jtcores` at `e5ac19e`, `modules/jtframe/hdl/cpu/8051`), and
`rtl/mcu/LGPL.TXT` beside it is its licence. It isn't in the Pocket's
bitstream: only the simulation builds it, with `MCU=mc8051`. The LGPL lets
it be conveyed under the GPL (its section 3).

### alphanu1's SDRAM controller – GPL-3.0-or-later and GPL-3.0-only
`rtl/mem/kaneko_sdram.sv` (GPL-3.0-or-later), `rtl/mem/kaneko_sdram_x2.sv`
(GPL-3.0-only) and `sim/mem/sdram_model.sv` (GPL-3.0-or-later), © 2026
alphanu1, are from alphanu1's
[Kaneko16 MiSTer core](https://github.com/alphanu1/kaneko16-mister), by way of
[Great 1000 Miles Rally for the Analogue Pocket](https://github.com/Frazilpop/Great-1000-Miles-Rally-Pocket),
unchanged. The controller follows meathax's System 32 controller
(GPL-3.0) – keep that note in the file. `tools/diff_bus_trace.py` and
`tools/pocket/match_frames.py` follow that core's tools of the same names.

### Analogue openFPGA core template – Analogue's APF Software License Agreement
`pocket/src/fpga/apf/`, `core_bridge_cmd.v` and the Quartus project files are
Analogue's, under the licence in their headers (with Analogue's Pocket EULA),
which yields to the MIT or GNU licence wherever the two disagree. The
Quartus megafunction output beside them (`mf_pllbase`, `pin_ddio_clk`,
`mf_datatable`, `mf_ddio_bidir_12`) is Intel's generated code, and
`build_id_gen.tcl` is Altera's reference design (Altera Reference Design
License), trimmed by Analogue.

## Written for this core

Everything else under `rtl/`, `sim/`, `tools/` and `pocket/`, under the
licence in each file's header (GPL-3.0-or-later; the combination is
GPL-3.0-only). The Pocket shell in `pocket/src/fpga/core/` started from
Great 1000 Miles Rally for the Analogue Pocket's, by the same author.

`pocket/art/wrally2-banner.png`, the platform image, is made from the game's
logo, © Gaelco.

## ROMs

No ROM images, or anything taken from them, are ever committed or distributed.
They're loaded at runtime, and tools that read them write only to `build/`.
