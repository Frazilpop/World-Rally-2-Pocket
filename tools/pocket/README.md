# Pocket tools

These are the scripts that make the game files for the Analogue Pocket, and
the ones the core is checked against MAME with. The ROMs you supply are
written into `build/`. Run anything that opens the zips with `python3 -I` so
Python can't pick up stray files from the folder you're in.

## Making the `.rom` files

```sh
python3 -I tools/pocket/build_rom.py wrally2 ~/Downloads build/pocket     # one game
python3 -I tools/pocket/build_rom.py all     ~/Downloads build/pocket     # all games
python3 -I tools/pocket/verify_rom.py all                                 # verify against MAME
```

You can also give a list of ROM ids separated by commas, e.g. `wrally2,wrally2b`.

The core supports the following ROM ids: `wrally2`, `wrally2a`, `wrally2b`, `wrally2c` and `wrally2d`.

Each image is exactly 0x1200000 bytes (18 MB), laid out the way the core reads
it from SDRAM, with zeros in the gaps:

| at | size | what |
| --- | --- | --- |
| 0x0000000 | 1 MB | the 68000's program, MAME's `maincpu` region as it is |
| 0x0100000 | 32 KB | the DS5002FP's SRAM, its program and data (`gaelco_ds5002fp:sram`) |
| 0x0200000 | 16 MB | MAME's 10 MB `gfx` region, graphics and sound samples, as 64-bit fetch lines |

The `gfx` region is five 2 MB bit planes. The image keeps one 8-byte line for
each byte offset in a plane, holding that byte of all five planes, so a single
64-bit read gives the five planes of a run of eight pixels. The top of
`build_rom.py` has the exact layout.

The script finds each chip by its CRC32 and size, and will look through every
zip in the folder (the game's own zip and its parent's first), so merged, split
and non-merged sets all work. A `<rom id>/` folder of loose files works too.
The list of chips follows `ROM_START` in MAME's `gaelco2.cpp`, and every file's
SHA-1 is checked against MAME's before anything is written. wrally2a has three
mask ROMs where the others have fourteen EPROMs; the script splits them into
the `gfx` region as MAME's `init_wrally2` does, which makes it wrally2b's.

`verify_rom.py` runs MAME with `tools/mame_wrally2_regions.lua`, which saves
MAME's own copy of each region to `build/mame/regions/<rom id>/`, then compares
them with the image byte for byte (`--zipdir`, `--romdir` and `--mame` say
where things are; `--no-mame` reuses the dumps).

For the simulation, `--regions` writes one file per MAME region instead:

```sh
python3 -I tools/pocket/build_rom.py wrally2b ~/Downloads build/roms --regions
# build/roms/wrally2b_maincpu.bin, _ds5002.bin, _gfx.bin
```

## On the Analogue Pocket

Copy the image onto the SD card as

```
Assets/wrally2/common/<rom id>.rom        e.g. Assets/wrally2/common/wrally2.rom
```

Each game's instance JSON points at that file. The Pocket loads it at bridge
address 0, and byte *n* of the file ends up at SDRAM byte *n*.

## Checking against MAME

Everything from here on is for working on the core itself.

### `mame_oracle.sh`

Run the Lua scripts through `tools/pocket/mame_oracle.sh <script> <rom id>
[VAR=value ...] [-- mame args]`. It gives each run a fresh, empty nvram and cfg
folder: MAME keeps the DS5002FP's SRAM as NVRAM, saving it when it quits and
loading it in place of the ROM's when it starts, so otherwise every run would
start from whatever the last one left. It also adds the flags autoboot needs
(`-skip_gameinfo -autoboot_delay 0`) and `-snapview native`, so a snapshot is
one 384 × 240 screen rather than both side by side. `ROMS=` changes where it
looks for ROMs (`~/Downloads` by default) and `MAME=` changes which MAME it
runs.

