// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally 2 (Pocket) — the board, Gaelco REF.950510.
//
// Platform-neutral: no pins, no framework. The Pocket shell (pocket/) and
// the simulation harness (sim/wrally2/) both host this module. It replaces
// jlrh's JTFRAME top (jtwrally2_game.v) and keeps what is under it as jlrh
// wrote it, but for the 68000's clock (wrally2_cpu_clk: board time, below)
// and the ADC's reset (wrally2_adc), both set by the bus trace against MAME:
//
//   MC68000 @ 13 MHz      wrally2_main: fx68k, the bus, work/extra/shared RAM
//   DS5002FP @ 13 MHz     wrally2_mcu (jt8051; mc8051 without WR2_JT8051)
//                         inside wrally2_main; its program here, filled
//                         from the ROM image
//   GAE1 video            wrally2_video_top, the left screen (index 0)
//   GAE1 sound            wrally2_gae1_sound, 7 channels; the right output
//
// SDRAM line ports (64-bit lines, INTERFACES.md): 0 the 68000's program,
// 1 tilemap 0, 2 sprites (the engine runs at 96 MHz), 3 sound. jlrh's
// fetchers ask for 32-bit words of his own layout – planes {2,3,0,1} of a
// tile row half, or plane 4 in every byte when address bit 21 is set – and
// both halves of that are one fetch line here, so the word is cut from it.

`timescale 1ns/1ps
`default_nettype none

module wrally2_board #(
    parameter int unsigned SDR_AW  = 25,
    parameter int unsigned NP      = 4,
    // Pixel clock = clk * PIX_NUM / PIX_DEN. 1/6 is jlrh's 8 MHz, a
    // 512 x 264 frame at 59.19 Hz. The harness sets 13002/78125 to stretch
    // the same frame to MAME's 59.1 Hz, so its IRQs fall where MAME's do.
    parameter int unsigned PIX_NUM = 1,
    parameter int unsigned PIX_DEN = 6,
    // IRQ 6 every IRQ_DEN / IRQ_NUM 68000 clocks of board time, the first
    // IRQ_FIRST clocks after reset. 1/219648 is the video frame above
    // (811,008 clocks at 48 MHz); MAME's 59.1 Hz is 591/130000000.
    parameter int unsigned IRQ_NUM   = 1,
    parameter int unsigned IRQ_DEN   = 219648,
    parameter int unsigned IRQ_FIRST = 219648,
    // The DS5002 as MAME clocks it (the harness; 0 on the Pocket, as the
    // chip is). MCU_TRIM: one clock more every MCU_TRIM ticks -- MAME's mcs51
    // rounds 13 MHz / 12 up to 1,083,334 machine cycles a second, so its
    // DS5002 gains a clock every 1,625,000. MCU_LAG: ticks it sits out after
    // reset, standing in for MAME's interleave, which runs the 68000 first in
    // each slice of one DS5002 machine cycle (12 ticks), so its DS5002 sees
    // the 68000's writes some ticks late.
    parameter int unsigned MCU_TRIM = 0,
    parameter int unsigned MCU_LAG  = 0
)(
    input  wire        clk,            // 48 MHz
    input  wire        clk96,          // 96 MHz, same PLL: the sprite engine
    input  wire        rst,            // core reset; the board adds !rom_loaded

    // ROM read ports (SDRAM controller, slow side)
    output wire [NP-1:0]             rom_req,
    output wire [NP-1:0][SDR_AW:1]   rom_addr,
    input  wire [NP-1:0]             rom_ack,
    input  wire [NP-1:0][63:0]       rom_dout,

    // Loader snoop: the DS5002FP's SRAM image (bytes 0x100000-0x107fff).
    // dl_wr no more often than every other clock (each word is two byte
    // writes into jlrh's scratch RAM).
    input  wire        dl_wr,
    input  wire [24:1] dl_addr,
    input  wire [15:0] dl_data,
    input  wire        rom_loaded,

    // Video, the left screen: 384 x 240 of a 512 x 264 frame
    output wire        ce_pix,
    output wire        hs, vs, hblank, vblank,
    output wire [4:0]  r, g, b,

    // Audio: the GAE1's right output (cabinet 1), 7812.5 Hz
    output wire signed [15:0] snd,
    output wire        snd_sample,

    // Inputs, active high. p1/p2 = {b2, b1, up, down, left, right}.
    input  wire [5:0]  p1, p2,
    input  wire [1:0]  coin, start,
    input  wire        service, test,
    // {DSW2, DSW1}: DSW2 is IN0's high byte, DSW1 IN1's (MAME's bit order)
    input  wire [15:0] dsw,
    // The TLC549s' readings (Pot Wheel cabinets)
    input  wire [7:0]  wheel1, wheel2,

    // Freezes the game: board time stops (no credit, no ticks), so the
    // 68000, the DS5002 and IRQ 6 stand still. Video keeps running.
    input  wire        pause
);

