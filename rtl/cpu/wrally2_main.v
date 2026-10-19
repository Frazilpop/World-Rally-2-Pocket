`default_nettype none

module wrally2_main (
    input  wire        clk,
    input  wire        rst,
    input  wire        game_run,
    input  wire        vblank_irq,

    output wire [19:1] prog_addr,
    output wire        prog_cs,
    input  wire [15:0] prog_data,
    input  wire        prog_data_ok,

    input  wire [15:0] in0, in1, in2, in3,
    input  wire [7:0]  paddle0, paddle1,

    output wire        flip_screen,
    output wire [15:0] vmem_addr,
    output wire        vmem_uds, vmem_lds,
    output wire        vmem_we,
    output wire        vmem_cs_vram,
    output wire        vmem_cs_pal,
    output wire [15:0] vmem_wdata,
    input  wire [15:0] vmem_vram_rdata,
    input  wire [15:0] vmem_pal_rdata,

    output wire [15:0] vreg0, vreg1, vreg2,

    output wire        sndreg_cs,
    output wire        sndreg_we,
    input  wire [15:0] snd_rdata,

    output wire        cpu_tick,       // one 68000 clock of board time (wrally2_cpu_clk)
    input  wire        cpu_hold,       // board time stands still (the GAE1 computing a sample)
    input  wire        mcu_cen,
    output wire [11:0] cpu_owed,       // board time behind wall time, in ticks
    output wire        cpu_lost,       // a tick dropped with the credit full (wrally2_cpu_clk)

    // Work RAM (fe0000-fe7fff, SRAM words 0-3fff) and extra RAM (212000-
    // 213fff, words 4000-4fff) on the platform's SRAM: req held until a
    // one-clock ack, dout valid with it. Board time waits for it.
    output reg         sram_req,
    output reg         sram_we,
    output reg  [16:0] sram_addr,
    output reg  [15:0] sram_din,
    output reg  [1:0]  sram_be,
    input  wire        sram_ack,
    input  wire [15:0] sram_dout,

    input  wire [14:0] scr_dl_addr,
    input  wire [ 7:0] scr_dl_data,
    input  wire        scr_dl_we,

    output wire [15:0] dbg_mcu_pcmax,
    output wire [15:0] dbg_mcu_fetch,
    output wire [15:0] dbg_mcuw,
    output wire [15:0] dbg_mcu_scrw,
    output wire [ 7:0] dbg_key
);

    wire [23:1] eab;
    wire        ASn, LDSn, UDSn, eRWn;
    wire [15:0] oEdb;
    reg  [15:0] iEdb;
    wire        DTACKn;
    reg         VPAn;
    wire        FC0, FC1, FC2;
    reg         IPL_n;
    wire [2:0]  fc = {FC2, FC1, FC0};
    wire        cpu_cen, cpu_cenb, cpu_mid;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(rst),
        .enPhi1(cpu_cen), .enPhi2(cpu_cenb),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(), .VMAn(), .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(), .oRESETn(), .oHALTEDn(),
        .DTACKn(DTACKn), .VPAn(VPAn), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),

        .IPL0n(1'b1), .IPL1n(IPL_n), .IPL2n(IPL_n),
        .iEdb(iEdb), .oEdb(oEdb), .eab(eab)
    );

    wire [23:0] addr  = {eab, 1'b0};
    wire        uds   = ~UDSn;
    wire        lds   = ~LDSn;
    wire        rw_rd = eRWn;

    wire cs_rom, cs_vram, cs_sound, cs_pal, cs_xram, cs_vregs, cs_in0, cs_in1, cs_in2, cs_in3,
         cs_latch, cs_wram, cs_shram;
    wrally2_addr_decode u_dec (
        .addr(addr), .as(~ASn),
        .cs_rom(cs_rom), .cs_vram(cs_vram), .cs_sound(cs_sound), .cs_pal(cs_pal), .cs_xram(cs_xram),
        .cs_vregs(cs_vregs), .cs_in0(cs_in0), .cs_in1(cs_in1), .cs_in2(cs_in2), .cs_in3(cs_in3),
        .cs_latch(cs_latch), .cs_wram(cs_wram), .cs_shram(cs_shram)
    );

    wire        latch_we = wr_ack & ~rw_rd & cs_latch;
    wire [2:0]  latch_sel = addr[5:3];
    wire        adc1_bit, adc2_bit;
    wrally2_adc u_adc (
        .clk(clk), .rst(rst),
        .latch_we(latch_we), .latch_sel(latch_sel), .latch_dat(oEdb[0]),
        .analog0(paddle0), .analog1(paddle1),
        .adc1_bit(adc1_bit), .adc2_bit(adc2_bit)
    );

    assign prog_addr = eab[19:1];
    assign prog_cs   = cs_rom & rw_rd;
    wire [15:0] rom_word = prog_data;

    wire bus_busy  = cs_rom & rw_rd & ~prog_data_ok;
    wire sram_wait;
    wire dtack_raw;
    wrally2_cpu_clk u_clk (
        .rst(rst), .clk(clk), .run(game_run),
        .ASn(ASn), .rom_wait(bus_busy | (sram_wait & rw_rd)), .hold((sram_wait & ~rw_rd) | cpu_hold),
        .cpu_cen(cpu_cen), .cpu_cenb(cpu_cenb), .tick(cpu_tick), .mid(cpu_mid),
        .DTACKn(dtack_raw), .owed(cpu_owed), .lost(cpu_lost)
    );

    assign DTACKn = (fc == 3'd7) ? 1'b1 : dtack_raw;

    reg [15:0] vregs[0:7];
`ifdef VERILATOR
    // the harness's scene mode: vreg sc_vsel = sc_vdata
    reg        sc_vwe   /*verilator public_flat_rw*/ = 1'b0;
    reg [2:0]  sc_vsel  /*verilator public_flat_rw*/ = 3'd0;
    reg [15:0] sc_vdata /*verilator public_flat_rw*/ = 16'd0;
