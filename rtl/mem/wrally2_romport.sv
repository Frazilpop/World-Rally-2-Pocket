// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally 2 (Pocket) — one fetcher's view of an SDRAM line port.
//
// jlrh's fetchers present an address and wait for `ok`, which means "the
// data for the address now on the bus" (jtframe's convention). The platform
// hands out 64-bit lines: a level request held until a one-clock ack.
// This keeps the last line fetched; `ok` is a hit on it, so a fetcher that
// moves between words of one line (the 68000 running through code, the
// fifth plane of a tile row that sits in the same line as the other four)
// waits only for the first.
//
// `line` may come from the 96 MHz domain (the sprite engine): it is compared
// combinationally and sampled here on the 48 MHz edge, which is also a
// 96 MHz edge (one PLL).

`timescale 1ns/1ps
`default_nettype none

module wrally2_romport #(
    parameter int unsigned AW = 25
)(
    input  wire          clk,
    input  wire          rst,       // forgets the line (held until the ROM is loaded)

    input  wire          cs,
    input  wire [AW:1]   line,      // word address of the wanted line, addr[2:1] == 0
    output wire          ok,
    output wire [63:0]   data,

    output reg           rom_req,
    output reg  [AW:1]   rom_addr,
    input  wire          rom_ack,
    input  wire [63:0]   rom_dout
);

reg          valid;
reg [AW:1]   have;
reg [63:0]   held;

wire hit = valid && (have == line);
assign ok   = cs && hit;
assign data = held;

always @(posedge clk) begin
    if (rst) begin
        valid   <= 1'b0;
        rom_req <= 1'b0;
    end else begin
        if (!rom_req && cs && !hit) begin
            rom_req  <= 1'b1;
            rom_addr <= line;
        end
        if (rom_req && rom_ack) begin
            rom_req <= 1'b0;
            valid   <= 1'b1;
            have    <= rom_addr;
            held    <= rom_dout;
        end
    end
end

endmodule

`default_nettype wire
