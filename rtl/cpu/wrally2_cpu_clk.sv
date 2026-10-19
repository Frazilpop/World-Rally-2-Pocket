// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally 2 (Pocket) — the 68000's clock: 13 MHz of board time.
//
// The real board has no wait states; here the program comes from SDRAM. So
// the 68000 is never shown one: while a ROM read waits for its line the CPU
// is simply not clocked, and the clocks it missed are owed to it (credit,
// 13 per 48 MHz clocks) and given back at up to 24 MHz once the data is in.
// Seen from the CPU every bus cycle takes four clocks, as in MAME.
//
// `tick` marks each 68000 clock given. Everything that must keep step with
// the program -- the DS5002FP, the vblank IRQ -- counts ticks rather than
// 48 MHz clocks, so the three stay in lockstep (MAME's perfect quantum)
// however long the SDRAM takes; board time trails wall time by the credit
// owed, a few microseconds at most.
//
// The credit holds 4,095 ticks. When the SDRAM's waits outrun the catch-up
// for longer than that (the power-on ROM test, at a line latency of 14
// clocks or more), board time drops the clocks it cannot give and marks
// each with `lost`: the CPUs run that much slower, as an overloaded board
// would, and the vblank IRQ counts the lost clocks as given, so it stays on
// the picture's vblank.
//
// Replaces jlrh's wrally2_68kdtack (jtframe's 68000 cen/DTACK with
// recovery), whose catch-up gives back cycles but not the 68000's timing:
// measured against MAME, its CPU fell 3.4% behind and took IRQs on other
// instructions.

`timescale 1ns/1ps
`default_nettype none

module wrally2_cpu_clk (
    input  wire rst,
    input  wire clk,            // 48 MHz
    input  wire run,            // 0 = paused: no credit, no clocks
    input  wire ASn,
    input  wire rom_wait,       // a read in progress whose data is not ready
    input  wire hold,           // board time stands still, DTACK as it is
    output reg  cpu_cen,        // fx68k enPhi1
    output reg  cpu_cenb,       // fx68k enPhi2
    output reg  tick,           // with cpu_cen: one 68000 clock of board time
    output wire mid,            // between a phi1 and its phi2
    output wire DTACKn,
    output wire [11:0] owed,    // board time behind wall time, in ticks
    output reg  lost            // a clock dropped with the credit full
);

reg  [5:0]  acc;
reg  [11:0] credit;
reg         ph;                 // 0: phi1 next, 1: phi2 next
wire        gain = run && (acc >= 6'd35);
// Enables are registered: one may still land in the clock after AS falls,
// which is S3, two phases before the 68000 samples DTACK.
wire        go   = run && !rom_wait && !hold;

always @(posedge clk) begin
    if (rst) begin
        acc <= 6'd0; credit <= 12'd0; ph <= 1'b0;
        cpu_cen <= 1'b0; cpu_cenb <= 1'b0; tick <= 1'b0; lost <= 1'b0;
    end else begin
        if (run) acc <= gain ? acc + 6'd13 - 6'd48 : acc + 6'd13;
        cpu_cen <= 1'b0; cpu_cenb <= 1'b0; tick <= 1'b0; lost <= 1'b0;
        if (go && !ph && (credit != 12'd0 || gain)) begin
            cpu_cen <= 1'b1; tick <= 1'b1; ph <= 1'b1;
            credit  <= credit + {11'd0, gain} - 12'd1;
        end else begin
            if (credit != 12'hfff) credit <= credit + {11'd0, gain};
            else lost <= gain;
            if (go && ph) begin cpu_cenb <= 1'b1; ph <= 1'b0; end
        end
    end
end

// No wait states: DTACK with AS, except for a read still waiting (the
// CPU is held then anyway; this only keeps a stray phase from taking a
// word that is not there). A hold leaves DTACK alone: one may start just as
// the 68000 samples it (a write's data strobes come out then), and a DTACK
// held back there would be a wait state MAME's 68000 never has.
assign DTACKn = ASn | rom_wait;
assign mid    = ph;
assign owed   = credit;

endmodule

`default_nettype wire