`endif
    assign vreg0 = vregs[2]; assign vreg1 = vregs[3]; assign vreg2 = vregs[4];

    assign flip_screen = 1'b0;

    assign vmem_addr    = addr[15:0];
    assign vmem_uds     = uds;
    assign vmem_lds     = lds;
    assign vmem_cs_vram = cs_vram;
    assign vmem_cs_pal  = cs_pal;
    assign vmem_we      = wr_ack & ~rw_rd & (cs_vram | cs_pal);
    assign vmem_wdata   = oEdb;

    assign sndreg_cs    = cs_sound;
    assign sndreg_we    = wr_ack & ~rw_rd & cs_sound;

    always @(*) begin
        iEdb = 16'hFFFF;
        case (1'b1)
            cs_rom:   iEdb = rom_word;
            cs_vram:  iEdb = vmem_vram_rdata;
            cs_pal:   iEdb = vmem_pal_rdata;
            cs_xram:  iEdb = sram_q;

            cs_vregs: iEdb = vregs[addr[3:1]];
            cs_in0:   iEdb = {in0[15:7], adc1_bit, in0[5:0]};
            cs_in1:   iEdb = in1;
            cs_in2:   iEdb = {in2[15:7], adc2_bit, in2[5:0]};
            cs_in3:   iEdb = in3;
            cs_wram:  iEdb = sram_q;
            cs_shram: iEdb = shram_q;
            cs_sound: iEdb = snd_rdata;
            default:  iEdb = 16'hFFFF;
        endcase
    end

    reg  asn_d;
    wire wr_ack     = (~ASn) & (~asn_d);

    reg irq_pending;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            asn_d       <= 1'b1;
            VPAn        <= 1'b1;
            irq_pending <= 1'b0;
            IPL_n       <= 1'b1;
        end else begin
            asn_d <= ASn;

            if (vblank_irq) irq_pending <= 1'b1;
            // IPL moves with phi2's clock or after it, never between phi1 and
            // phi2: where it lands against the phases decides which instruction
            // takes the IRQ, and a hold of board time (a ROM miss, the SRAM,
            // the sprite copy, the GAE1) can come between them
            if (!cpu_mid) IPL_n <= ~irq_pending;
`ifdef VERILATOR
            if (sc_vwe) vregs[sc_vsel] <= sc_vdata;
