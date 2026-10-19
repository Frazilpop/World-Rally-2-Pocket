`default_nettype none

// The left screen's tilemap (layer 0, palette half 0) and its scroll, as
// MAME's dual_update draws it: y scroll VRAM 0x2800 + 1, plus the rowscroll
// mode's y (get_rowscrollmode_yscroll) when vreg0 bit 15 is set; x scroll
// 0x2802 + 0x14, or in rowscroll mode the 0x2000 table indexed by the
// tilemap's own row, (screen line + y scroll) & 0x1ff.

module wrally2_gae1_video (
    input  wire        clk,
    input  wire        ce,
    input  wire [9:0]  hpos,
    input  wire [8:0]  vpos,
    input  wire        frame_end,

    input  wire [15:0] vreg0,

    output wire [14:0] wrd_a,
    input  wire [15:0] wrd_q,

    output wire [13:0] tp0_idx, output wire tp0_rd, input wire [31:0] tp0_q,
    output wire [20:0] rom_a0,  input wire [63:0] d0_line, input wire gfx0_ok,

    output reg  [11:0] pal_index,
    output reg         opaque,

    output wire        tm_ovr
);

    localparam [8:0] VLAST = 9'd263;    // wrally2_video_timing's last line

    reg [8:0] vpos_d;
    always @(posedge clk) vpos_d <= vpos;
    wire        line_change = (vpos != vpos_d);
    wire [8:0]  next_vpos   = frame_end ? 9'd0 : vpos + 9'd1;

    wire [8:0]  render_line = next_vpos + 9'd16;
    wire        rbank = vpos[0];
    wire        wbank = next_vpos[0];
    // the line the tilemap starts on at the next line change
    wire [8:0]  next2_vpos  = (vpos == VLAST) ? 9'd1 : (vpos == VLAST - 9'd1) ? 9'd0 : vpos + 9'd2;
    wire [8:0]  ahead_line  = next2_vpos + 9'd16;

    reg start_r;
    always @(posedge clk) start_r <= line_change;

    // The scroll words, one read a pixel in turn: y, x, the rowscroll entry
    // for the line ahead, and one of the 32 entries whose bit 12 makes the
    // rowscroll mode's y (MAME's checkoffsets, scanned 0..31: the first set,
    // i, gives 31 - i).
    reg [1:0] scnt = 2'd0;
    reg [4:0] rk = 5'd0;
    reg [8:0] scroll0y_w;
    reg [9:0] scroll0x, ls0;
    reg [4:0] rsy, rsy_acc;
    reg       rsy_hit;
    wire [8:0] scroll0y = scroll0y_w + (vreg0[15] ? {4'd0, rsy} : 9'd0);

    function automatic [4:0] chkoff(input [4:0] i);
        case (i)
            5'd0:  chkoff = 5'h02; 5'd1:  chkoff = 5'h0e; 5'd2:  chkoff = 5'h0a; 5'd3:  chkoff = 5'h1b;
            5'd4:  chkoff = 5'h15; 5'd5:  chkoff = 5'h13; 5'd6:  chkoff = 5'h04; 5'd7:  chkoff = 5'h19;
            5'd8:  chkoff = 5'h0c; 5'd9:  chkoff = 5'h1f; 5'd10: chkoff = 5'h08; 5'd11: chkoff = 5'h1d;
            5'd12: chkoff = 5'h11; 5'd13: chkoff = 5'h06; 5'd14: chkoff = 5'h17; 5'd15: chkoff = 5'h10;
            5'd16: chkoff = 5'h01; 5'd17: chkoff = 5'h0d; 5'd18: chkoff = 5'h16; 5'd19: chkoff = 5'h09;
            5'd20: chkoff = 5'h1a; 5'd21: chkoff = 5'h05; 5'd22: chkoff = 5'h1e; 5'd23: chkoff = 5'h00;
            5'd24: chkoff = 5'h12; 5'd25: chkoff = 5'h0b; 5'd26: chkoff = 5'h14; 5'd27: chkoff = 5'h03;
            5'd28: chkoff = 5'h1c; 5'd29: chkoff = 5'h18; 5'd30: chkoff = 5'h07; default: chkoff = 5'h0f;
        endcase
    endfunction
    wire [6:0] rk_off = {2'd0, chkoff(rk)} + {1'b0, chkoff(rk), 1'b0} + 7'd1;   // 3i + 1

    assign wrd_a = (scnt == 2'd0) ? 15'h1400 :
                   (scnt == 2'd1) ? 15'h1401 :
                   (scnt == 2'd2) ? (15'h1000 + {6'd0, (ahead_line + scroll0y) & 9'h1ff}) :
                                    (15'h1040 + {8'd0, rk_off});
    always @(posedge clk) if (ce) begin
        scnt <= scnt + 2'd1;
        case (scnt)
            2'd0: scroll0y_w <= wrd_q[8:0] + 9'd1;
            2'd1: scroll0x   <= wrd_q[9:0] + 10'h14;
            2'd2: ls0        <= wrd_q[9:0] + 10'h14;
            2'd3: begin
                rk <= rk + 5'd1;
                if (wrd_q[12] && !rsy_hit) begin rsy_acc <= 5'd31 - rk; rsy_hit <= 1'b1; end
                if (rk == 5'd31) begin
                    rsy <= (wrd_q[12] && !rsy_hit) ? 5'd0 : rsy_hit ? rsy_acc : 5'd0;
                    rsy_hit <= 1'b0;
                end
            end
        endcase
    end
    wire [9:0] scroll0x_eff = vreg0[15] ? ls0 : scroll0x;
    wire [2:0] bank0 = vreg0[11:9];

    wire [11:0] lb_q0;
    wire        l0_ovr;
    assign tm_ovr = l0_ovr;

    wire [9:0] sc0x  = scroll0x_eff & 10'h3ff;
    wire [9:0] lb_rx = (hpos - 10'd14) & 10'h1ff;

    wrally2_gae1_tilemap u_l0 (
        .clk(clk), .ce(1'b1), .start(start_r), .line(render_line),
        .scroll_x(sc0x), .scroll_y(scroll0y), .bank(bank0), .busy(),
        .tp_idx(tp0_idx), .tp_rd(tp0_rd), .tp_q(tp0_q),
        .rom_a(rom_a0), .d_line(d0_line), .gfx_ok(gfx0_ok),
        .lb_x(lb_rx), .lb_q(lb_q0), .wbank(wbank), .rbank(rbank), .ovr(l0_ovr)
    );

    wire [4:0] pen0 = lb_q0[4:0]; wire [6:0] color0 = lb_q0[11:5];

    always @(posedge clk) if (ce) begin
        if (pen0 != 5'd0) begin pal_index <= {color0, pen0}; opaque <= 1'b1; end
        else              begin pal_index <= 12'd0;          opaque <= 1'b0; end
    end

    // synthesis translate_off
    initial begin rsy = 5'd0; rsy_acc = 5'd0; rsy_hit = 1'b0; end
    // synthesis translate_on
endmodule

`default_nettype wire
