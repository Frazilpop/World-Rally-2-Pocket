// SPDX-License-Identifier: GPL-3.0-or-later
// World Rally 2 (Pocket) — whole-board harness.
//
//   tb_wrally2 <set.rom> <frames> <outdir> [dump frames, comma list]
//       [--rom-lat N] [--trace file] [--trace-count N] [--trace-from F]
//       [--mcu-trace file]
//       [--mcu-sram] [--inputs plan.txt] [--dsw hex] [--wheel hex]
//       [--release N] [--gen-dir dir] [--ticks file]
//
// Hosts wrally2_board the way the Pocket shell does, with behavioural
// memories:
//
//   SDRAM   the .rom image; four independent line ports, fixed latency
//           (--rom-lat, 48 MHz clocks). Optimistic: no contention, no
//           refresh. It answers "does the board work", not "does it fit
//           the bandwidth".
//
// The loader snoop is fed the ds5002 slot before reset is released, as the
// Pocket's loader passes it. The CPUs are then released --release clocks
// after the video's vblank (default 0): IRQ 6 is the board's own, counted
// in 68000 clocks from reset (IRQ_FIRST in sim/wrally2/build.sh), so this
// only places the picture against it.
//
// --trace writes the 68000's bus cycles in tools/mame_wrally2_bus_trace.lua's
// format, one line per cycle as it ends (IACK cycles left out, as MAME has
// none), with "# frame N" at each vblank IRQ. --mcu-trace (default: the
// trace's name + ".mcu") writes the DS5002FP's MOVX accesses to the shared
// RAM, "<n68k> <t13> <addr> <R|W> <data>", as the Lua script does; with
// --mcu-sram its own SRAM's too (addr + 0x10000). --trace-from F starts both
// at frame F's IRQ ("# frame F" first), as the Lua script's BUS_TRACE_FROM.
//
// Writes frame_NNNNN.ppm (384 x 240) for each requested frame and one line
// a frame to stats.csv.

#include "Vwrally2_board.h"
#include "Vwrally2_board___024root.h"
#include "verilated.h"

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <set>
#include <sys/stat.h>
#include <unistd.h>

static const int NP = 4;
static const int SDR_AW = 25;


template <typename W>
static uint64_t getbits(const W& w, int lo, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) {
        int b = lo + i;
        if ((w[b >> 5] >> (b & 31)) & 1) v |= 1ull << i;
    }
    return v;
}
template <typename W>
static void setbits(W& w, int lo, int n, uint64_t v) {
    for (int i = 0; i < n; i++) {
        int b = lo + i;
        if ((v >> i) & 1) w[b >> 5] |= (1u << (b & 31));
        else              w[b >> 5] &= ~(1u << (b & 31));
    }
}