`endif

            if (~ASn) VPAn <= (fc == 3'd7) ? 1'b0 : 1'b1;
            else      VPAn <= 1'b1;

            if (wr_ack) begin
                if (fc == 3'd7) begin
                    irq_pending <= 1'b0;
                end else if (~rw_rd) begin
                    if (cs_vregs) begin
                        if (uds) vregs[addr[3:1]][15:8] <= oEdb[15:8];
                        if (lds) vregs[addr[3:1]][7:0]  <= oEdb[7:0];
                    end

                end
            end
        end
    end

    // One request a bus cycle, once its data strobes are out (a write's come
    // a phase after AS); `sram_done` until they fall, so a read-modify-write
    // cycle makes two. The CPU is not clocked meanwhile, as for a ROM miss;
    // a read's DTACK waits for the data, a write's does not.
    wire        cs_sram   = cs_wram | cs_xram;
    wire        sram_need = cs_sram & ~ASn & (uds | lds);
    reg         sram_done;
    reg  [15:0] sram_q;
    assign      sram_wait = sram_need & ~sram_done;
    always @(posedge clk) begin
        if (rst) begin
            sram_req <= 1'b0; sram_done <= 1'b0;
        end else begin
            if (ASn || !(uds || lds)) sram_done <= 1'b0;
            if (!sram_req && sram_wait) begin
                sram_req  <= 1'b1;
                sram_we   <= ~rw_rd;
                sram_addr <= cs_wram ? {3'b000, addr[14:1]} : {5'b00100, addr[12:1]};
                sram_din  <= oEdb;
                sram_be   <= {uds, lds};
            end
            if (sram_req && sram_ack) begin
                sram_req  <= 1'b0;
                sram_done <= 1'b1;
                sram_q    <= sram_dout;
            end
        end
    end

    wire        mcu_xrd, mcu_xwr; wire [15:0] mcu_xaddr; wire [7:0] mcu_xdout; wire [7:0] mcu_xdin;
    wire [15:0] mcu_rom_addr; wire mcu_rom_en;
    reg  [7:0]  mcurom_q;
    wrally2_mcu u_mcu (
        .clk(clk), .rst(rst), .cen(mcu_cen),
        .rom_addr(mcu_rom_addr), .rom_en(mcu_rom_en), .rom_byte(mcurom_q),
        .xdata_rd(mcu_xrd), .xdata_wr(mcu_xwr), .xdata_addr(mcu_xaddr),
        .xdata_dout(mcu_xdout), .xdata_din(mcu_xdin)
    );

    wire        mcu_sh    = mcu_xaddr[15];
    wire [13:0] mcu_shidx = mcu_xaddr[14:1];
    wire        mcu_scr   = ~mcu_xaddr[15];

    wire [13:0] shidx = addr[14:1];
    wire        sw_hi = wr_ack & ~rw_rd & cs_shram & uds;
    wire        sw_lo = wr_ack & ~rw_rd & cs_shram & lds;
    wire        mcu_sh_wr_hi = mcu_xwr & mcu_sh & ~mcu_xaddr[0];
    wire        mcu_sh_wr_lo = mcu_xwr & mcu_sh &  mcu_xaddr[0];
    wire [7:0]  shram_hi_q, shram_lo_q;
    wire [7:0]  shram_mcu_hi_q, shram_mcu_lo_q;
    wire [15:0] shram_q = {shram_hi_q, shram_lo_q};
    jtframe_dual_ram #(.AW(14),.DW(8)) u_shram_hi (
        .clk0(clk), .data0(oEdb[15:8]), .addr0(shidx),     .we0(sw_hi),        .q0(shram_hi_q),
        .clk1(clk), .data1(mcu_xdout),  .addr1(mcu_shidx), .we1(mcu_sh_wr_hi), .q1(shram_mcu_hi_q)
    );
    jtframe_dual_ram #(.AW(14),.DW(8)) u_shram_lo (
        .clk0(clk), .data0(oEdb[7:0]),  .addr0(shidx),     .we0(sw_lo),        .q0(shram_lo_q),
        .clk1(clk), .data1(mcu_xdout),  .addr1(mcu_shidx), .we1(mcu_sh_wr_lo), .q1(shram_mcu_lo_q)
    );

    // The DS5002FP's 32 KB SRAM: its program and, the same bytes, MOVX data
    // 0000-7fff, as on the board (jlrh kept two copies). Port A the MOVX
    // side, and the loader's while both CPUs are in reset; port B the
    // program fetch (jt8051 reads it on cen only).
    (* ramstyle = "no_rw_check" *) reg [7:0] dsram [0:32767];
    wire [14:0] dsa_addr = scr_dl_we ? scr_dl_addr : mcu_xaddr[14:0];
    wire        dsa_we   = scr_dl_we | (mcu_xwr & mcu_scr);
    wire [7:0]  dsa_d    = scr_dl_we ? scr_dl_data : mcu_xdout;
    reg  [7:0]  scratch_q;
    always @(posedge clk) begin
        if (dsa_we) dsram[dsa_addr] <= dsa_d;
        scratch_q <= dsram[dsa_addr];
    end
    always @(posedge clk) if (mcu_rom_en) mcurom_q <= dsram[mcu_rom_addr[14:0]];
    wire [14:0] mcurom_addr = mcu_rom_addr[14:0];

    assign mcu_xdin = mcu_scr ? scratch_q :
                      (mcu_xaddr[0] ? shram_mcu_lo_q : shram_mcu_hi_q);

`ifdef ALI_XTRACE

    integer xr_lo=0, xr_hi=0, xw_lo=0, xw_hi=0, xsmp=0;
    reg xrd_d=0, xwr_d=0;
    always @(posedge clk) begin
        xrd_d <= mcu_xrd; xwr_d <= mcu_xwr;
        if (mcu_xrd & ~xrd_d) begin
            if (mcu_xaddr[15]) xr_hi<=xr_hi+1; else xr_lo<=xr_lo+1;
            if (~mcu_xaddr[15] && xsmp<32) begin
                xsmp<=xsmp+1;
                $display("XTR rd lo [%04x] -> %02x", mcu_xaddr, mcu_xdin);
            end
        end
        if (mcu_xwr & ~xwr_d) begin
            if (mcu_xaddr[15]) xw_hi<=xw_hi+1; else xw_lo<=xw_lo+1;
        end
    end

    reg [23:0] xtc=0;
    always @(posedge clk) begin
        xtc<=xtc+1;
        if (xtc==24'hFFFFFF) $display("XTR HIST  rd lo(0-7fff)=%0d hi(8000-ffff)=%0d  wr lo=%0d hi=%0d", xr_lo, xr_hi, xw_lo, xw_hi);
    end
`endif

    localparam [15:0] T_SAT16 = 16'hFFFF;
    localparam [ 7:0] T_SAT8  = 8'hFF;
    reg [14:0] tl_mcu_prev   = 15'd0;
    reg [14:0] tl_mcu_pcmax  = 15'd0;
    reg [15:0] tl_mcu_fetch  = 16'd0;
    reg [15:0] tl_mcuw       = 16'd0;
    reg [15:0] tl_mcu_scrw   = 16'd0;
    reg [ 7:0] tl_key        = 8'd0;
    reg        tl_mcuw_prev  = 1'b0;
    reg        tl_scrw_prev  = 1'b0;
    reg        tl_key_prev   = 1'b0;
    wire       tl_mcuw_lvl   = mcu_xwr & mcu_sh;
    wire       tl_scrw_lvl   = mcu_xwr & mcu_scr;
    wire       tl_key_lvl    = sw_hi | sw_lo;

    always @(posedge clk) begin
        if (rst) begin
            tl_mcu_prev<=15'd0; tl_mcu_pcmax<=15'd0; tl_mcu_fetch<=16'd0;
            tl_mcuw<=16'd0; tl_mcu_scrw<=16'd0; tl_key<=8'd0;
            tl_mcuw_prev<=1'b0; tl_scrw_prev<=1'b0; tl_key_prev<=1'b0;
        end else begin
            tl_mcu_prev <= mcurom_addr;
            if (mcurom_addr != tl_mcu_prev && tl_mcu_fetch != T_SAT16) tl_mcu_fetch <= tl_mcu_fetch + 1'b1;
            if (mcurom_addr > tl_mcu_pcmax) tl_mcu_pcmax <= mcurom_addr;
            tl_mcuw_prev <= tl_mcuw_lvl;
            if (tl_mcuw_lvl & ~tl_mcuw_prev & (tl_mcuw != T_SAT16)) tl_mcuw <= tl_mcuw + 1'b1;
            tl_scrw_prev <= tl_scrw_lvl;
            if (tl_scrw_lvl & ~tl_scrw_prev & (tl_mcu_scrw != T_SAT16)) tl_mcu_scrw <= tl_mcu_scrw + 1'b1;
            tl_key_prev <= tl_key_lvl;
            if (tl_key_lvl & ~tl_key_prev & (shidx==14'h3e02) & (tl_key != T_SAT8)) tl_key <= tl_key + 1'b1;
        end
    end
    assign dbg_mcu_pcmax = {1'b0, tl_mcu_pcmax};
    assign dbg_mcu_fetch = tl_mcu_fetch;
    assign dbg_mcuw      = tl_mcuw;
    assign dbg_mcu_scrw  = tl_mcu_scrw;
    assign dbg_key       = tl_key;

`ifdef SIMULATION

    reg [31:0] dc=0; integer n_iack=0, n_vbl=0; reg asn_dd=1;
    always @(posedge clk) begin
        dc <= dc + 1; asn_dd <= ASn;
        if (vblank_irq) n_vbl <= n_vbl + 1;
        if ((~ASn) & asn_dd & (fc==3'd7)) n_iack <= n_iack + 1;
        if (dc[20:0]==0) $display("MAINDBG vbl=%0d iack=%0d pc=%h dataacc=%h IPLn=%b vreg=%h,%h,%h",
                                  n_vbl, n_iack, {prog_addr,1'b0}, addr, IPL_n, vregs[2], vregs[3], vregs[4]);
    end
`endif
endmodule

`default_nettype wire
