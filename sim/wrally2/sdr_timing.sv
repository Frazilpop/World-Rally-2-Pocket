// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally 2 (Pocket) — the shell's SDRAM path, for the harness's timing.
//
// kaneko_sdram_x2 and kaneko_sdram as core_top.v sets them up (five ports:
// the board's four and the shell's read-back of line 0, URGENT 0_1111,
// T_REFI 700, T_RC 11), in front of sdram_model. sim/wrally2/build.sh with
// SDR=real builds this as a second model (Vsdr_timing); tb_wrally2 clocks it
// twice per 48 MHz clock and takes only the acknowledges from it: the data
// still comes from the ROM image, so this answers when a line arrives –
// arbitration, refresh and the 2:1 adapter included – not what is in it.

`timescale 1ns/1ps
`default_nettype none

module sdr_timing #(
    parameter int unsigned NP = 5,
    parameter int unsigned AW = 25
) (
    input  wire             clk_fast,       // 96 MHz
    input  wire             rst_n,
    output wire             ready,
    input  wire [NP-1:0]    s_req,
    input  wire [NP*AW-1:0] s_addr,
    output wire [NP-1:0]    s_ack,
    output int unsigned     violations
);

wire [NP-1:0]       f_req, f_ack, f_we;
wire [NP-1:0][AW:1] f_addr;
wire [NP-1:0][63:0] f_dout;
wire [NP-1:0][15:0] f_din;
wire [NP-1:0][1:0]  f_be;
wire                f_wr_req, f_wr_ack;
wire [AW:1]         f_wr_addr;
wire [15:0]         f_wr_din;
wire [1:0]          f_wr_be;

kaneko_sdram_x2 #(.NP(NP), .AW(AW)) u_x2 (
    .clk_fast (clk_fast),
    .s_req    (s_req), .s_addr(s_addr),
    .s_we     ({NP{1'b0}}), .s_din({NP{16'd0}}), .s_be({NP{2'b11}}),
    .s_ack    (s_ack), .s_dout(),
    .s_wr_req (1'b0), .s_wr_addr('0), .s_wr_din(16'd0), .s_wr_be(2'b11), .s_wr_ack(),
    .f_req    (f_req), .f_addr(f_addr), .f_ack(f_ack), .f_dout(f_dout),
    .f_we     (f_we),  .f_din(f_din),   .f_be(f_be),
    .f_wr_req (f_wr_req), .f_wr_addr(f_wr_addr), .f_wr_din(f_wr_din),
    .f_wr_be  (f_wr_be),  .f_wr_ack(f_wr_ack)
);

wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
wire [1:0]  sd_ba, sd_dqm;
wire [12:0] sd_a;
wire [15:0] sd_dq_o, sd_dq_i;

kaneko_sdram #(
    .COL_BITS (10), .NP(NP),
    .T_REFI   (700), .T_RC(11),
    .INIT_NOP (600),                // the power-up wait, shortened
    .URGENT   (5'b0_1111)
) u_ctrl (
    .clk(clk_fast), .rst_n(rst_n), .ready(ready),
    .rd_lat_sel(2'd0),              // CL+3: sdram_model's phase (the Pocket: CL+2)
    .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
    .sd_we_n(sd_we_n), .sd_ba(sd_ba), .sd_a(sd_a), .sd_dqm(sd_dqm),
    .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(sd_dq_i),
    .wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din), .wr_be(f_wr_be), .wr_ack(f_wr_ack),
    .p_req(f_req), .p_we(f_we), .p_addr(f_addr), .p_din(f_din), .p_be(f_be),
    .p_dout(f_dout), .p_ack(f_ack),
    .dbg_req(), .dbg_grant()
);

sdram_model #(.COL_BITS(10), .T_REFI(750), .REFI_SLACK(9)) u_dram (
    .clk(clk_fast), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
    .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a),
    .dqm(sd_dqm), .dq_i(sd_dq_o), .dq_oe_i(sd_dq_oe),
    .dq_o(sd_dq_i), .dq_oe_o(),
    .violations(violations), .v_flags(),
    .reads_served(), .writes_served()
);

endmodule

`default_nettype wire