Every script loads `tools/mame_wrally2_inputs.lua`, which sets the DIPs the
core holds – Monitors **One** (MAME's default is two) and the cabinet on
**Joystick** – with everything else at MAME's default. Its `INPUTS` is `none`
(power-on, then the attract) or `race`: a coin at frame 600, start at 700,
the accelerator tapped from 800 through the menus and held from 1400, and the
car steered left and right from 1600. Frame *N* is MAME's *N*th frame
notification from power-on.

### The harness

`sim/wrally2/` runs the whole board in Verilator, hosted the way the Pocket
shell hosts it, with the `.rom` image as its SDRAM:

```sh
sim/wrally2/build.sh                       # build/obj_wrally2/tb_wrally2
mkdir -p build/sim
python3 -I tools/wrally2_inputs_plan.py race 1800 > build/sim/race.txt
build/obj_wrally2/tb_wrally2 build/pocket/wrally2b.rom 1800 build/sim/race 600,1200 \
    --inputs build/sim/race.txt
```

That runs 1,800 frames, writes `frame_00600.ppm` and `frame_01200.ppm`, and a
line a frame to `stats.csv` (the sprite engine's longest line, lines cut
short, where IRQ 6 fell, the most board time owed). `wrally2_inputs_plan.py`
turns the Lua script's `INPUTS` schedule into the harness's plan file, so the
two drive the same race. The options are listed at the top of
`tb_wrally2.cpp`; `build.sh` takes `MCU=mc8051` for jlrh's DS5002FP instead of
jt8051, `SDR=real` to time the ROM reads with the shell's own SDRAM controller,
and `PIX=jlrh` for the Pocket's frame timing rather than MAME's.

### Tracing the bus from power-on

```sh
tools/pocket/mame_oracle.sh tools/mame_wrally2_bus_trace.lua wrally2b \
    BUS_TRACE_OUT=build/mame/wrally2b_bus.txt BUS_TRACE_COUNT=3000000
build/obj_wrally2/tb_wrally2 build/pocket/wrally2b.rom 70 build/sim/trace \
    --trace build/sim/wrally2b_bus.txt --trace-count 3000000
python3 -I tools/diff_bus_trace.py build/sim/wrally2b_bus.txt build/mame/wrally2b_bus.txt wrally2b
```

Each trace is a pair of files: the 68000's accesses, one a line (`addr R|W
data mask`, with `# frame N` lines between frames), and beside it, with
`.mcu` added, the DS5002FP's reads and writes of the RAM it shares with the
68000. `diff_bus_trace.py` compares every 68000 access in order, instruction
fetches included, then picks up again wherever the two took IRQ 6 an
instruction apart (fx68k and MAME's 68000 sample the interrupt at slightly
different points), and fails only on a difference that isn't that. On the
DS5002FP's side it compares every write and every read that saw a new value.
`BUS_TRACE_FROM=<frame>` (and the harness's `--trace-from`) starts a trace
later than power-on.

### Frames

```sh
tools/pocket/mame_oracle.sh tools/mame_wrally2_screens.lua wrally2b \
    SCREENS_DIR=build/mame/screens/wrally2b FROM=10 TO=600 STEP=10
build/obj_wrally2/tb_wrally2 build/pocket/wrally2b.rom 600 build/sim/attract $(seq -s, 10 10 600)
python3 -I tools/pocket/match_frames.py build/sim/attract build/mame/screens/wrally2b --same
python3 -I tools/pocket/ppm2png.py build/sim/attract/frame_00600.ppm
```

`mame_wrally2_screens.lua` writes MAME's left screen for each frame in the
range as `m<N>.png` (`RIGHT=1` adds the right one). `match_frames.py` says, for
each of the harness's frames, which of MAME's it matches best and how many
pixels differ, and with `--same` the count against MAME's frame of the same
number; 0 is pixel-exact. `ppm2png.py` turns the harness's frames into PNGs
to look at.

### What's on screen at a given frame

Once the game takes inputs, the harness and MAME part ways a little in time,
so a race is compared scene by scene instead:

```sh
tools/pocket/mame_oracle.sh tools/mame_wrally2_dump.lua wrally2b \
    DUMP_DIR=build/mame/dump/race DUMP_FRAME=1700,2400,3000 INPUTS=race
python3 -I tools/pocket/render_dump.py build/mame/dump/race/f01700 build/pocket/wrally2b.rom f1700.ppm
tools/pocket/match_scenes.sh build/pocket/wrally2b.rom build/mame/dump/race/f0*
```

`mame_wrally2_dump.lua` saves the board's video state at each frame – the
VRAM, the sprite buffer, the palette, the video registers, the RAMs and the
GAE1's registers – with MAME's own picture; the top of the script lists every
file and which picture each belongs to. `render_dump.py` draws a dump the way
MAME does, as a check on the dump itself (`--pixel X,Y` lists what is drawn
at one pixel). `match_scenes.sh` loads each dump into the harness's video
memories with the game stopped, draws it on the board and compares the
picture with MAME's, then prints the sprite engine's busiest line.

### Sound

```sh
tools/pocket/mame_oracle.sh tools/mame_wrally2_screens.lua wrally2b \
    SCREENS_DIR=build/mame/screens/race FROM=1800 TO=1800 INPUTS=race -- -wavwrite $PWD/build/mame/race.wav
build/obj_wrally2/tb_wrally2 build/pocket/wrally2b.rom 1800 build/sim/race \
    --inputs build/sim/race.txt --audio build/sim/race.s16
python3 -I tools/pocket/match_audio.py build/sim/race.s16 build/mame/race.wav --from 13
```

The harness's `--audio` writes the GAE1's two outputs at its own 7,812.5
samples a second. MAME sends the first to its right speaker and the second to
its left; with one screen the game plays everything on the second, which is
what the Pocket plays. MAME's WAV isn't in step with emulated time sample for
sample, so `match_audio.py` scores each second at the lag where the two agree
best: the correlation and both levels.

## Made at build time

- `tools/gen_volume_table.py` writes `build/gen/volume_table.mem`, the GAE1's
  volume table, from the formula in MAME's `sound/gaelco.cpp`.
- `tools/gen_jt8051.sh` expands jt8051's microcode into `build/gen/jt8051/`
  with jtframe's `ucode` tool, which it builds from `third_party/` the first
  time (you'll need Go).

`pocket/build.sh` and `sim/wrally2/build.sh` run both for you.

## Building the core

```sh
tools/bootstrap.sh            # the dependencies, into third_party/
sh pocket/build.sh            # Quartus Prime Lite 21.1 in Docker, about ten minutes
sh pocket/build.sh --clean    # the whole flow from an empty database
sh pocket/lint/lint.sh        # Verilator lint of the shell around the board
```

`pocket/build.sh` runs Quartus in Docker (here under Colima), prints the fit
and the worst slack of each clock, and writes the bitstream to
`pocket/dist/Cores/frazilpop.World Rally 2/bitstream.rbf_r` only if every
clock meets timing. `pocket/dist/` is then the SD card's layout, apart from the
ROM images.