// SDRAM regions, word addresses
localparam [SDR_AW:1] W_MAINCPU = SDR_AW'(25'h0000000);
localparam [24:1]     W_DS5002  = 24'h080000;              // byte 0x0100000
localparam [SDR_AW:1] W_GFX     = SDR_AW'(25'h0100000);    // byte 0x0200000

// ================================================================ resets
wire cpu_rst = rst | ~rom_loaded;

// ================================================================ clocks
reg [31:0] pix_acc = 32'd0;
reg        ce_pix_r = 1'b0;
always @(posedge clk) begin
    if (pix_acc + PIX_NUM >= PIX_DEN) begin
        pix_acc  <= pix_acc + PIX_NUM - PIX_DEN;
        ce_pix_r <= 1'b1;
    end else begin
        pix_acc  <= pix_acc + PIX_NUM;
        ce_pix_r <= 1'b0;
    end
end
assign ce_pix = ce_pix_r;

// Board time: one tick per 68000 clock (wrally2_cpu_clk), 13 MHz on
// average. The DS5002FP shares the 68000's 13 MHz crystal, so it takes one
// clock a tick (twelve to its machine cycle: jt8051 counts them itself,
// mc8051 behind wrally2_mcu's divider), and
// IRQ 6 is counted in ticks: the CPUs and the interrupt keep MAME's
// lockstep whatever the SDRAM does. (jlrh: 12 MHz, or 13/48 behind
// WR2_CEN_FRAC, from the 48 MHz clock; the IRQ from the video timing.)
wire cpu_tick;
// The GAE1 counts its samples in ticks too, and holds board time while it
// computes one (wrally2_gae1_sound, TICKDIV): the 68000 reads the channels'
// positions, so they must move when MAME's do.
wire snd_busy;

