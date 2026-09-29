`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_top : core + dma + tester end-to-end, 5-layer bit-exact check.
//
//   The DRAM (blk_mem_gen `dram` inside the tester) starts empty. The tb loads
//   the whole image through the tester's host port, one word per cycle, exactly
//   the way the PS would write it into DDR in silicon. No COE, no IP re-gen :
//   rerun the generator and the next simulation picks the new image up.
//
//   Files : dram.txt (image) / gold.txt / gold_addr.txt
//
//   Output : per-layer cycle counts, stall totals, and the bit-exact verdict.
//////////////////////////////////////////////////////////////////////////////////
module tb_top;
 
    // MUST match the `dram` IP depth. The CNN needs 60,352 words (43,904 of
    // weights alone), so the IP has to be regenerated at 65,536 - which is also
    // the ceiling, because every DRAM address in this design is [15:0].
    localparam DRAM_DEPTH = 65536;
    localparam GMAX       = 8192;    // Conv1_1 alone emits 6,272 words
    localparam LEN_W      = 13;      // burst length / word index
 
    reg clk, rst;
    always #5 clk = ~clk;            // 100 MHz
    
    reg dram_rdy_d;
    always @(posedge clk or posedge rst)
        if (rst) dram_rdy_d <= 1'b0;
        else     dram_rdy_d <= dram_en;   // tester's blk_mem_gen: fixed 1-cycle latency
 
    // descriptor handshake, core -> dma
    wire        mm2s_req, s2mm_req;
    wire [15:0] mm2s_base, s2mm_base;
    wire [LEN_W-1:0] mm2s_len, s2mm_len;
    wire        mm2s_done, s2mm_done;
 
    // inbound word stream, dma -> core
    wire        strm_vld;
    wire [31:0] strm_data;
    wire [LEN_W-1:0] strm_idx;
 
    // writeback word request, dma -> core -> dma
    wire        wb_req;
    wire [LEN_W-1:0] wb_idx;
    wire [31:0] wb_data;
 
    // DRAM port, dma <-> tester
    wire        dram_en, dram_we;
    wire [15:0] dram_addr;
    wire [31:0] dram_wdata, dram_rdata;
    wire        dram_rdy;         
 
    // CSR, tester -> core
    wire        csr_we;
    wire [3:0]  csr_addr;
    wire [31:0] csr_data;
    wire        core_done;    // one pulse per layer
    wire        all_done;     // whole CSR program finished
 
    // host port into the tester's DRAM : the tb plays the role of the PS
    reg         h_en, h_we, tgo;
    reg  [15:0] h_addr;
    reg  [31:0] h_wdata;
    wire [31:0] h_rdata;
 
    core u_core (
        .clk(clk), .rst(rst),
        .csr_we(csr_we), .csr_addr(csr_addr), .csr_data(csr_data), .done(core_done),
        .mm2s_req(mm2s_req), .mm2s_base(mm2s_base), .mm2s_len(mm2s_len),
        .mm2s_done(mm2s_done),
        .strm_vld(strm_vld), .strm_data(strm_data), .strm_idx(strm_idx),
        .s2mm_req(s2mm_req), .s2mm_base(s2mm_base), .s2mm_len(s2mm_len),
        .s2mm_done(s2mm_done),
        .wb_req(wb_req), .wb_idx(wb_idx), .wb_data(wb_data)
    );
 
    dma u_dma (
        .clk(clk), .rst(rst),
        .mm2s_req(mm2s_req), .mm2s_base(mm2s_base), .mm2s_len(mm2s_len),
        .mm2s_done(mm2s_done),
        .s2mm_req(s2mm_req), .s2mm_base(s2mm_base), .s2mm_len(s2mm_len),
        .s2mm_done(s2mm_done),
        .strm_vld(strm_vld), .strm_data(strm_data), .strm_idx(strm_idx),
        .wb_req(wb_req), .wb_idx(wb_idx), .wb_data(wb_data),
        .dram_en(dram_en), .dram_we(dram_we), .dram_addr(dram_addr),
        .dram_wdata(dram_wdata), .dram_rdata(dram_rdata),
        .dram_rdy(dram_rdy_d)
    );
 
    tester u_tester (
        .clk(clk), .rst(rst),
        .h_en(h_en), .h_we(h_we), .h_addr(h_addr),
        .h_wdata(h_wdata), .h_rdata(h_rdata),
        .go(tgo),
        .dram_en(dram_en), .dram_we(dram_we), .dram_addr(dram_addr),
        .dram_wdata(dram_wdata), .dram_rdata(dram_rdata),
        .csr_we(csr_we), .csr_addr(csr_addr), .csr_data(csr_data),
        .core_done(core_done), .all_done(all_done)
    );
 
    reg [31:0] dimg   [0:DRAM_DEPTH-1];  // image staged here, then written in
    reg [31:0] golden [0:GMAX-1];        // expected output words
    reg [15:0] gaddr  [0:GMAX-1];        // their DRAM addresses
    reg [31:0] rdw;                      // one word read back
    integer i, errors, gn;               // loop var, mismatch count, gold count
 
//---------------------------------------------------------------- host tasks
    // Stream the image in, one word per clock. h_* are driven off negedge so
    // they are stable well before the edge the BRAM latches them on.
    task dram_load;
        integer a;
    begin
        @(negedge clk);
        h_we = 1'b1;
        for (a = 0; a < DRAM_DEPTH; a = a + 1) begin
            h_en    = 1'b1;
            h_addr  = a[15:0];
            h_wdata = dimg[a];
            @(posedge clk);
            #1;
        end
        h_en = 1'b0; h_we = 1'b0;
    end
    endtask
 
    // Read one word back. BRAM latency 1 : address on one edge, data the next.
    task dram_read(input [15:0] a, output [31:0] d);
    begin
        @(negedge clk);
        h_en = 1'b1; h_we = 1'b0; h_addr = a;
        @(posedge clk);          // BRAM samples the address here
        @(negedge clk);          // douta valid now
        h_en = 1'b0;
        d = h_rdata;
    end
    endtask
 
//---------------------------------------------------------------- measurement
    // States are referenced by name, not by raw code, so renumbering the FSM
    // does not require touching this file. The MLP-era ST_CDONE / ST_IN_WAIT
    // are gone; the row-streaming controller stalls in different places:
    //   ROW_WAIT : blocking load of the first input row of a tile sweep
    //   ROW_END  : waiting for the next row's prefetch to land
    //   TILE_END : waiting for the next weight tile's prefetch
    //   OUT_WAIT : waiting for an s2mm chunk to drain
    // dma_busy is the honest number: every layer here is DMA-bound, so the
    // interesting figure is how much of the run the port had work to do.
    integer st_row_wait, st_row_end, st_tile_end, st_out_wait, dma_busy;
    initial begin
        st_row_wait=0; st_row_end=0; st_tile_end=0; st_out_wait=0; dma_busy=0;
    end
 
    always @(posedge clk) if (!rst) begin
        if (u_core.u_ctrl.state_q == u_core.u_ctrl.ST_ROW_WAIT)
            st_row_wait = st_row_wait + 1;
        if (u_core.u_ctrl.state_q == u_core.u_ctrl.ST_ROW_END)
            st_row_end  = st_row_end  + 1;
        if (u_core.u_ctrl.state_q == u_core.u_ctrl.ST_TILE_END)
            st_tile_end = st_tile_end + 1;
        if (u_core.u_ctrl.state_q == u_core.u_ctrl.ST_OUT_WAIT)
            st_out_wait = st_out_wait + 1;
        if (u_core.u_ctrl.mm2s_busy || u_core.u_ctrl.s2mm_busy)
            dma_busy    = dma_busy    + 1;
        if (core_done)
            $display("  [stall] ROW_WAIT=%0d ROW_END=%0d TILE_END=%0d OUT_WAIT=%0d  DMA busy=%0d",
                     st_row_wait, st_row_end, st_tile_end, st_out_wait, dma_busy);
    end
 
    // per-layer cycle count : start_pulse to core_done
    integer cyc, lyr, tot;
    integer fd;
    reg [31:0] t_start;
    initial begin cyc = 0; lyr = 0; tot = 0; t_start = 0; end
 
    always @(posedge clk) if (!rst) cyc <= cyc + 1;
 
    always @(posedge clk) if (!rst) begin
        if (u_core.u_ctrl.start_pulse) t_start <= cyc;
        if (core_done) begin
            lyr = lyr + 1;
            tot = tot + (cyc - t_start);
            $display("===== LAYER %0d : %0d cycles (cum %0d) =====",
                     lyr, cyc - t_start, tot);
        end
    end
 
//---------------------------------------------------------------- main
    initial begin
        clk = 0; rst = 1; errors = 0;
        h_en = 0; h_we = 0; h_addr = 0; h_wdata = 0; tgo = 0;
 
        for (i = 0; i < DRAM_DEPTH; i = i + 1) dimg[i] = 32'd0;
        for (i = 0; i < GMAX; i = i + 1) begin
            golden[i] = 32'hx; gaddr[i] = 16'hffff;   // ffff = unused entry
        end
 
        $readmemh("dram.txt",      dimg);
        $readmemh("gold.txt",      golden);
        $readmemh("gold_addr.txt", gaddr);
 
        gn = 0;
        for (i = 0; i < GMAX; i = i + 1) if (gaddr[i] !== 16'hffff) gn = gn + 1;
 
        repeat (5) @(posedge clk); rst = 0; @(posedge clk);
 
        dram_load;
        $display("[TB] DRAM image loaded (%0d words)", DRAM_DEPTH);
 
        @(posedge clk);
        tgo = 1'b1; @(posedge clk); tgo = 1'b0;   // kick the CSR sequencer
 
        i = 0;
        while (!all_done && i < 2000000) begin @(posedge clk); i = i + 1; end
        if (i >= 2000000) begin $display("TIMEOUT"); $finish; end
        $display("all_done cyc=%0d, comparing %0d gold words...", i, gn);
 
        // dump every compared word so a failure can be analysed offline:
        // which pixels, channels and rows are wrong is the whole diagnosis,
        // and 24 $display lines never show that.
        fd = $fopen("got.txt", "w");
        for (i = 0; i < gn; i = i + 1) begin
            dram_read(gaddr[i], rdw);
            $fdisplay(fd, "%04h %08h %08h", gaddr[i], rdw, golden[i]);
            if (rdw !== golden[i]) begin
                if (errors < 24)
                    $display("MISMATCH addr=%04h got=%08h exp=%08h",
                             gaddr[i], rdw, golden[i]);
                errors = errors + 1;
            end
        end
        $fclose(fd);
        if (errors == 0) $display(">>> PASS : bit-exact (%0d words)", gn);
        else             $display(">>> FAIL : %0d/%0d mismatches", errors, gn);
        $finish;
    end
 
    initial begin #100_000_000; $display("HARD TIMEOUT"); $finish; end
 
endmodule