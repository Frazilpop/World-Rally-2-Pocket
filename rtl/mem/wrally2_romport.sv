// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally 2 (Pocket) — one fetcher's view of an SDRAM line port.
//
// jlrh's fetchers present an address and wait for `ok`, which means "the
// data for the address now on the bus" (jtframe's convention). The platform
// hands out 64-bit lines: a level request held until a one-clock ack.
// This keeps the last LINES lines fetched (fully associative, the least
// recently used one replaced); `ok` is a hit on any of them, so a fetcher
// that moves between words of one line (the 68000 running through code, the
// fifth plane of a tile row that sits in the same line as the other four)
// waits only for the first.
//
// LINES = 1 for the video and sound fetchers. The 68000's port keeps four:
// a loop whose code spans three lines while it reads ROM data through a
// fourth (wrally2c's power-on ROM checksum at 2606-2610: add.w (a0)+,d0 /
// cmp.l #,a0 / blt) missed five accesses in seven with one line, and board
// time could not keep up even at a 10-clock line, where the real board's
// ROM never waits.
//
// `line` may come from the 96 MHz domain (the sprite engine): it is compared
// combinationally and sampled here on the 48 MHz edge, which is also a
// 96 MHz edge (one PLL).

`timescale 1ns/1ps
`default_nettype none

module wrally2_romport #(
    parameter int unsigned AW    = 25,
    parameter int unsigned LINES = 1
)(
    input  wire          clk,
    input  wire          rst,       // forgets the lines (held until the ROM is loaded)

    input  wire          cs,
    input  wire [AW:1]   line,      // word address of the wanted line, addr[2:1] == 0
    output wire          ok,
    output wire [63:0]   data,

    output reg           rom_req,
    output reg  [AW:1]   rom_addr,
    input  wire          rom_ack,
    input  wire [63:0]   rom_dout
);

localparam int unsigned LW = LINES > 1 ? $clog2(LINES) : 1;

reg          valid [LINES];
reg [AW:1]   have  [LINES];
reg [63:0]   held  [LINES];
reg [LW-1:0] age   [LINES];     // 0 = used last; always a permutation of 0..LINES-1

logic          hit;
logic [LW-1:0] hit_i, vic_i;
always_comb begin
    hit = 1'b0; hit_i = '0; vic_i = '0;
    for (int i = 0; i < LINES; i++) begin
        if (valid[i] && have[i] == line) begin hit = 1'b1; hit_i = LW'(i); end
        if (age[i] == LW'(LINES - 1)) vic_i = LW'(i);
    end
end
assign ok   = cs && hit;
assign data = held[hit_i];

// the entry used: the one hit, or the one filled
wire          touch   = (cs && hit) || (rom_req && rom_ack);
wire [LW-1:0] touch_i = (rom_req && rom_ack) ? vic_i : hit_i;

always @(posedge clk) begin
    if (rst) begin
        rom_req <= 1'b0;
        for (int i = 0; i < LINES; i++) begin
            valid[i] <= 1'b0;
            age[i]   <= LW'(i);
        end
    end else begin
        if (!rom_req && cs && !hit) begin
            rom_req  <= 1'b1;
            rom_addr <= line;
        end
        if (rom_req && rom_ack) begin
            rom_req       <= 1'b0;
            valid[vic_i]  <= 1'b1;
            have[vic_i]   <= rom_addr;
            held[vic_i]   <= rom_dout;
        end
        if (touch && LINES > 1)
            for (int i = 0; i < LINES; i++)
                if (LW'(i) == touch_i)            age[i] <= '0;
                else if (age[i] < age[touch_i])   age[i] <= age[i] + 1'b1;
    end
end

endmodule

`default_nettype wire