static std::string absolute(const char* p) {
    if (!p) return "";
    if (p[0] == '/') return p;
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd)) return p;
    return std::string(cwd) + "/" + p;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s set.rom frames outdir [dumps] [--rom-lat N] [--trace f] "
                        "[--trace-count N] [--mcu-trace f] [--mcu-sram] [--inputs plan] "
                        "[--dsw hex] [--wheel hex] [--release N] [--gen-dir d]\n", argv[0]);
        return 2;
    }
    std::string rom_path = absolute(argv[1]);
    int frames = atoi(argv[2]);
    std::string outdir = absolute(argv[3]);
    std::set<int> dumps;
    int rom_lat = 10;
    std::string trace_path, mcu_path, ticks_path, inputs_path, gen_dir = absolute("build/gen");
    long trace_count = 0;
    int trace_from = 0;
    bool mcu_sram = false;
    unsigned dsw = 0xddff, wheel = 0x8a;
    long long release = 0;
    for (int i = 4; i < argc; i++) {
        if (!strcmp(argv[i], "--rom-lat") && i + 1 < argc)          rom_lat = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc)       trace_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--trace-count") && i + 1 < argc) trace_count = atol(argv[++i]);
        else if (!strcmp(argv[i], "--trace-from") && i + 1 < argc)  trace_from = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mcu-trace") && i + 1 < argc)   mcu_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--ticks") && i + 1 < argc)       ticks_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--mcu-sram"))                    mcu_sram = true;
        else if (!strcmp(argv[i], "--inputs") && i + 1 < argc)      inputs_path = absolute(argv[++i]);
        else if (!strcmp(argv[i], "--dsw") && i + 1 < argc)         dsw = strtoul(argv[++i], 0, 16);
        else if (!strcmp(argv[i], "--wheel") && i + 1 < argc)       wheel = strtoul(argv[++i], 0, 16);
        else if (!strcmp(argv[i], "--release") && i + 1 < argc)     release = atoll(argv[++i]);
        else if (!strcmp(argv[i], "--gen-dir") && i + 1 < argc)     gen_dir = absolute(argv[++i]);
        else {
            std::string s = argv[i];
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(',', p);
                if (q == std::string::npos) q = s.size();
                if (q > p) dumps.insert(atoi(s.substr(p, q - p).c_str()));
                p = q + 1;
            }
        }
    }
    if (!trace_path.empty() && mcu_path.empty()) mcu_path = trace_path + ".mcu";
    mkdir(outdir.c_str(), 0755);

    // -------------------------------------------------------------- memories
    std::vector<uint8_t> rom;
    {
        FILE* f = fopen(rom_path.c_str(), "rb");
        if (!f) { perror(rom_path.c_str()); return 1; }
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        rom.resize(n);
        if (fread(rom.data(), 1, n, f) != (size_t)n) { perror("read"); return 1; }
        fclose(f);
    }
    rom.resize(64u << 20, 0);
    auto rom_word = [&](uint32_t w) -> uint16_t {
        return (uint16_t)rom[2 * w] | ((uint16_t)rom[2 * w + 1] << 8);
    };

    // The GAE1's $readmemh("volume_table.mem") is relative: run from there.
    if (chdir(gen_dir.c_str()) != 0) { perror(gen_dir.c_str()); return 1; }

    Verilated::commandArgs(argc, argv);
    Vwrally2_board* t = new Vwrally2_board;
    auto& R = *t->rootp;

    t->rst = 1; t->rom_loaded = 0;
    t->p1 = 0; t->p2 = 0; t->coin = 0; t->start = 0; t->service = 0; t->test = 0;
    t->dsw = dsw; t->wheel1 = wheel; t->wheel2 = wheel;
    t->pause = 0;
    t->dl_wr = 0;

    uint64_t cyc = 0;
    // One 48 MHz clock: both clocks rise together, clk96 rises again halfway.
    auto tick = [&]() {
        t->clk = 1; t->clk96 = 1; t->eval();
        t->clk96 = 0; t->eval();
        t->clk = 0; t->clk96 = 1; t->eval();
        t->clk96 = 0; t->eval();
        cyc++;
    };

    // ----------------------------------------------------------- ROM ports
    struct Port { int busy = 0; int cnt = 0; uint32_t addr = 0; };
    Port rp[NP];
    auto serve_rom = [&]() {
        uint32_t req = t->rom_req;
        uint32_t ack = 0;
        for (int p = 0; p < NP; p++) {
            Port& P = rp[p];
            if (!P.busy && ((req >> p) & 1)) {
                P.busy = 1; P.cnt = rom_lat;
                P.addr = (uint32_t)getbits(t->rom_addr, p * SDR_AW, SDR_AW);
            }
            if (P.busy && --P.cnt <= 0) {
                ack |= 1u << p;
                uint32_t w = P.addr & ~3u;
                for (int k = 0; k < 4; k++)
                    setbits(t->rom_dout, p * 64 + k * 16, 16, rom_word(w + k));
                P.busy = 0;
            }
        }
        t->rom_ack = ack;
    };

    // Power-on: a few clocks of reset, then the ds5002 slot through the snoop
    // (every other clock, as the board asks), video running throughout.
    for (int i = 0; i < 16; i++) tick();
    t->rst = 0;
    for (uint32_t w = 0x80000; w < 0x84000; w++) {
        t->dl_wr = 1; t->dl_addr = w; t->dl_data = rom_word(w);
        tick();
        t->dl_wr = 0;
        tick();
    }
    // Release the CPUs `release` clocks after a vblank IRQ.
    {
        bool seen = false;
        uint64_t at = 0;
        while (!seen) { tick(); if (R.wrally2_board__DOT__dbg_vbirq) { seen = true; at = cyc; } }
        while (cyc < at + (uint64_t)release) tick();
    }
    t->rom_loaded = 1;
    const uint64_t cyc0 = cyc;
    fprintf(stderr, "CPUs released at clock %llu\n", (unsigned long long)cyc0);

    // ------------------------------------------------------------ inputs
    // One line a frame, "<frame> coin=1 start=1 b1=1 right=0 ...", applied at
    // the start of the numbered frame (counting vblank IRQs from release).
    struct Step { int frame; std::string name; int val; };
    std::vector<Step> plan;
    size_t plan_i = 0;
    if (!inputs_path.empty()) {
        FILE* f = fopen(inputs_path.c_str(), "r");
        if (!f) { perror(inputs_path.c_str()); return 1; }
        char line[512];
        while (fgets(line, sizeof line, f)) {
            char* save = nullptr;
            char* tok = strtok_r(line, " \t\r\n", &save);
            if (!tok || tok[0] == '#') continue;
            int fr = atoi(tok);
            while ((tok = strtok_r(nullptr, " \t\r\n", &save))) {
                char* eq = strchr(tok, '=');
                if (!eq) continue;
                *eq = 0;
                plan.push_back({fr, tok, atoi(eq + 1)});
            }
        }
        fclose(f);
        fprintf(stderr, "inputs: %zu steps from %s\n", plan.size(), inputs_path.c_str());
    }
    uint8_t p1v = 0;
    auto apply_inputs = [&](int fr) {
        while (plan_i < plan.size() && plan[plan_i].frame <= fr) {
            const Step& st = plan[plan_i++];
            int bit = -1;
            // p1 = {b2, b1, up, down, left, right}
            if      (st.name == "right") bit = 0;
            else if (st.name == "left")  bit = 1;
            else if (st.name == "down")  bit = 2;
            else if (st.name == "up")    bit = 3;
            else if (st.name == "b1")    bit = 4;
            else if (st.name == "b2")    bit = 5;
            else if (st.name == "coin")  { t->coin  = st.val ? 1 : 0; continue; }
            else if (st.name == "start") { t->start = st.val ? 1 : 0; continue; }
            else if (st.name == "pause") { t->pause = st.val ? 1 : 0; continue; }
            if (bit >= 0) {
                if (st.val) p1v |= (1u << bit); else p1v &= ~(1u << bit);
                t->p1 = p1v;
            }
        }
    };
    apply_inputs(0);

    // ------------------------------------------------------------ traces
    FILE* trace = trace_path.empty() ? nullptr : fopen(trace_path.c_str(), "w");
    FILE* mtrace = (trace && mcu_path != "none") ? fopen(mcu_path.c_str(), "w") : nullptr;
    long traced = 0, mtraced = 0;
    bool tracing = trace_from <= 0;
    // --ticks: the 68000 clock (board time since release) at the end of each
    // traced access, one line each, and "# irq <clock>" at each IRQ 6
    FILE* ticks = ticks_path.empty() ? nullptr : fopen(ticks_path.c_str(), "w");
    uint64_t bclk = 0;
    // the 68000: the bus cycle's last clock before AS rises
    bool as_prev = false;
    uint32_t c_addr = 0, c_data = 0, c_mask = 0; bool c_rd = false;
    // the DS5002: an access is a run of clocks with the same address and
    // direction; reads keep the byte the core latched last
    bool x_prev = false; uint32_t x_addr = 0; bool x_wr = false; uint32_t x_data = 0;
    uint64_t x_start = 0; long x_n68 = 0;
    auto mcu_flush = [&]() {
        if (!mtrace || !tracing) return;
        bool shared = x_addr & 0x8000;
        if (!shared && !mcu_sram) return;
        uint32_t a = shared ? x_addr : (x_addr + 0x10000);
        uint64_t t13 = x_start;     // board time: 68000 clocks since release, MAME's 13 MHz
        fprintf(mtrace, "%ld %llu %05x %c %02x\n", x_n68, (unsigned long long)t13, a,
                x_wr ? 'W' : 'R', x_data & 0xff);
        mtraced++;
    };

    // ------------------------------------------------------------- video
    std::vector<uint8_t> img(384 * 240 * 3, 0);
    int x = 0, y = 0, frame = 0;
    int prev_hb = 1, prev_vb = 1;
    FILE* stats = fopen((outdir + "/stats.csv").c_str(), "w");
    fprintf(stats, "frame,cycles,bus_cycles,mcu_accesses\n");
    uint64_t bus_cycles = 0, bus_cycles_f = 0;
    long mcu_f = 0;
    bool irq_prev = false;

    while (frame < frames) {
        serve_rom();
        tick();
        bclk += R.wrally2_board__DOT__dbg_cen;
        if (ticks && R.wrally2_board__DOT__dbg_irq) fprintf(ticks, "# irq %llu\n", (unsigned long long)bclk);

        // ---- 68000 bus monitor
        {
            bool as = R.wrally2_board__DOT__dbg_as;
            if (as) {
                c_addr = (uint32_t)R.wrally2_board__DOT__dbg_eab << 1;
                c_rd   = R.wrally2_board__DOT__dbg_rw;
                uint32_t ds = R.wrally2_board__DOT__dbg_ds;
                c_mask = (ds == 3) ? 0xffff : (ds == 2) ? 0xff00 : (ds == 1) ? 0x00ff : 0;
                c_data = c_rd ? R.wrally2_board__DOT__dbg_din : R.wrally2_board__DOT__dbg_dout;
            }
            if (!as && as_prev) {
                bus_cycles++;
                if (trace && tracing && c_mask) {
                    fprintf(trace, "%06x %c %04x %04x\n", c_addr, c_rd ? 'R' : 'W', c_data & c_mask, c_mask);
                    traced++;
                    if (ticks) fprintf(ticks, "%llu\n", (unsigned long long)bclk);
                    if (trace_count > 0 && traced >= trace_count) {
                        fclose(trace); trace = nullptr;
                        if (mtrace) { fclose(mtrace); mtrace = nullptr; }
                    }
                }
            }
            as_prev = as;
        }
        // ---- DS5002 MOVX monitor
        {
            bool acc = R.wrally2_board__DOT__dbg_x_rd || R.wrally2_board__DOT__dbg_x_wr;
            uint32_t a = R.wrally2_board__DOT__dbg_x_addr;
            bool wr = R.wrally2_board__DOT__dbg_x_wr;
            if (x_prev && (!acc || a != x_addr || wr != x_wr)) mcu_flush();
            if (acc && (!x_prev || a != x_addr || wr != x_wr)) {
                x_addr = a; x_wr = wr; x_start = bclk; x_n68 = traced;
            }
            if (acc) x_data = wr ? R.wrally2_board__DOT__dbg_x_dout : R.wrally2_board__DOT__dbg_x_din;
            x_prev = acc;
        }

        // ---- frames: MAME marks its frame at the vblank IRQ
        {
            bool irq = R.wrally2_board__DOT__dbg_irq;
            if (irq && !irq_prev) {
                if (frame + 1 >= trace_from) tracing = true;
                if (trace && tracing) fprintf(trace, "# frame %d\n", frame + 1);
                fprintf(stats, "%d,%llu,%llu,%ld\n", frame, (unsigned long long)(cyc - cyc0),
                        (unsigned long long)(bus_cycles - bus_cycles_f), mtraced - mcu_f);
                bus_cycles_f = bus_cycles; mcu_f = mtraced;
                fflush(stats);
                if (frame % 10 == 0)
                    fprintf(stderr, "frame %d of %d  (%ld accesses traced)\n", frame, frames, traced);
                frame++;
                apply_inputs(frame);
            }
            irq_prev = irq;
        }

        // ---- video capture
        if (t->ce_pix) {
            int hb = t->hblank, vb = t->vblank;
            if (!hb && !vb) {
                if (x < 384 && y < 240) {
                    uint8_t* px = &img[(y * 384 + x) * 3];
                    px[0] = (t->r << 3) | (t->r >> 2);
                    px[1] = (t->g << 3) | (t->g >> 2);
                    px[2] = (t->b << 3) | (t->b >> 2);
                }
                x++;
            }
            if (hb && !prev_hb && !vb) { y++; x = 0; }
            if (vb && !prev_vb) {
                if (dumps.count(frame)) {
                    char fn[1024];
                    snprintf(fn, sizeof fn, "%s/frame_%05d.ppm", outdir.c_str(), frame);
                    FILE* f = fopen(fn, "wb");
                    fprintf(f, "P6\n384 240\n255\n");
                    fwrite(img.data(), 1, img.size(), f);
                    fclose(f);
                }
                y = 0; x = 0;
            }
            prev_hb = hb; prev_vb = vb;
        }
    }

    if (trace) fclose(trace);
    if (mtrace) fclose(mtrace);
    if (ticks) fclose(ticks);
    fclose(stats);
    fprintf(stderr, "%d frames, %ld 68000 accesses and %ld DS5002 accesses traced, %llu clocks\n",
            frames, traced, mtraced, (unsigned long long)(cyc - cyc0));
    t->final();
    delete t;
    return 0;
}
