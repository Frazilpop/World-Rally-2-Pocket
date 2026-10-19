// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally 2 for Analogue Pocket — the GAE1's samples, evened out to wall
// time.
//
// WHY A FIFO AND NOT A REGISTER
//
// The board makes one sample every 1,664 ticks of board time (7812.5 Hz at
// 13 MHz), and board time keeps 13 MHz only on average: it stands still for
// the sprite buffer's copy at every IRQ 6 (about 200 us) and for each ROM
// line it waits on, then catches up at 24 MHz. Held in a plain register and
// sampled at 48 kHz, the samples made during a catch-up would land closer
// together than one 48 kHz period and some would never be heard, once a
// frame: a 59 Hz buzz under the sound. So they go into a FIFO and come out
// at exactly 7812.5 Hz of wall time, one every 6,144 clocks at 48 MHz, which
// is the same rate exactly (board time's credit is 13/48 of the 48 MHz
// clock), so the FIFO neither fills nor empties in the long run.
//
// PRIMING. Reading starts once PRIME samples are in, so the FIFO carries
// about PRIME x 128 us of slack against board time running late (the copy's
// hold is ~2,700 ticks, about two samples). If it runs dry, the last sample
// is held and reading waits for PRIME again; that is what happens under the
// Pocket's menu, when board time stops (`paused`): the sound holds one
// level, silent, and starts again cleanly after.

`default_nettype none

module pocket_audio #(
    parameter int unsigned PERIOD = 6144,   // 48 MHz / 7812.5 Hz
    parameter int unsigned PRIME  = 4,
    parameter int unsigned DEPTH  = 16      // a power of two
)(
    input  wire               clk,          // 48 MHz
    input  wire               rst,
    input  wire               sample,       // din valid, one clock
    input  wire signed [15:0] din,
    input  wire               paused,       // board time stopped: running dry is expected
    output reg  signed [15:0] dout,
    output reg                under,        // one clock: ran dry while the game ran
    output reg                over          // one clock: a sample arrived with the FIFO full
);

    localparam int unsigned AW = $clog2(DEPTH);

    reg signed [15:0] mem [DEPTH];
    reg [AW:0]        wp, rp;
    reg [12:0]        div;
    reg               priming;
    wire [AW:0]       count = wp - rp;

    always @(posedge clk) begin
        under <= 1'b0;
        over  <= 1'b0;
        if (rst) begin
            wp <= '0; rp <= '0; div <= '0; priming <= 1'b1; dout <= 16'sd0;
        end else begin
            if (sample) begin
                if (count == DEPTH[AW:0]) over <= 1'b1;
                else begin
                    mem[wp[AW-1:0]] <= din;
                    wp <= wp + 1'b1;
                end
            end
            div <= (div == PERIOD[12:0] - 13'd1) ? 13'd0 : div + 13'd1;
            if (priming) begin
                if (count >= PRIME[AW:0]) priming <= 1'b0;
            end else if (div == 13'd0) begin
                if (count != '0) begin
                    dout <= mem[rp[AW-1:0]];
                    rp   <= rp + 1'b1;
                end else begin
                    priming <= 1'b1;
                    under   <= ~paused;
                end
            end
        end
    end

endmodule

`default_nettype wire
