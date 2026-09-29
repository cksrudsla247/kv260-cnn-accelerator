`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench : tb_controller     (control-sequence check, no datapath)
//
//   The controller is driven with a small layer and a behavioural DMA. Nothing
//   here models the PE array or the buffers: this checks the CONTROL protocol,
//   which is where the row-streaming rewrite can go wrong.
//
//     1  the layer terminates and pulses done
//     2  acc_en and dr_en are never high together (they share the BRAM port)
//     3  every accumulate is ph=0 then ph=1 on the SAME acc_addr
//     4  acc_first is high for the first weight tile only
//     5  each slot is visited once per tile, in raster order
//     6  obuf_we is exactly one cycle behind dr_en  (the MLP->CNN trap)
//     7  mm2s bursts have the right length for their kind
//     8  s2mm emits one burst per output channel group at the right base
//
//   Layer used : 4x4 output, C/ROW_SIZE = 2, FH=FW=1, pad=0, one ft.
//   That is Conv1_1's shape in miniature - two tiles, the second accumulating.
//////////////////////////////////////////////////////////////////////////////////
module tb_controller;

    localparam ROW_SIZE  = 8;
    localparam COL_SIZE  = 32;
    localparam NB_IN     = 2;
    localparam NB_W      = 8;
    localparam NB_OUT    = 8;
    localparam ROW_BIT   = 3;
    localparam IB_A_BIT  = 5;
    localparam WB_A_BIT  = 5;
    localparam OB_A_BIT  = 6;
    localparam ACC_A_BIT = 10;
    localparam LEN_W     = 13;

    // The layer under test. Overridable from the command line so one testbench
    // covers Conv1_1 (1x1, no pad), Conv1_2 (3x3 with padding) and Conv2_1
    // (more than one output-channel tile) without three copies of this file.
    parameter CT_MAX = 1;     // C/ROW_SIZE  - 1
    parameter FT_MAX = 0;     // FN/COL_SIZE - 1
    parameter FH_MAX = 0, FW_MAX = 0, PAD = 0;
    parameter H = 4, W = 4, OH = 4, OW = 4;
    parameter POOL = 0;       // 2x2 maxpool on the drain
    localparam IN_BASE = 16'h1000, W_BASE = 16'h2000, OUT_BASE = 16'h3000;
    localparam CT_STRIDE = H*W*NB_IN;           // 32
    localparam NOUT      = POOL ? (OH/2)*(OW/2) : OH*OW;  // emitted pixels
    localparam OG_STRIDE = NOUT*NB_IN;          // output words per channel group
    localparam TILE_WORDS = ROW_SIZE*NB_W;      // 64
    localparam ROW_WORDS  = W*NB_IN;            // 8
    localparam BN_WORDS   = 432;
    localparam NPIX       = OH*OW;
    localparam GRP        = COL_SIZE/ROW_SIZE;  // output groups per ft tile
    localparam N_FT       = FT_MAX+1;
    localparam TILES_PFT  = (CT_MAX+1)*(FH_MAX+1)*(FW_MAX+1);  // tiles per ft
    localparam OB_DEPTH   = 1 << OB_A_BIT;
    localparam N_CHUNK    = (NOUT + OB_DEPTH - 1) / OB_DEPTH;  // drain chunks

    // sized copies, so the CSR words below can be built by concatenation
    localparam [7:0] H_M1 = H-1,  W_M1 = W-1, OH_M1 = OH-1, OW_M1 = OW-1;
    localparam [7:0] CT_M = CT_MAX;
    localparam [3:0] FT_M = FT_MAX;
    localparam [1:0] FH_M = FH_MAX, FW_M = FW_MAX, PAD_V = PAD;
    localparam       POOL_V = POOL[0];
    localparam [15:0] CT_STR = CT_STRIDE, OG_STR = OG_STRIDE;

    reg clk = 0, rst;
    always #5 clk = ~clk;

    reg         csr_we = 0;
    reg  [3:0]  csr_addr = 0;
    reg  [31:0] csr_data = 0;
    wire        done;

    wire                mm2s_req;
    wire [15:0]         mm2s_base;
    wire [LEN_W-1:0]    mm2s_len;
    reg                 mm2s_done;
    wire                s2mm_req;
    wire [15:0]         s2mm_base;
    wire [LEN_W-1:0]    s2mm_len;
    reg                 s2mm_done;
    reg                 strm_vld;
    reg  [31:0]         strm_data;
    reg  [LEN_W-1:0]    strm_idx;

    wire [NB_W-1:0]     wbuf_we;
    wire [NB_IN-1:0]    ibuf_we;
    wire [WB_A_BIT-1:0] wbuf_waddr;
    wire [IB_A_BIT-1:0] ibuf_waddr;
    wire [31:0]         strm_wdata;
    wire wbuf_wr_sel, wbuf_rd_sel, ibuf_wr_sel, ibuf_rd_sel;
    wire obuf_wr_sel, obuf_rd_sel;
    wire [WB_A_BIT-1:0] wbuf_raddr;
    wire [IB_A_BIT-1:0] ibuf_raddr;
    wire                ibuf_oob;
    wire                bn_rf_we;
    wire [8:0]          bn_rf_waddr, bn_group_base;
    wire                pe_w_en;
    wire [ROW_BIT-1:0]  pe_row_addr;
    wire                acc_en, acc_ph, acc_first;
    wire [ACC_A_BIT-1:0] acc_addr;
    wire                dr_en;
    wire [ACC_A_BIT-1:0] dr_addr;
    wire [3:0]          rq_shift, rq_mult;
    wire [1:0]          bn_shift;
    wire                bn_en, relu_en, wide_out, wide_half_sel;
    wire                obuf_we;
    wire [OB_A_BIT-1:0] obuf_waddr;
    wire [1:0]          wb_grp;
    wire                pool_en, pool_vld;
    wire [7:0]          pool_oh, pool_ow;

    controller #(
        .ROW_SIZE(ROW_SIZE), .COL_SIZE(COL_SIZE), .NB_IN(NB_IN), .NB_W(NB_W),
        .NB_OUT(NB_OUT), .ROW_BIT(ROW_BIT), .IB_A_BIT(IB_A_BIT),
        .WB_A_BIT(WB_A_BIT), .OB_A_BIT(OB_A_BIT), .ACC_A_BIT(ACC_A_BIT),
        .LEN_W(LEN_W)
    ) dut (
        .clk(clk), .rst(rst),
        .csr_we(csr_we), .csr_addr(csr_addr), .csr_data(csr_data), .done(done),
        .mm2s_req(mm2s_req), .mm2s_base(mm2s_base), .mm2s_len(mm2s_len),
        .mm2s_done(mm2s_done),
        .s2mm_req(s2mm_req), .s2mm_base(s2mm_base), .s2mm_len(s2mm_len),
        .s2mm_done(s2mm_done),
        .strm_vld(strm_vld), .strm_data(strm_data), .strm_idx(strm_idx),
        .wbuf_we(wbuf_we), .ibuf_we(ibuf_we),
        .wbuf_waddr(wbuf_waddr), .ibuf_waddr(ibuf_waddr),
        .strm_wdata(strm_wdata),
        .wbuf_wr_sel(wbuf_wr_sel), .wbuf_rd_sel(wbuf_rd_sel),
        .ibuf_wr_sel(ibuf_wr_sel), .ibuf_rd_sel(ibuf_rd_sel),
        .obuf_wr_sel(obuf_wr_sel), .obuf_rd_sel(obuf_rd_sel),
        .wbuf_raddr(wbuf_raddr), .ibuf_raddr(ibuf_raddr), .ibuf_oob(ibuf_oob),
        .bn_rf_we(bn_rf_we), .bn_rf_waddr(bn_rf_waddr),
        .bn_group_base(bn_group_base),
        .pe_w_en(pe_w_en), .pe_row_addr(pe_row_addr),
        .acc_en(acc_en), .acc_ph(acc_ph), .acc_first(acc_first),
        .acc_addr(acc_addr), .dr_en(dr_en), .dr_addr(dr_addr),
        .rq_shift(rq_shift), .rq_mult(rq_mult), .bn_shift(bn_shift),
        .bn_en(bn_en), .relu_en(relu_en),
        .wide_out(wide_out), .wide_half_sel(wide_half_sel),
        .pool_en(pool_en), .pool_vld(pool_vld),
        .pool_oh(pool_oh), .pool_ow(pool_ow),
        .obuf_we(obuf_we), .obuf_waddr(obuf_waddr), .wb_grp(wb_grp)
    );

    integer errors = 0;
    task fail(input [255:0] msg);
        begin errors = errors + 1; $display("  FAIL %0s  (t=%0t)", msg, $time); end
    endtask

//------------------------------------------------------------------ DMA model
//   Accepts one request at a time and finishes it len cycles later, streaming
//   strm_idx 0..len-1 so the sink logic sees a realistic burst.
    integer mm_left, mm_i;
    integer n_bn, n_tile, n_row;
    reg [15:0] last_mm_base;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mm2s_done<=0; strm_vld<=0; strm_idx<=0; strm_data<=0;
            mm_left<=0; mm_i<=0; n_bn<=0; n_tile<=0; n_row<=0;
        end else begin
            mm2s_done <= 1'b0;
            strm_vld  <= 1'b0;
            if (mm_left != 0) begin
                strm_vld  <= 1'b1;
                strm_idx  <= mm_i[LEN_W-1:0];
                strm_data <= last_mm_base + mm_i;
                mm_i      <= mm_i + 1;
                mm_left   <= mm_left - 1;
                if (mm_left == 1) mm2s_done <= 1'b1;
            // mm2s_req stays high through the done cycle, so the guard from
            // dma.v S_IDLE has to be mirrored here or one burst counts twice
            end else if (!mm2s_done && mm2s_req) begin
                mm_left      <= mm2s_len;
                mm_i         <= 0;
                last_mm_base <= mm2s_base;
                if      (mm2s_len == BN_WORDS)   n_bn   <= n_bn   + 1;
                else if (mm2s_len == TILE_WORDS) n_tile <= n_tile + 1;
                else if (mm2s_len == ROW_WORDS)  n_row  <= n_row  + 1;
                else fail("mm2s length is not BN / tile / row");
            end
        end
    end

    integer s2_left;
    integer n_s2mm;
    reg [15:0] s2_base_seen [0:255];
    integer    s2_len_seen  [0:255];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s2mm_done<=0; s2_left<=0; n_s2mm<=0;
        end else begin
            s2mm_done <= 1'b0;
            if (s2_left != 0) begin
                s2_left <= s2_left - 1;
                if (s2_left == 1) s2mm_done <= 1'b1;
            end else if (!s2mm_done && s2mm_req) begin
                s2_left <= s2mm_len;
                if (n_s2mm < 256) begin
                    s2_base_seen[n_s2mm] = s2mm_base;
                    s2_len_seen [n_s2mm] = s2mm_len;
                end
                n_s2mm <= n_s2mm + 1;
            end
        end
    end

//------------------------------------------------------------------ checkers
    // 2  the accumulator port is shared : never both
    always @(posedge clk) if (!rst && acc_en && dr_en) fail("acc_en with dr_en");

    // 3/4/5  accumulate protocol : ph0 then ph1 on the same address, in order
    reg                  seen_ph0;
    reg [ACC_A_BIT-1:0]  ph0_addr;
    reg [ACC_A_BIT-1:0]  exp_slot;
    integer              n_acc_write, n_first_write;

    initial begin
        seen_ph0=0; ph0_addr=0; exp_slot=0; n_acc_write=0; n_first_write=0;
    end

    always @(posedge clk) if (!rst && acc_en) begin
        if (!acc_ph) begin
            if (acc_first) begin
                if (acc_addr !== exp_slot) fail("acc_first slot out of order");
                exp_slot      = (exp_slot == NPIX-1) ? 0 : exp_slot + 1;
                n_acc_write   = n_acc_write + 1;
                n_first_write = n_first_write + 1;
            end else begin
                if (seen_ph0) fail("two ph=0 in a row without a ph=1");
                seen_ph0 = 1'b1;
                ph0_addr = acc_addr;
                if (acc_addr !== exp_slot) fail("rmw slot out of order");
            end
        end else begin
            if (!seen_ph0)             fail("ph=1 without a preceding ph=0");
            if (acc_addr !== ph0_addr) fail("ph=1 address differs from ph=0");
            seen_ph0    = 1'b0;
            exp_slot    = (exp_slot == NPIX-1) ? 0 : exp_slot + 1;
            n_acc_write = n_acc_write + 1;
        end
    end

    // 6  obuf_we must lag dr_en by exactly one cycle, with the matching row
    reg                 dr_emit_d1;
    reg [OB_A_BIT-1:0]  out_row_d1;
    integer             n_drain, n_obuf;

    initial begin dr_emit_d1=0; out_row_d1=0; n_drain=0; n_obuf=0; end

    always @(posedge clk) if (!rst) begin
        if (obuf_we !== dr_emit_d1)
            fail("obuf_we is not (dr_en and emit) delayed one cycle");
        if (obuf_we && (obuf_waddr !== out_row_d1))
            fail("obuf_waddr does not match the emitted pixel index");
        dr_emit_d1 <= dr_en && dut.dr_emit;
        out_row_d1 <= dut.out_row;
        if (dr_en)   n_drain = n_drain + 1;
        if (obuf_we) n_obuf  = n_obuf  + 1;
    end


//------------------------------------------------------------------ 9  ranges
//   Every buffer address the controller can generate is tracked, so "the IPs
//   are big enough" is measured rather than asserted.
    integer max_ibw, max_wbw, max_obw, max_acc, max_dra, max_ibr;
    // start at 0, NOT -1 : these are compared against unsigned wires, and a
    // signed -1 promotes to 4294967295 there, so nothing would ever exceed it.
    // Address 0 is always used, so max+1 is still the true count.
    initial begin
        max_ibw=0; max_wbw=0; max_obw=0; max_acc=0; max_dra=0; max_ibr=0;
    end
    always @(posedge clk) if (!rst) begin
        if (|ibuf_we && ibuf_waddr > max_ibw) max_ibw = ibuf_waddr;
        if (|wbuf_we && wbuf_waddr > max_wbw) max_wbw = wbuf_waddr;
        if (obuf_we  && obuf_waddr > max_obw) max_obw = obuf_waddr;
        if (acc_en   && acc_addr   > max_acc) max_acc = acc_addr;
        if (dr_en    && dr_addr    > max_dra) max_dra = dr_addr;
        if ((dut.state_q == 5'd11) && !ibuf_oob && ibuf_raddr > max_ibr)
            max_ibr = ibuf_raddr;      // ST_PIX_WR : an address actually used
    end

    // how much of the run the DMA actually has work to do. Everything else is
    // the port sitting idle while the controller is between requests, which is
    // the only thing a request queue could ever recover.
    integer dma_busy, s2_busy;
    initial begin dma_busy=0; s2_busy=0; end
    always @(posedge clk) if (!rst) begin
        if (mm_left != 0) dma_busy = dma_busy + 1;
        if (s2_left != 0) s2_busy  = s2_busy  + 1;
    end

    task report_ranges;
        begin
            $display("------------------------------------------------");
            $display("  buffer          used / depth");
            $display("   ibuf write      %4d / %4d", max_ibw+1, 1<<IB_A_BIT);
            $display("   ibuf read       %4d / %4d", max_ibr+1, 1<<IB_A_BIT);
            $display("   wbuf            %4d / %4d", max_wbw+1, 1<<WB_A_BIT);
            $display("   obuf            %4d / %4d", max_obw+1, 1<<OB_A_BIT);
            $display("   accumulator     %4d / %4d", max_acc+1, 1<<ACC_A_BIT);
            $display("  DMA port busy    : mm2s %0d + s2mm %0d of %0d cycles (%0d%%)",
                     dma_busy, s2_busy, cyc, (100*(dma_busy+s2_busy))/cyc);
            if (max_ibw+1 > (1<<IB_A_BIT)) fail("ibuf write overflows depth");
            if (max_ibr+1 > (1<<IB_A_BIT)) fail("ibuf read overflows depth");
            if (max_wbw+1 > (1<<WB_A_BIT)) fail("wbuf overflows depth");
            if (max_obw+1 > (1<<OB_A_BIT)) fail("obuf overflows depth");
            if (max_acc+1 > (1<<ACC_A_BIT)) fail("accumulator overflows depth");
            if (max_dra   > max_acc)        fail("drain reads past the last slot");
        end
    endtask

//------------------------------------------------------------------ program
    task csr(input [3:0] a, input [31:0] d);
        begin
            @(negedge clk);
            csr_addr = a; csr_data = d; csr_we = 1'b1;
            @(negedge clk);
            csr_we = 1'b0;
        end
    endtask

    integer cyc;
    always @(posedge clk) if (!rst) cyc = cyc + 1;

    integer g, f, c, b, pix, ohv, fhv, fwv, ctv, inh;
    integer exp_rows, exp_base;
    integer timeout;

    initial begin
        rst = 1'b1; cyc = 0; timeout = 0;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        // a row is fetched once per (ft,ct,fh,fw,oh) unless oh+fh-pad
        // falls outside the input, in which case the mask feeds zeros
        // and the load is skipped
        exp_rows = 0;
        for (f = 0; f < N_FT; f = f+1)
         for (ctv = 0; ctv <= CT_MAX; ctv = ctv+1)
          for (fhv = 0; fhv <= FH_MAX; fhv = fhv+1)
           for (fwv = 0; fwv <= FW_MAX; fwv = fwv+1)
            for (ohv = 0; ohv < OH; ohv = ohv+1) begin
                inh = ohv + fhv - PAD;
                if (inh >= 0 && inh < H) exp_rows = exp_rows + 1;
            end

        $display("================================================");
        $display("  %0dx%0d out, ct %0d, ft %0d, %0dx%0d pad %0d, pool %0d -> %0d px",
                 OH, OW, CT_MAX+1, FT_MAX+1, FH_MAX+1, FW_MAX+1, PAD, POOL, NOUT);
        $display("================================================");

        // CSR0 : ct_max | fh_max | fw_max | ft_max | pool bn relu wide | pad
        csr(4'd0, {10'd0, PAD_V, 1'b0, 1'b1, 1'b1, POOL_V,
                   FT_M, FW_M, FH_M, CT_M});
        // CSR1 : h_max | w_max | oh_max | ow_max
        csr(4'd1, {OW_M1, OH_M1, W_M1, H_M1});
        csr(4'd2, {16'd0, IN_BASE});
        csr(4'd3, H*W*(CT_MAX+1)*NB_IN);
        csr(4'd4, {16'd0, W_BASE});
        csr(4'd5, {16'd0, OUT_BASE});
        csr(4'd6, OH*OW*GRP*NB_IN);
        csr(4'd8, {19'd0, 5'd0, 4'd2, 4'd3});
        csr(4'd9, {OG_STR, CT_STR});
        csr(4'd7, 32'd1);                       // start

        while (!done && timeout < 2000000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (timeout >= 2000000) fail("layer did not finish");
        repeat (4) @(negedge clk);

        $display("  cycles           : %0d", cyc);
        $display("  mm2s  BN/tile/row: %0d / %0d / %0d", n_bn, n_tile, n_row);
        $display("  acc writes       : %0d  (first-tile loads %0d)",
                 n_acc_write, n_first_write);
        $display("  drain reads      : %0d   obuf writes %0d", n_drain, n_obuf);
        $display("  s2mm bursts      : %0d", n_s2mm);
        report_ranges;

        if (n_bn   !== 1)                  fail("BN load did not happen once");
        if (n_tile !== TILES_PFT*N_FT)     fail("wrong number of weight tiles");
        if (n_row  !== exp_rows)           fail("wrong number of input row loads");

        if (n_acc_write   !== NPIX*TILES_PFT*N_FT) fail("wrong accumulate count");
        if (n_first_write !== NPIX*N_FT)           fail("acc_first count wrong");

        if (n_drain !== NPIX*N_FT) fail("drain did not cover every pixel");
        if (n_obuf  !== NOUT*N_FT) fail("obuf write count is not the pooled size");

        // one burst per (ft, chunk, channel group), each contiguous in DRAM at
        // out_base + (ft*GRP + g)*og_stride + chunk_first*NB_IN
        if (n_s2mm !== N_CHUNK*GRP*N_FT)
            fail("wrong number of s2mm bursts");
        else begin
            b = 0;
            for (f = 0; f < N_FT; f = f+1)
              for (c = 0; c < N_CHUNK; c = c+1) begin
                pix = (c == N_CHUNK-1) ? (NOUT - c*OB_DEPTH) : OB_DEPTH;
                for (g = 0; g < GRP; g = g+1) begin
                    exp_base = OUT_BASE + (f*GRP + g)*OG_STRIDE
                                        + c*OB_DEPTH*NB_IN;
                    if (s2_base_seen[b] !== exp_base) begin
                        errors = errors + 1;
                        $display("  FAIL s2mm[%0d] ft%0d ch%0d grp%0d base : exp %0h got %0h",
                                 b, f, c, g, exp_base, s2_base_seen[b]);
                    end
                    if (s2_len_seen[b] !== pix*NB_IN) begin
                        errors = errors + 1;
                        $display("  FAIL s2mm[%0d] len : expected %0d got %0d",
                                 b, pix*NB_IN, s2_len_seen[b]);
                    end
                    b = b + 1;
                end
              end
        end

        $display("================================================");
        if (errors == 0) $display("  PASS   control sequence clean");
        else             $display("  FAIL   %0d problems", errors);
        $display("================================================");
        $finish;
    end

endmodule
