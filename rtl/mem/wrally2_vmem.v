// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally 2 (Pocket) — the GAE1's video memories, one screen.
//
// jlrh's board kept six copies of the 64 KB video RAM (one per reader) and
// two of the palette; the Pocket has room for two. So:
//
//   VRAM           64 KB, written and read by the 68000 on one port; the
//                  other port is the video's: the tilemap's tile pairs, the
//                  scroll words, and the copy below. Four banks of words
//                  (bank = word address [1:0]), so that port reads a row of
//                  four words at once.
//   sprite buffer  64 KB, the VRAM as it stood at vblank (`snap`, the
//                  tick of IRQ 6): what MAME's BUFFERED_SPRITERAM16 draws
//                  from, picture N's sprites from vblank N - 1's VRAM. The
//                  copy takes 8,192 rows; `copying` holds board time
//                  meanwhile, so the 68000 sees it done in an instant, as
//                  MAME's is.
//   palette        8 KB, the 68000 on one port, the pixel on the other.
//
// The video port goes first to the tilemap (tp_rd, a tile's two words for
// the next clock), then to the scroll reader when its address has moved
// (or always while no copy runs), then to the copy.

`timescale 1ns/1ps
`default_nettype none

module wrally2_vmem (
    input  wire        clk,             // 48 MHz
    input  wire        rst,

    // the 68000
    input  wire [15:0] cpu_addr,        // byte address within the window
    input  wire        cpu_uds, cpu_lds,
    input  wire        cpu_we,
    input  wire        cs_vram,
    input  wire        cs_pal,
    input  wire [15:0] cpu_wdata,
    output wire [15:0] cpu_vram_rdata,
    output reg  [15:0] cpu_pal_rdata,

    // the tilemap: words 2i and 2i+1 for tp_rd's clock, in tp_q the next
    input  wire        tp_rd,
    input  wire [13:0] tp_idx,
    output wire [31:0] tp_q,
    // the scroll reader: wrd_q holds the last word read at wrd_a
    input  wire [14:0] wrd_a,
    output reg  [15:0] wrd_q,

    // the sprite buffer
    input  wire        snap,
    output wire        copying,
    input  wire [14:0] spr_a,
    output wire [15:0] spr_q,

    // the palette, for the pixel
    input  wire [11:0] pal_a,
    output reg  [15:0] pal_q
);

`ifdef VERILATOR
// The harness's scene mode (tb_wrally2 --scene) writes a MAME dump in here:
// sc_sel 0 the VRAM, 1 the sprite buffer, 2 the palette.
reg        sc_we   /*verilator public_flat_rw*/ = 1'b0;
reg [1:0]  sc_sel  /*verilator public_flat_rw*/ = 2'd0;
reg [14:0] sc_addr /*verilator public_flat_rw*/ = 15'd0;
reg [15:0] sc_data /*verilator public_flat_rw*/ = 16'd0;
`endif

// ================================================================ VRAM
wire [12:0] a_row  = cpu_addr[15:3];
wire [1:0]  a_bank = cpu_addr[2:1];

reg  [12:0] cp_row;
reg         cp_run;
reg  [14:0] wrd_last;
reg         wrd_seen;

localparam [1:0] K_NONE = 2'd0, K_TILE = 2'd1, K_SCROLL = 2'd2, K_COPY = 2'd3;
wire        scroll_due = !wrd_seen || wrd_a != wrd_last || !cp_run;
wire [1:0]  b_kind = tp_rd ? K_TILE : scroll_due ? K_SCROLL : cp_run ? K_COPY : K_NONE;
wire [12:0] b_row  = tp_rd ? tp_idx[13:1] : (b_kind == K_SCROLL) ? wrd_a[14:2] : cp_row;

reg  [1:0]  b_kind_q;
reg         tp_half_q;
reg  [1:0]  wrd_bank_q;
reg  [12:0] b_row_q;
reg  [1:0]  a_bank_q;

// bank k's word at [16k +: 16], registered in wrally2_vram8
wire [63:0] a_qv, b_qv;

// Each bank's byte lane is a module of its own (wrally2_vram8): written as
// arrays in this generate loop, Quartus split every one into two simple
// dual-port copies, one a reader, 128 M10K for 64 KB.
genvar k;
generate for (k = 0; k < 4; k = k + 1) begin : g_vram
    wire        we  = cpu_we & cs_vram & (a_bank == k);
    wire [12:0] aa  = a_row;
    wire [15:0] ad  = cpu_wdata;
    wire        awh = we & cpu_uds, awl = we & cpu_lds;
`ifdef VERILATOR
    wire        scw = sc_we && sc_sel == 2'd0 && sc_addr[1:0] == k;
    wire [12:0] aa_r = scw ? sc_addr[14:2] : aa;
    wire [15:0] ad_r = scw ? sc_data : ad;
    wire        awh_r = scw | awh, awl_r = scw | awl;
`else
    wire [12:0] aa_r = aa;
    wire [15:0] ad_r = ad;
    wire        awh_r = awh, awl_r = awl;
