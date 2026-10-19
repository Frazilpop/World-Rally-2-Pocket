#!/usr/bin/env bash
# Build the whole-board harness. Run from the repository root.
#   sim/wrally2/build.sh [extra verilator args]
# PIX=jlrh builds the Pocket's frame (8 MHz, 59.19 Hz); the default stretches
# the frame and IRQ 6 to MAME's 59.1 Hz so a bus trace keeps its IRQs in step
# (IRQ_FIRST: 68000 clocks to the first one) and clocks the DS5002 as MAME
# does (MCU_TRIM, MCU_LAG: wrally2_board). MCU=mc8051 builds the DS5002
# as jlrh had it; the default is jt8051, whose microcode headers are made
# here with jtframe's ucode tool (Go) into build/gen/jt8051.
set -euo pipefail
JR=third_party/jtcores/modules/jtframe/hdl/ram
J8=third_party/jtcores/modules/jt8051
mkdir -p build/obj_wrally2 build/tmp build/gen
if [ "${MCU:-jt8051}" = jt8051 ]; then
  if [ ! -f build/gen/jt8051/jt8051.vh ] || [ $J8/ucode/8051.yaml -nt build/gen/jt8051/jt8051.vh ]; then
    tools/gen_jt8051.sh build/gen/jt8051
  fi
  cmp -s build/gen/jt8051/jt8051.uc build/gen/jt8051.uc || cp build/gen/jt8051/jt8051.uc build/gen/
  MCUSRC=(+define+WR2_JT8051 +incdir+build/gen/jt8051 $J8/hdl/jt8051.v $J8/hdl/jt8051_ctrl.v
          $J8/hdl/jt8051_regs.v $J8/hdl/jt8051_alu.v $J8/hdl/jt8051_periph.v $J8/hdl/jt8051_serial.v)
else
  MCUSRC=(rtl/mcu/mc8051_regen.v)
fi
export TMPDIR="$PWD/build/tmp"
# $readmemh files, read relative to where tb_wrally2 runs (--gen-dir)
[ -f build/gen/volume_table.mem ] || python3 -I tools/gen_volume_table.py build/gen/volume_table.mem
cmp -s third_party/fx68k/hdl/microrom.mem build/gen/microrom.mem || cp third_party/fx68k/hdl/microrom.mem build/gen/
cmp -s third_party/fx68k/hdl/nanorom.mem build/gen/nanorom.mem || cp third_party/fx68k/hdl/nanorom.mem build/gen/
if [ "${PIX:-mame}" = jlrh ]; then PIXG=(-GPIX_NUM=1 -GPIX_DEN=6)
else PIXG=(-GPIX_NUM=13002 -GPIX_DEN=78125 -GIRQ_NUM=${IRQ_NUM:-591} -GIRQ_DEN=${IRQ_DEN:-130000000} -GIRQ_FIRST=${IRQ_FIRST:-219966}
       -GMCU_TRIM=${MCU_TRIM:-1625000} -GMCU_LAG=${MCU_LAG:-18}); fi
verilator --cc --exe --build -j 0 -O3 --x-assign fast --x-initial 0 \
  -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
  --top-module wrally2_board --Mdir "${OBJ:-build/obj_wrally2}" -o tb_wrally2 \
  "${PIXG[@]}" -CFLAGS -O2 "$@" \
  rtl/top/wrally2_board.sv rtl/mem/wrally2_romport.sv \
  rtl/cpu/wrally2_main.v rtl/cpu/wrally2_addr_decode.v rtl/cpu/wrally2_cpu_clk.sv \
  rtl/io/wrally2_inputs.v rtl/io/wrally2_adc.v \
  rtl/mcu/wrally2_mcu.v "${MCUSRC[@]}" \
  rtl/mem/wrally2_vmem.v \
  rtl/video/wrally2_video_top.v rtl/video/wrally2_video_timing.v rtl/video/wrally2_gae1_video.v \
  rtl/video/wrally2_gae1_tilemap.v rtl/video/wrally2_gae1_sprite.v rtl/video/wrally2_gae1_palette.v \
  rtl/sound/wrally2_gae1_sound.v \
  $JR/jtframe_dual_ram.v $JR/jtframe_ram_rst.v $JR/jtframe_ram.v \
  third_party/fx68k/hdl/verilator/*.sv \
  sim/wrally2/tb_wrally2.cpp