// Clocks the DS5002 is owed beyond the ticks (MCU_TRIM): each is given with
// board time held, on a clock with no tick or other enable on either side
// (jt8051 never takes adjacent ones). MCU_LAG: the ticks it misses at reset.
reg  [7:0]  mcu_owed  = 8'd0;
reg  [7:0]  mcu_lag   = 8'd0;
reg  [20:0] mcu_trimc = 21'd0;
reg         mcu_extra = 1'b0;
wire        mcu_due   = MCU_TRIM != 0 && cpu_tick && mcu_trimc == MCU_TRIM - 1;
wire        mcu_fire  = mcu_owed != 8'd0 && !cpu_tick && !mcu_extra;
always @(posedge clk) begin
    if (cpu_rst) begin
        mcu_owed <= 8'd0; mcu_lag <= MCU_LAG[7:0]; mcu_trimc <= 21'd0; mcu_extra <= 1'b0;
    end else begin
        if (MCU_TRIM != 0 && cpu_tick) mcu_trimc <= mcu_due ? 21'd0 : mcu_trimc + 21'd1;
        if (cpu_tick && mcu_lag != 8'd0) mcu_lag <= mcu_lag - 8'd1;
        mcu_owed  <= mcu_owed + {7'd0, mcu_due} - {7'd0, mcu_fire};
        mcu_extra <= mcu_fire;
    end
end
wire mcu_cen  = (cpu_tick & mcu_lag == 8'd0) | mcu_extra;
wire cpu_hold = snd_busy | mcu_owed != 8'd0 | mcu_extra;

// board_irq is the tick's own clock, not a register after it: wrally2_main
// takes it to IPL in two clocks, so IPL always changes after this tick's phi2
// and before the next phi1, whether the CPU is running at 13 MHz or catching
// up at 24. A clock later and that would depend on the SDRAM.
reg  [31:0] irq_acc, irq_first;
reg         irq_run;
wire        irq_wrap  = irq_acc + IRQ_NUM >= IRQ_DEN;
wire        board_irq = cpu_tick && (irq_run ? irq_wrap : irq_first == 32'd1);
always @(posedge clk) begin
    if (cpu_rst) begin
        irq_first <= IRQ_FIRST; irq_run <= 1'b0; irq_acc <= 32'd0;
    end else if (cpu_tick) begin
        if (!irq_run) begin
            irq_first <= irq_first - 32'd1;
            if (irq_first == 32'd1) irq_run <= 1'b1;
        end else irq_acc <= irq_wrap ? irq_acc + IRQ_NUM - IRQ_DEN : irq_acc + IRQ_NUM;
    end
end

// ================================================================ inputs
wire [15:0] in0, in1, in2, in3;
wrally2_inputs u_inputs (
    .clk(clk),
    .dipsw(dsw),
    .joystick1(~p1), .joystick2(~p2),
    .coin(~coin), .start(~start),
    .service(~service), .test(~test),
    .port_in0(in0), .port_in1(in1), .port_in2(in2), .port_in3(in3)
);

// ================================================================ ROM ports
wire        main_cs, main_ok;
wire [19:1] main_addr;
wire [63:0] main_line;
wrally2_romport #(.AW(SDR_AW)) u_rp_main (
    .clk(clk), .rst(cpu_rst),
    .cs(main_cs), .line(W_MAINCPU + {main_addr[19:3], 2'b00}),
    .ok(main_ok), .data(main_line),
    .rom_req(rom_req[0]), .rom_addr(rom_addr[0]), .rom_ack(rom_ack[0]), .rom_dout(rom_dout[0])
);
// SDRAM words are {byte 2w+1, byte 2w}; the 68000's are big-endian
wire [15:0] main_sw   = main_line[16*main_addr[2:1] +: 16];
wire [15:0] main_data = {main_sw[7:0], main_sw[15:8]};

// jlrh's word at address a: a[21] = 0, planes {2,3,0,1} of row half
// a[20:0]; a[21] = 1, plane 4 of it in every byte. Fetch line o holds
// plane p in bits [8p+7:8p].
function automatic [SDR_AW:1] gfx_line(input [21:0] a);
    gfx_line = W_GFX + {a[20:0], 2'b00};
endfunction
function automatic [31:0] gfx_word(input [63:0] l, input a21);
    gfx_word = a21 ? {4{l[39:32]}} : {l[23:16], l[31:24], l[7:0], l[15:8]};
endfunction

wire [21:0] tm0_a;   wire tm0_ok;   wire [63:0] tm0_line;
wire [21:0] spr_ra;  wire spr_ok;   wire [63:0] spr_line;
wire [21:0] snd_ra;  wire snd_cs;   wire snd_ok;  wire [63:0] snd_line;

wrally2_romport #(.AW(SDR_AW)) u_rp_tm0 (
    .clk(clk), .rst(cpu_rst),
    .cs(1'b1), .line(gfx_line(tm0_a)), .ok(tm0_ok), .data(tm0_line),
    .rom_req(rom_req[1]), .rom_addr(rom_addr[1]), .rom_ack(rom_ack[1]), .rom_dout(rom_dout[1])
);
wrally2_romport #(.AW(SDR_AW)) u_rp_spr (
    .clk(clk), .rst(cpu_rst),
    .cs(1'b1), .line(gfx_line(spr_ra)), .ok(spr_ok), .data(spr_line),
    .rom_req(rom_req[2]), .rom_addr(rom_addr[2]), .rom_ack(rom_ack[2]), .rom_dout(rom_dout[2])
);
wrally2_romport #(.AW(SDR_AW)) u_rp_snd (
    .clk(clk), .rst(cpu_rst),
    .cs(snd_cs), .line(gfx_line(snd_ra)), .ok(snd_ok), .data(snd_line),
    .rom_req(rom_req[3]), .rom_addr(rom_addr[3]), .rom_ack(rom_ack[3]), .rom_dout(rom_dout[3])
);

// ================================================================ DS5002FP program
// jlrh's board reads the DS5002's code from a 32 KB PROM and its MOVX data
// from a separate copy (the scratch RAM in wrally2_main); both are filled
// from the image's ds5002 slot as the loader passes.
wire        dl_mcu = dl_wr && dl_addr >= W_DS5002 && dl_addr < W_DS5002 + 24'h4000;
wire [13:0] dl_mcu_w = dl_addr[14:1];

reg  [15:0] mcu_prog [0:16383];
wire [14:0] mcurom_addr;
wire        mcurom_en;      // jt8051 reads its PROM on cen only, mc8051 always
reg  [15:0] mcu_prog_q;
reg         mcu_prog_a0;
always @(posedge clk) begin
    if (dl_mcu) mcu_prog[dl_mcu_w] <= dl_data;
    if (mcurom_en) begin
        mcu_prog_q  <= mcu_prog[mcurom_addr[14:1]];
        mcu_prog_a0 <= mcurom_addr[0];
    end
end
wire [7:0] mcurom_data = mcu_prog_a0 ? mcu_prog_q[15:8] : mcu_prog_q[7:0];

// The scratch copy takes bytes: the low byte on the snoop's clock, the high
// byte on the next.
reg        scr_hi_pend = 1'b0;
reg [13:0] scr_hi_w;
reg [7:0]  scr_hi_d;
always @(posedge clk) begin
    scr_hi_pend <= dl_mcu;
    scr_hi_w    <= dl_mcu_w;
    scr_hi_d    <= dl_data[15:8];
end
wire        scr_dl_we   = dl_mcu | scr_hi_pend;
wire [14:0] scr_dl_addr = dl_mcu ? {dl_mcu_w, 1'b0} : {scr_hi_w, 1'b1};
wire [7:0]  scr_dl_data = dl_mcu ? dl_data[7:0] : scr_hi_d;

// ================================================================ main board
wire [15:0] vmem_addr; wire vmem_uds, vmem_lds, vmem_we;
wire        vmem_cs_vram, vmem_cs_pal;
wire [15:0] vmem_wdata;
wire [15:0] cpu_vram_rd, cpu_pal_rd;
wire [15:0] vreg0, vreg1, vreg2;
wire        sndreg_cs, sndreg_we; wire [15:0] snd_rdata;
wire        vblank_irq;

wrally2_main u_main (
    .clk(clk), .rst(cpu_rst), .game_run(~pause),
    .vblank_irq(board_irq),
    .prog_addr(main_addr), .prog_cs(main_cs), .prog_data(main_data), .prog_data_ok(main_ok),
    .in0(in0), .in1(in1), .in2(in2), .in3(in3),
    .paddle0(wheel1), .paddle1(wheel2),
    .flip_screen(),
    .vmem_addr(vmem_addr), .vmem_uds(vmem_uds), .vmem_lds(vmem_lds), .vmem_we(vmem_we),
    .vmem_cs_vram(vmem_cs_vram), .vmem_cs_pal(vmem_cs_pal),
    .vmem_wdata(vmem_wdata),
    .vmem_vram_rdata(cpu_vram_rd), .vmem_pal_rdata(cpu_pal_rd),
    .vreg0(vreg0), .vreg1(vreg1), .vreg2(vreg2),
    .sndreg_cs(sndreg_cs), .sndreg_we(sndreg_we), .snd_rdata(snd_rdata),
    .cpu_tick(cpu_tick), .cpu_hold(cpu_hold), .mcu_cen(mcu_cen), .mcurom_addr(mcurom_addr), .mcurom_en(mcurom_en), .mcurom_data(mcurom_data),
    .scr_dl_clk(clk), .scr_dl_addr(scr_dl_addr), .scr_dl_data(scr_dl_data), .scr_dl_we(scr_dl_we),
    .dbg_mcu_pcmax(), .dbg_mcu_fetch(), .dbg_mcuw(), .dbg_mcu_scrw(), .dbg_key()
);

// ================================================================ sound
wire signed [15:0] snd_l, snd_r;
wrally2_gae1_sound #(.TICKDIV(1664)) u_snd (
    .clk(clk), .rst(cpu_rst), .tick(cpu_tick), .busy(snd_busy),
    .cs_sound(sndreg_cs), .cpu_aw(vmem_addr[7:1]), .cpu_we(sndreg_we),
    .cpu_uds(vmem_uds), .cpu_lds(vmem_lds), .cpu_wdata(vmem_wdata), .cpu_rdata(snd_rdata),
    .rom_addr(snd_ra), .rom_cs(snd_cs), .rom_data(gfx_word(snd_line, snd_ra[21])), .rom_ok(snd_ok),
    .snd_l(snd_l), .snd_r(snd_r), .sample(snd_sample)
);
assign snd = snd_r;

// ================================================================ video
wire [13:0] tp0_idx, tp1_idx; wire [31:0] tp0_q, tp1_q;
wire [14:0] wrd_a;  wire [15:0] wrd_q;
wire [14:0] spr_a;  wire [15:0] spr_q;
wire [14:0] spr2_a; wire [15:0] spr2_q;
wire [11:0] pal_a;  wire [15:0] pal_q;
wrally2_vmem u_vmem (
    .clk(clk), .clk96(clk96),
    .cpu_addr(vmem_addr), .cpu_uds(vmem_uds), .cpu_lds(vmem_lds), .cpu_we(vmem_we),
    .cs_vram(vmem_cs_vram), .cs_pal(vmem_cs_pal),
    .cpu_wdata(vmem_wdata),
    .cpu_vram_rdata(cpu_vram_rd), .cpu_pal_rdata(cpu_pal_rd),
    .tp0_idx(tp0_idx), .tp0_q(tp0_q), .tp1_idx(tp1_idx), .tp1_q(tp1_q),
    .wrd_a(wrd_a), .wrd_q(wrd_q), .spr_a(spr_a), .spr_q(spr_q),
    .spr2_a(spr2_a), .spr2_q(spr2_q),
    .pal_a(pal_a), .pal_q(pal_q)
);

// The video's own vblank IRQ is left unused: IRQ 6 is board time's (above).
// Tilemap 1 and the second sprite engine belong to the right screen: their
// fetches are never answered, as in jlrh's one-screen modes.
wire [21:0] tm1_a, spr2_ra;
wrally2_video_top u_video (
    .clk(clk), .clk96(clk96), .rst(rst), .ce_pix(ce_pix),
    .index(1'b0), .twin(1'b0),
    .vreg0(vreg0), .vreg1(vreg1), .vreg2(vreg2),
    .tp0_idx(tp0_idx), .tp0_q(tp0_q), .tp1_idx(tp1_idx), .tp1_q(tp1_q),
    .wrd_a(wrd_a), .wrd_q(wrd_q), .spr_a(spr_a), .spr_q(spr_q),
    .spr2_a(spr2_a), .spr2_q(spr2_q), .pal_a(pal_a), .pal_q(pal_q),
    .rom_a0(tm0_a),  .gfx0_data(gfx_word(tm0_line, tm0_a[21])), .gfx0_ok(tm0_ok),
    .rom_a1(tm1_a),  .gfx1_data(32'd0), .gfx1_ok(1'b0),
    .rom_as(spr_ra), .gfxs_data(gfx_word(spr_line, spr_ra[21])), .gfxs_ok(spr_ok),
    .rom_as2(spr2_ra), .gfxs2_data(32'd0), .gfxs2_ok(1'b0),
    .vga_r(r), .vga_g(g), .vga_b(b),
    .hsync(hs), .vsync(vs), .hblank(hblank), .vblank(vblank), .de(),
    .vblank_irq(vblank_irq),
    .cpu_vwe(vmem_we & vmem_cs_vram), .cpu_vaddr(vmem_addr[14:0])
);

// ================================================================ harness probes
// Read by sim/wrally2/tb_wrally2.cpp for the bus traces; nothing uses them.
// Hierarchical, so Verilator only.
`ifdef VERILATOR
wire        dbg_as     /*verilator public_flat_rd*/ = ~u_main.ASn & ~(u_main.fc == 3'd7);
wire        dbg_rw     /*verilator public_flat_rd*/ = u_main.eRWn;
wire [23:1] dbg_eab    /*verilator public_flat_rd*/ = u_main.eab;
wire [15:0] dbg_dout   /*verilator public_flat_rd*/ = u_main.oEdb;
wire [15:0] dbg_din    /*verilator public_flat_rd*/ = u_main.iEdb;
wire [1:0]  dbg_ds     /*verilator public_flat_rd*/ = {~u_main.UDSn, ~u_main.LDSn};
wire        dbg_irq    /*verilator public_flat_rd*/ = board_irq;
wire        dbg_vbirq  /*verilator public_flat_rd*/ = vblank_irq;
wire        dbg_x_rd   /*verilator public_flat_rd*/ = u_main.mcu_xrd;
wire        dbg_x_wr   /*verilator public_flat_rd*/ = u_main.mcu_xwr;
wire [15:0] dbg_x_addr /*verilator public_flat_rd*/ = u_main.mcu_xaddr;
wire [7:0]  dbg_x_dout /*verilator public_flat_rd*/ = u_main.mcu_xdout;
wire [7:0]  dbg_x_din  /*verilator public_flat_rd*/ = u_main.u_mcu.xdata_din_q;
wire        dbg_x_cen  /*verilator public_flat_rd*/ = u_main.u_mcu.cen_eff;
wire [15:0] dbg_x_pc   /*verilator public_flat_rd*/ = u_main.u_mcu.core_rom_adr;
wire        dbg_cen    /*verilator public_flat_rd*/ = cpu_tick;
`endif

endmodule

`default_nettype wire