`endif
    wire [7:0]  aqh, aql, bqh, bql;
    wrally2_vram8 u_hi (.clk(clk), .a_addr(aa_r), .a_we(awh_r), .a_d(ad_r[15:8]), .a_q(aqh), .b_addr(b_row), .b_q(bqh));
    wrally2_vram8 u_lo (.clk(clk), .a_addr(aa_r), .a_we(awl_r), .a_d(ad_r[7:0]),  .a_q(aql), .b_addr(b_row), .b_q(bql));
    assign a_qv[16*k +: 16] = {aqh, aql};
    assign b_qv[16*k +: 16] = {bqh, bql};
end endgenerate

assign cpu_vram_rdata = a_qv[16*a_bank_q +: 16];
assign tp_q = tp_half_q ? {b_qv[47:32], b_qv[63:48]} : {b_qv[15:0], b_qv[31:16]};

always @(posedge clk) begin
    a_bank_q   <= a_bank;
    b_kind_q   <= b_kind;
    b_row_q    <= b_row;
    tp_half_q  <= tp_idx[0];
    wrd_bank_q <= wrd_a[1:0];
    if (b_kind == K_SCROLL) begin wrd_last <= wrd_a; wrd_seen <= 1'b1; end
    if (b_kind_q == K_SCROLL) wrd_q <= b_qv[16*wrd_bank_q +: 16];
end

// ================================================================ the copy
reg cp_wr;
always @(posedge clk) begin
    cp_wr <= b_kind == K_COPY;
    if (rst) begin
        cp_run <= 1'b0; cp_wr <= 1'b0;
    end else if (snap && !cp_run) begin
        cp_run <= 1'b1; cp_row <= 13'd0;
    end else if (b_kind == K_COPY) begin
        cp_row <= cp_row + 13'd1;
        if (cp_row == 13'h1fff) cp_run <= 1'b0;
    end
end
assign copying = snap | cp_run | cp_wr;

reg  [15:0] s_q [0:3];
reg  [1:0]  spr_bank_q;
generate for (k = 0; k < 4; k = k + 1) begin : g_sbuf
    (* ramstyle = "no_rw_check" *) reg [15:0] m [0:8191];
    always @(posedge clk) begin
        if (cp_wr) m[b_row_q] <= b_qv[16*k +: 16];
`ifdef VERILATOR
        if (sc_we && sc_sel == 2'd1 && sc_addr[1:0] == k) m[sc_addr[14:2]] <= sc_data;
`endif
        s_q[k] <= m[spr_a[14:2]];
    end
end endgenerate
always @(posedge clk) spr_bank_q <= spr_a[1:0];
assign spr_q = s_q[spr_bank_q];

// ================================================================ palette
(* ramstyle = "no_rw_check" *) reg [7:0] pal_hi [0:4095];
(* ramstyle = "no_rw_check" *) reg [7:0] pal_lo [0:4095];
wire [11:0] pwo = cpu_addr[12:1];
wire        pwe = cpu_we & cs_pal;
always @(posedge clk) begin
    if (pwe & cpu_uds) pal_hi[pwo] <= cpu_wdata[15:8];
    if (pwe & cpu_lds) pal_lo[pwo] <= cpu_wdata[7:0];
    cpu_pal_rdata <= {pal_hi[pwo], pal_lo[pwo]};
`ifdef VERILATOR
    if (sc_we && sc_sel == 2'd2) begin pal_hi[sc_addr[11:0]] <= sc_data[15:8]; pal_lo[sc_addr[11:0]] <= sc_data[7:0]; end
`endif
end
always @(posedge clk) pal_q <= {pal_hi[pal_a], pal_lo[pal_a]};

// synthesis translate_off
initial begin cp_run = 1'b0; cp_wr = 1'b0; wrd_seen = 1'b0; b_kind_q = K_NONE; end
// synthesis translate_on

endmodule

// One byte lane of a VRAM bank: 8K x 8, port A the 68000's (read and write),
// port B the video's (read), both registered: one true dual-port M10K group.
module wrally2_vram8 (
    input  wire        clk,
    input  wire [12:0] a_addr,
    input  wire        a_we,
    input  wire [7:0]  a_d,
    output reg  [7:0]  a_q,
    input  wire [12:0] b_addr,
    output reg  [7:0]  b_q
);
(* ramstyle = "no_rw_check" *) reg [7:0] m [0:8191];
always @(posedge clk) begin
    if (a_we) m[a_addr] <= a_d;
    a_q <= m[a_addr];
end
always @(posedge clk) b_q <= m[b_addr];
endmodule

`default_nettype wire
