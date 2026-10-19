`default_nettype none

module wrally2_mcu #(
    parameter DIVCEN = 1
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,

    output wire [15:0] rom_addr,
    output wire        rom_en,
    input  wire [ 7:0] rom_byte,

    output wire        xdata_rd,
    output wire        xdata_wr,
    output wire [15:0] xdata_addr,
    output wire [ 7:0] xdata_dout,
    input  wire [ 7:0] xdata_din
);

`ifdef WR2_JT8051
    // jt8051 (jotego): cen is the oscillator period, twelve to a machine
    // cycle, so it takes the board's 13 MHz tick as it is, never on adjacent
    // clocks. Laid out as jtframe_8751mcu: the core's buses registered on the
    // next clock, the PROM read only on cen (rom_en, the board's PROM), the
    // MOVX data passed straight in. The internal RAM is the 8051's 128 bytes.
    wire        cen_eff = cen;
    wire [15:0] core_rom_adr;
    wire [ 7:0] core_ram_q, core_ram_d;
    wire [ 6:0] core_ram_adr;
    wire        core_ram_wr;
    wire [ 7:0] core_datax_o;
    wire [15:0] core_adrx;
    wire        core_memx, core_wrx;

    reg [15:0] rom_addr_r = 16'd0;
    always @(posedge clk) rom_addr_r <= core_rom_adr;
    assign rom_addr = rom_addr_r;
    assign rom_en   = cen_eff;

    jtframe_ram_rst #(.AW(7),.CEN_RD(1)) u_iram (
        .rst(rst), .clk(clk), .cen(cen_eff),
        .addr(core_ram_adr), .data(core_ram_d), .we(core_ram_wr), .q(core_ram_q)
    );

    reg [15:0] x_addr_r = 16'd0;
    reg [ 7:0] x_dout_r = 8'd0;
    reg        x_wr_r = 1'b0, x_acc_r = 1'b0;
    always @(posedge clk) begin
        x_addr_r <= core_adrx;
        x_dout_r <= core_datax_o;
        x_wr_r   <= core_wrx;
        x_acc_r  <= core_memx;
    end
    assign xdata_addr = x_addr_r;
    assign xdata_dout = x_dout_r;
    assign xdata_rd   = x_acc_r & ~x_wr_r;
    assign xdata_wr   = x_acc_r &  x_wr_r;
    // what the core takes (it reads x_din on a cen of its own choosing)
    wire [7:0] xdata_din_q = xdata_din;

`ifdef VERILATOR
    // jt8051's own check, behind SIMULATION there (which would also have the
    // jtframe RAMs load their SIMFILEs here)
    reg cen_l = 1'b0;
    always @(posedge clk) begin
        if (!rst && cen && cen_l) $fatal(1, "wrally2_mcu: jt8051's cen on adjacent clocks");
        cen_l <= cen & ~rst;
    end
`endif

    jt8051 u_core (
        .rst(rst), .clk(clk), .cen(cen_eff),
        .int0n(1'b1), .int1n(1'b1),
        .p0_i(8'hFF), .p1_i(8'hFF), .p2_i(8'hFF), .p3_i(8'hFF),
        .p0_o(), .p1_o(), .p2_o(), .p3_o(),
        .rom_data(rom_byte), .rom_addr(core_rom_adr),
        .ram_din(core_ram_q), .ram_dout(core_ram_d), .ram_addr(core_ram_adr), .ram_we(core_ram_wr),
        .x_din(xdata_din), .x_dout(core_datax_o), .x_addr(core_adrx),
        .x_wr(core_wrx), .x_acc(core_memx)
    );
`else
    // mc8051 (Oregano, through GHDL): one cen a machine cycle, so the tick
    // is divided by 12 (DIVCEN).
    reg  [3:0] divcnt = 4'd0;
    reg        cen_div = 1'b0;
    always @(posedge clk) begin
        if (cen) divcnt <= (divcnt==4'd11) ? 4'd0 : divcnt + 4'd1;
        cen_div <= (divcnt==4'd1) && cen;
    end
    wire cen_eff = (DIVCEN!=0) ? cen_div : cen;

    wire [15:0] core_rom_adr;
    wire [ 7:0] core_ram_q, core_ram_d, core_ram_adr;
    wire        core_ram_wr, core_ram_en;
    wire [ 7:0] core_datax_o;
    wire [15:0] core_adrx;
    wire        core_memx, core_wrx;

    reg [15:0] rom_addr_r = 16'd0;
    always @(posedge clk) rom_addr_r <= core_rom_adr;
    assign rom_addr = rom_addr_r;
    assign rom_en   = 1'b1;
    reg [7:0] rom_data_q = 8'd0;
    always @(posedge clk) if (cen_eff) rom_data_q <= rom_byte;

    jtframe_ram_rst #(.AW(8),.CEN_RD(1)) u_iram (
        .rst(rst), .clk(clk), .cen(cen_eff),
        .addr(core_ram_adr), .data(core_ram_d), .we(core_ram_wr), .q(core_ram_q)
    );

    reg [15:0] x_addr_r = 16'd0;
    reg [ 7:0] x_dout_r = 8'd0;
    reg        x_wr_r = 1'b0, x_acc_r = 1'b0;
    always @(posedge clk) begin
        x_addr_r <= core_adrx;
        x_dout_r <= core_datax_o;
        x_wr_r   <= core_wrx;
        x_acc_r  <= core_memx;
    end
    assign xdata_addr = x_addr_r;
    assign xdata_dout = x_dout_r;
    assign xdata_rd   = x_acc_r & ~x_wr_r;
    assign xdata_wr   = x_acc_r &  x_wr_r;
    reg [7:0] xdata_din_q = 8'd0;
    always @(posedge clk) if (cen_eff) xdata_din_q <= xdata_din;

    mc8051_core u_core (
        .clk(clk), .cen(cen_eff), .reset(rst),
        .rom_data_i(rom_data_q), .rom_adr_o(core_rom_adr),
        .ram_data_i(core_ram_q), .ram_data_o(core_ram_d), .ram_adr_o(core_ram_adr),
        .ram_wr_o(core_ram_wr), .ram_en_o(core_ram_en),
        .datax_i(xdata_din_q), .datax_o(core_datax_o), .adrx_o(core_adrx),
        .memx_o(core_memx), .wrx_o(core_wrx),
        .int0_i(1'b1), .int1_i(1'b1),
        .all_t0_i(1'b0), .all_t1_i(1'b0), .all_rxd_i(1'b0),
        .all_rxd_o(), .all_rxdwr_o(), .all_txd_o(),
        .p0_i(8'hFF), .p0_o(), .p1_i(8'hFF), .p1_o(),
        .p2_i(8'hFF), .p2_o(), .p3_i(8'hFF), .p3_o()
    );
`endif
endmodule

`default_nettype wire
