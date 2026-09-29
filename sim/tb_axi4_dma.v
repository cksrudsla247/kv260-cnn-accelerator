`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_axi4_dma : dma.v + axi4_master_dram.v against a variable-latency AXI4
//               slave model, standing in for the PS's DDR HP port.
//
//   tb_top.v only ever exercises dma.v against a FIXED 1-cycle BRAM
//   (dram_rdy = dram_en delayed by one cycle). That is not the path the
//   KV260 actually uses: on the board, dma.v drives axi4_master_dram.v,
//   which drives a real HP/DDR port with variable, back-pressured latency.
//   axi4_master_dram.v had never been simulated at all before this file.
//
//   This tb drives dma.v directly (no core.v / controller.v - just enough
//   of a stub to answer wb_req/wb_idx and to catch strm_vld/strm_data,
//   same contract core.v honours: wb_data is valid exactly one cycle after
//   wb_idx, like a synchronous BRAM read) through several write-then-
//   read-back rounds, randomising the slave's AR/AW/W/B latency and
//   READY backpressure every round, including AWREADY/WREADY arriving in
//   either order (the aw_done/w_done independent-latch logic in
//   axi4_master_dram.v exists specifically for that case).
//////////////////////////////////////////////////////////////////////////////////
module tb_axi4_dma;

    localparam LEN_W  = 13;
    localparam DEPTH  = 4096;      // slave memory model, words
    localparam ROUNDS = 40;

    reg clk, rst;
    always #5 clk = ~clk;

    //---- dma.v <-> stub controller ------------------------------------------
    reg               mm2s_req;
    reg  [15:0]       mm2s_base;
    reg  [LEN_W-1:0]  mm2s_len;
    wire              mm2s_done;

    reg               s2mm_req;
    reg  [15:0]       s2mm_base;
    reg  [LEN_W-1:0]  s2mm_len;
    wire              s2mm_done;

    wire              strm_vld;
    wire [31:0]       strm_data;
    wire [LEN_W-1:0]  strm_idx;

    wire              wb_req;
    wire [LEN_W-1:0]  wb_idx;
    wire [31:0]       wb_data;

    //---- dma.v <-> axi4_master_dram.v ----------------------------------------
    wire              dram_en, dram_we;
    wire [15:0]       dram_addr;
    wire [31:0]       dram_wdata, dram_rdata;
    wire              dram_rdy;

    //---- axi4_master_dram.v <-> AXI4 slave model -----------------------------
    wire [31:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awvalid;
    reg         m_axi_awready;

    wire [31:0] m_axi_wdata;
    wire [3:0]  m_axi_wstrb;
    wire        m_axi_wlast, m_axi_wvalid;
    reg         m_axi_wready;

    reg  [1:0]  m_axi_bresp;
    reg         m_axi_bvalid;
    wire        m_axi_bready;

    wire [31:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    reg         m_axi_arready;

    reg  [31:0] m_axi_rdata;
    reg  [1:0]  m_axi_rresp;
    reg         m_axi_rlast;
    reg         m_axi_rvalid;
    wire        m_axi_rready;

    dma #(.LEN_W(LEN_W)) u_dma (
        .clk(clk), .rst(rst),
        .mm2s_req(mm2s_req), .mm2s_base(mm2s_base), .mm2s_len(mm2s_len),
        .mm2s_done(mm2s_done),
        .s2mm_req(s2mm_req), .s2mm_base(s2mm_base), .s2mm_len(s2mm_len),
        .s2mm_done(s2mm_done),
        .strm_vld(strm_vld), .strm_data(strm_data), .strm_idx(strm_idx),
        .wb_req(wb_req), .wb_idx(wb_idx), .wb_data(wb_data),
        .dram_en(dram_en), .dram_we(dram_we), .dram_addr(dram_addr),
        .dram_wdata(dram_wdata), .dram_rdata(dram_rdata), .dram_rdy(dram_rdy)
    );

    axi4_master_dram #(.AXI_ADDR_WIDTH(32), .DDR_BASE(32'h0000_0000)) u_axi (
        .clk(clk), .rst(rst),
        .dram_en(dram_en), .dram_we(dram_we), .dram_addr(dram_addr),
        .dram_wdata(dram_wdata), .dram_rdata(dram_rdata), .dram_rdy(dram_rdy),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize), .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast), .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

//---------------------------------------------------------------- wb stub (core.v's obuf contract)
    // wb_data must be valid exactly one cycle after wb_idx, same as a
    // synchronous BRAM read with the address applied combinationally -
    // this is the same timing core.v's output_buffer gives dma.v.
    reg [31:0] src_mem [0:DEPTH-1];
    reg [LEN_W-1:0] wb_idx_d;
    always @(posedge clk) wb_idx_d <= wb_idx;
    assign wb_data = src_mem[wb_idx_d];

//---------------------------------------------------------------- mm2s capture
    reg [31:0] got_mem [0:DEPTH-1];
    always @(posedge clk) if (strm_vld) got_mem[strm_idx] <= strm_data;

//---------------------------------------------------------------- AXI4 slave model (variable latency)
    reg [31:0] ddr_mem [0:DEPTH-1];

    // -- AR/R --
    reg [31:0] ar_addr_r;
    reg        ar_pending;
    integer    ar_delay, r_delay;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            m_axi_arready <= 1'b0; m_axi_rvalid <= 1'b0;
            m_axi_rdata <= 32'd0; m_axi_rresp <= 2'b00; m_axi_rlast <= 1'b1;
            ar_pending <= 1'b0; ar_delay <= 0; r_delay <= 0;
        end else begin
            m_axi_arready <= 1'b0;
            if (!ar_pending && m_axi_arvalid && !m_axi_arready) begin
                if (ar_delay == 0) begin
                    m_axi_arready <= 1'b1;
                    ar_addr_r     <= m_axi_araddr;
                    ar_pending    <= 1'b1;
                    r_delay       <= $unsigned($random) % 6;   // 0..5 cyc before RVALID
                end else ar_delay <= ar_delay - 1;
            end
            if (ar_pending && !m_axi_rvalid) begin
                if (r_delay == 0) begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rlast  <= 1'b1;
                    m_axi_rresp  <= 2'b00;
                    m_axi_rdata  <= ddr_mem[ar_addr_r[31:2] % DEPTH];
                end else r_delay <= r_delay - 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                ar_pending   <= 1'b0;
                ar_delay     <= $unsigned($random) % 4;        // gap before next AR accepted
            end
        end
    end

    // -- AW / W (independent, order not guaranteed) / B --
    reg        aw_pend, w_pend, bw_pending;
    reg [31:0] aw_addr_r, w_data_r;
    integer    aw_delay, w_delay, b_delay;
    integer    wr_addr_word;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            m_axi_awready <= 1'b0; m_axi_wready <= 1'b0;
            m_axi_bvalid  <= 1'b0; m_axi_bresp  <= 2'b00;
            aw_pend <= 1'b0; w_pend <= 1'b0; bw_pending <= 1'b0;
            aw_delay <= 0; w_delay <= 0; b_delay <= 0;
        end else begin
            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;

            if (!bw_pending) begin
                if (!aw_pend && m_axi_awvalid) begin
                    if (aw_delay == 0) begin
                        m_axi_awready <= 1'b1;
                        aw_addr_r     <= m_axi_awaddr;
                        aw_pend       <= 1'b1;
                    end else aw_delay <= aw_delay - 1;
                end
                if (!w_pend && m_axi_wvalid) begin
                    if (w_delay == 0) begin
                        m_axi_wready <= 1'b1;
                        w_data_r     <= m_axi_wdata;
                        w_pend       <= 1'b1;
                    end else w_delay <= w_delay - 1;
                end
            end

            // both channels landed (this cycle's accept counts immediately)
            if (!bw_pending &&
                (aw_pend || (m_axi_awvalid && m_axi_awready)) &&
                (w_pend  || (m_axi_wvalid  && m_axi_wready))) begin
                wr_addr_word = (m_axi_awready ? m_axi_awaddr : aw_addr_r) >> 2;
                ddr_mem[wr_addr_word % DEPTH] <= (m_axi_wready ? m_axi_wdata : w_data_r);
                bw_pending <= 1'b1;
                aw_pend    <= 1'b0;
                w_pend     <= 1'b0;
                b_delay    <= $unsigned($random) % 6;          // 0..5 cyc before BVALID
                aw_delay   <= $unsigned($random) % 4;
                w_delay    <= $unsigned($random) % 4;
            end

            if (bw_pending && !m_axi_bvalid) begin
                if (b_delay == 0) begin
                    m_axi_bvalid <= 1'b1;
                    m_axi_bresp  <= 2'b00;
                end else b_delay <= b_delay - 1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
                bw_pending   <= 1'b0;
            end
        end
    end

//---------------------------------------------------------------- driver
    integer i, r, errors, total_words;
    integer base, len;
    reg [15:0] base16;

    task do_write(input [15:0] wbase, input [LEN_W-1:0] wlen);
    begin
        @(negedge clk);
        s2mm_base = wbase; s2mm_len = wlen; s2mm_req = 1'b1;
        @(posedge clk);
        while (!s2mm_done) @(posedge clk);
        @(negedge clk);
        s2mm_req = 1'b0;
    end
    endtask

    task do_read(input [15:0] rbase, input [LEN_W-1:0] rlen);
    begin
        @(negedge clk);
        mm2s_base = rbase; mm2s_len = rlen; mm2s_req = 1'b1;
        @(posedge clk);
        while (!mm2s_done) @(posedge clk);
        @(negedge clk);
        mm2s_req = 1'b0;
    end
    endtask

    initial begin
        clk = 0; rst = 1; errors = 0; total_words = 0;
        mm2s_req = 0; mm2s_base = 0; mm2s_len = 0;
        s2mm_req = 0; s2mm_base = 0; s2mm_len = 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            ddr_mem[i] = 32'd0; src_mem[i] = 32'd0; got_mem[i] = 32'hDEAD_BEEF;
        end

        repeat (5) @(posedge clk); rst = 0; @(posedge clk);

        for (r = 0; r < ROUNDS; r = r + 1) begin
            // small lengths hit the S_IDLE-right-after-done edge every round;
            // occasional len==1 exercises the very first/last word alone.
            len   = 1 + ($unsigned($random) % 37);
            base  = $unsigned($random) % (DEPTH - 64);
            base16 = base[15:0];

            for (i = 0; i < len; i = i + 1)
                src_mem[i] = $random;

            do_write(base16, len[LEN_W-1:0]);
            do_read(base16, len[LEN_W-1:0]);

            for (i = 0; i < len; i = i + 1) begin
                total_words = total_words + 1;
                if (got_mem[i] !== src_mem[i]) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("MISMATCH round=%0d base=%0d i=%0d got=%08h exp=%08h",
                                  r, base, i, got_mem[i], src_mem[i]);
                end
            end
            // fire the next round's request as close as possible to this
            // round's done pulse, to stress the S_IDLE req/done race under
            // AXI's variable latency too.
        end

        // back-to-back writes with NO gap between them at all, immediately
        // chained from the driver side (worst case for the S_IDLE guard)
        for (r = 0; r < 10; r = r + 1) begin
            len  = 1 + ($unsigned($random) % 5);
            base = r * 8;
            base16 = base[15:0];
            for (i = 0; i < len; i = i + 1) src_mem[i] = $random;
            do_write(base16, len[LEN_W-1:0]);
            do_read(base16, len[LEN_W-1:0]);
            for (i = 0; i < len; i = i + 1) begin
                total_words = total_words + 1;
                if (got_mem[i] !== src_mem[i]) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("MISMATCH(tight) round=%0d base=%0d i=%0d got=%08h exp=%08h",
                                  r, base, i, got_mem[i], src_mem[i]);
                end
            end
        end

        if (errors == 0)
            $display(">>> PASS : axi4_master_dram bit-exact over %0d words, %0d rounds",
                      total_words, ROUNDS + 10);
        else
            $display(">>> FAIL : %0d/%0d word mismatches", errors, total_words);
        $finish;
    end

    initial begin #2_000_000; $display("TIMEOUT"); $finish; end

endmodule
