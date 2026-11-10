![World Rally 2 banner](pocket/art/wrally2-banner.png)

# World Rally 2 for the Analogue Pocket

**Gaelco's 1995 rally racer, now on the Analogue Pocket!**

World Rally 2: Twin Racing is the sequel to Gaelco's World Rally. In the
arcade it ran on a cabinet with two screens side-by-side, but it arrives here
on Analogue Pocket as a one-player game on a single screen. The core supports
all five versions revisions.

## Supported ROMs

| ROM id | game | notes |
| --- | --- | --- |
| `wrally2` | World Rally 2: Twin Racing (version 20-07) | Final version (July 1995) |
| `wrally2a` | World Rally 2: Twin Racing (version 26-06, mask ROM version) | The June 26 version, with its graphics on mask ROMs |
| `wrally2b` | World Rally 2: Twin Racing (version 26-06) | The June 26 version |
| `wrally2c` | World Rally 2: Twin Racing (version 09-06, checksum 7BE1) | The June 9 version |
| `wrally2d` | World Rally 2: Twin Racing (version 09-06, checksum 50A2) | Another June 9 version. Its own sound ROMs have never been dumped, so it plays the later version's and some sounds are wrong |

## Installation

No game data comes with this core – you will need to supply your own MAME ROM
sets (`wrally2.zip`, plus the clones' zips if your sets are split).

### Make the game files

You can't just drag and drop your MAME files. The Analogue Pocket can't read
zips, and the core needs each game as one file with every chip in its correct
place. There's a script in the repository that puts this all together for you,
or you can use a tool like Pocket Updater.

1. Download this repository (**Code → Download ZIP**, then unzip it) or clone it. You'll need Python 3 to run the build script.
2. Put your MAME zips in a folder.
3. In a terminal, from the repository's folder, run the script with the ROM ids you want from the table above, separated by commas:

   ```sh
   python3 tools/pocket/build_rom.py wrally2,wrally2b ~/path/to/roms build/pocket
   ```

   So this will write `build/pocket/wrally2.rom` and `build/pocket/wrally2b.rom`. Use `all` instead for all five. The script finds the right chips in whatever zips you have, merged or split, and checks them against MAME's checksums.

[`tools/pocket/README.md`](tools/pocket/README.md) includes more info on this.

### Copy to the Pocket

1. Copy the `Cores`, `Platforms` and `Assets` folders from a release onto your Pocket's SD card.
2. Copy your `.rom` files into `Assets/wrally2/common/` – for example `Assets/wrally2/common/wrally2.rom`.
3. On the Pocket: openFPGA → Arcade → World Rally 2, and pick your rom (the other versions are under `_alternatives`).

## Controls

| Input | Action |
| --- | --- |
| D-pad | steer |
| A | accelerate |
| Select | insert coin |
| Start | start |

The Analogue Pocket menu has the usual **Display Mode** and **Controls**
entries, and opening it pauses the game. Under **Core Settings** there are
three options:

- **Test Mode** – the arcade cabinet's operator menu
- **Reset Game**
- **Diagnostic overlay** – probably best to ignore this

## Technical details

- The core recreates Gaelco's World Rally 2 board in hardware logic – the 68000, the DS5002FP security processor running the game's own code, and the GAE1 video and sound chip – built on [jlrh's World Rally 2 MiSTer core](https://github.com/jlrh/gaelco-fpga), with jotego's jt8051 as the DS5002FP and a Pocket shell.
- It's been checked against MAME in simulation – over 1.6 million moves of the game's main processor identical from power-on, and race scenes drawn pixel for pixel. The sound is the output the game uses with one screen, which MAME plays on its left speaker.
- To build it yourself: `tools/bootstrap.sh`, then `sh pocket/build.sh` (Quartus Prime Lite 21.1 in Docker, about ten minutes; Go is needed for the DS5002FP's microcode). The finished SD card layout can be found in `pocket/dist/`.

## Credits and licence

- **jlrh** – the World Rally 2 MiSTer core this is built on.
- **Jorge Cwik (ijor)** – fx68k, the 68000 processor.
- **Jose Tejada (jotego)** – jt8051, the DS5002FP, and jtframe's RAM blocks.
- **alphanu1** – the SDRAM controller, from the Kaneko16 MiSTer core.
- **agg23** – the Pocket utilities used for loading and audio.
- **Analogue** – the openFPGA core framework.
- **The MAME team** – whose work on Gaelco's boards was referenced.
- Pocket port by **Frazilpop**.

GPL-3.0-only. [`THIRD-PARTY.md`](THIRD-PARTY.md) lists every dependency and its
licence.

World Rally 2: Twin Racing is © Gaelco. This project contains no game data.
