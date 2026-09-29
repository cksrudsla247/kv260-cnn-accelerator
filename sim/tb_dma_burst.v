`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_dma_burst : dma_axi_burst.v against a burst-capable AXI4 slave model
//
//   The slave accepts one read burst and one write burst at a time, with
//   random ARREADY / AWREADY / WREADY, random gaps between R beats and a
//   random BVALID delay. W beats may be accepted before the AW handshake
//   (legal in AXI), so a master that waits for AWREADY before WVALID shows
//   up as a hang, not as a pass.
//
//   Protocol checks (any violation is an error):
//     - AxVALID stays high and AxADDR / AxLEN stay stable until AxREADY
//     - WVALID stays high and WDATA / WLAST stay stable until WREADY
//     - AxSIZE = 4 bytes, AxBURST = INCR, word-aligned address
//     - no burst crosses a 4 KB page
//     - W beats per burst == AWLEN + 1, WLAST exactly on the last beat
//     - strm_vld count == requested length, every strm_idx seen once
//
//   The wb stub gives wb_data one cycle after wb_idx, like core.v's output
//   buffer (with the wb_bank_d1 fix).
//
//   Plusargs : +READ_ONLY   skip the write tests (read path first)
//              +STALL=<n>   percent of cycles each READY/VALID is withheld
//                           (default 30)
//////////////////////////////////////////////////////////////////////////////////
module tb_dma_burst;

    localparam LEN_W   = 13;
    localparam DEPTH   = 16384;    // slave memory, words
    localparam TIMEOUT = 400000;   // cycles per transfer

    reg clk, rst;
    always #5 clk = ~clk;

    reg               mm2s_req;  reg [15:0] mm2s_base;  reg [LEN_W-1:0] mm2s_len;
    wire              mm2s_done;
    reg               s2mm_req;  reg [15:0] s2mm_base;  reg [LEN_W-1:0] s2mm_len;
    wire              s2mm_done;
    wire              strm_vld;  wire [31:0] strm_data; wire [LEN_W-1:0] strm_idx;
    wire              wb_req;    wire [LEN_W-1:0] wb_idx; wire [31:0] wb_data;

    wire [31:0] m_axi_awaddr;  wire [7:0] m_axi_awlen;  wire [2:0] m_axi_awsize;
    wire [1:0]  m_axi_awburst; wire m_axi_awvalid;      reg  m_axi_awready;
    wire [31:0] m_axi_wdata;   wire [3:0] m_axi_wstrb;  wire m_axi_wlast;
    wire        m_axi_wvalid;  reg  m_axi_wready;
    reg  [1:0]  m_axi_bresp;   reg  m_axi_bvalid;       wire m_axi_bready;
    wire [31:0] m_axi_araddr;  wire [7:0] m_axi_arlen;  wire [2:0] m_axi_arsize;
    wire [1:0]  m_axi_arburst; wire m_axi_arvalid;      reg  m_axi_arready;
    reg  [31:0] m_axi_rdata;   reg  [1:0] m_axi_rresp;  reg  m_axi_rlast;
    reg         m_axi_rvalid;  wire m_axi_rready;

    dma_axi_burst #(.LEN_W(LEN_W), .AXI_ADDR_WIDTH(32), .DDR_BASE(32'h0000_0000)) dut (
        .clk(clk), .rst(rst),
        .mm2s_req(mm2s_req), .mm2s_base(mm2s_base), .mm2s_len(mm2s_len), .mm2s_done(mm2s_done),
        .s2mm_req(s2mm_req), .s2mm_base(s2mm_base), .s2mm_len(s2mm_len), .s2mm_done(s2mm_done),
        .strm_vld(strm_vld), .strm_data(strm_data), .strm_idx(strm_idx),
        .wb_req(wb_req), .wb_idx(wb_idx), .wb_data(wb_data),
        .m_axi_awaddr(m_axi_awaddr), .m_axi_awlen(m_axi_awlen), .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst), .m_axi_awvalid(m_axi_awvalid), .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata), .m_axi_wstrb(m_axi_wstrb), .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid), .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp), .m_axi_bvalid(m_axi_bvalid), .m_axi_bready(m_axi_bready),
        .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen), .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst), .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp), .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
    );

    integer stall_pct;
    integer errors;
    function go; input dummy; go = (($unsigned($random) % 100) >= stall_pct); endfunction

    task err(input [8*96-1:0] msg);
    begin
        errors = errors + 1;
        if (errors <= 30) $display("ERROR t=%0t : %0s", $time, msg);
    end
    endtask

//---------------------------------------------------------------- wb stub (core.v obuf contract)
    reg [31:0]      src_mem [0:8191];
    reg [LEN_W-1:0] wb_idx_d;
    always @(posedge clk) wb_idx_d <= wb_idx;
    assign wb_data = src_mem[wb_idx_d];

//---------------------------------------------------------------- mm2s capture
    reg [31:0] got_mem  [0:8191];
    reg        got_seen [0:8191];
    integer    strm_count;
    always @(posedge clk) if (strm_vld) begin
        if (got_seen[strm_idx]) err("strm_idx delivered twice");
        got_mem[strm_idx]  <= strm_data;
        got_seen[strm_idx] <= 1'b1;
        strm_count = strm_count + 1;
    end

//---------------------------------------------------------------- AXI4 slave : memory
    reg [31:0] ddr_mem [0:DEPTH-1];

//---------------------------------------------------------------- AXI4 slave : AR / R
    reg        rd_active;
    reg [31:0] rd_base;          // word address
    integer    rd_len, rd_sent;
    integer    n_ar;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            m_axi_arready <= 1'b0; m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0;
            m_axi_rdata <= 32'd0; m_axi_rresp <= 2'b00;
            rd_active <= 1'b0; rd_len <= 0; rd_sent <= 0; n_ar = 0;
        end else begin
            if (m_axi_arvalid && m_axi_arready) begin
                n_ar = n_ar + 1;
                if (m_axi_arsize  !== 3'b010) err("ARSIZE is not 4 bytes");
                if (m_axi_arburst !== 2'b01)  err("ARBURST is not INCR");
                if (m_axi_araddr[1:0] !== 2'b00) err("ARADDR not word aligned");
                if ((m_axi_araddr & 32'hFFF) + (m_axi_arlen + 1) * 4 > 4096)
                    err("read burst crosses a 4 KB page");
                rd_active <= 1'b1;
                rd_base   <= m_axi_araddr >> 2;
                rd_len    <= m_axi_arlen + 1;
                rd_sent   <= 0;
                m_axi_arready <= 1'b0;
            end else if (!rd_active)
                m_axi_arready <= go(0);

            if (rd_active) begin
                if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                    m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0;
                    rd_active    <= 1'b0;
                end else if (!m_axi_rvalid || m_axi_rready) begin
                    if (rd_sent < rd_len && go(0)) begin
                        m_axi_rvalid <= 1'b1;
                        m_axi_rdata  <= ddr_mem[(rd_base + rd_sent) % DEPTH];
                        m_axi_rlast  <= (rd_sent == rd_len - 1);
                        rd_sent      <= rd_sent + 1;
                    end else begin
                        m_axi_rvalid <= 1'b0; m_axi_rlast <= 1'b0;
                    end
                end
            end
        end
    end

//---------------------------------------------------------------- AXI4 slave : AW / W / B
    reg        aw_have, w_have, b_pend;
    reg [31:0] aw_base;
    integer    aw_len, w_cnt, b_delay, k, n_aw;
    reg [31:0] wq [0:511];
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            m_axi_awready <= 1'b0; m_axi_wready <= 1'b0;
            m_axi_bvalid <= 1'b0; m_axi_bresp <= 2'b00;
            aw_have <= 1'b0; w_have <= 1'b0; b_pend <= 1'b0;
            w_cnt = 0; b_delay <= 0; n_aw = 0;
        end else begin
            // AW
            if (m_axi_awvalid && m_axi_awready) begin
                n_aw = n_aw + 1;
                if (m_axi_awsize  !== 3'b010) err("AWSIZE is not 4 bytes");
                if (m_axi_awburst !== 2'b01)  err("AWBURST is not INCR");
                if (m_axi_awaddr[1:0] !== 2'b00) err("AWADDR not word aligned");
                if ((m_axi_awaddr & 32'hFFF) + (m_axi_awlen + 1) * 4 > 4096)
                    err("write burst crosses a 4 KB page");
                aw_have <= 1'b1;
                aw_base <= m_axi_awaddr >> 2;
                aw_len  <= m_axi_awlen + 1;
                m_axi_awready <= 1'b0;
            end else if (!aw_have && !b_pend)
                m_axi_awready <= go(0);

            // W (may run ahead of AW)
            if (m_axi_wvalid && m_axi_wready) begin
                if (w_cnt >= 256) err("more than 256 W beats without WLAST");
                else wq[w_cnt] = m_axi_wdata;
                w_cnt = w_cnt + 1;
                if (m_axi_wlast) begin
                    w_have <= 1'b1;
                    m_axi_wready <= 1'b0;
                end else
                    m_axi_wready <= go(0);
            end else if (!w_have && !b_pend)
                m_axi_wready <= go(0);
            else
                m_axi_wready <= 1'b0;

            // commit once both halves of the burst are in
            if (aw_have && w_have && !b_pend) begin
                if (w_cnt != aw_len) err("W beat count != AWLEN+1 (WLAST in the wrong place)");
                for (k = 0; k < w_cnt && k < 256; k = k + 1)
                    ddr_mem[(aw_base + k) % DEPTH] = wq[k];
                aw_have <= 1'b0; w_have <= 1'b0; w_cnt = 0;
                b_pend  <= 1'b1;
                b_delay <= $unsigned($random) % 6;
            end
            if (aw_have && !w_have && w_cnt > aw_len)
                err("more W beats than AWLEN+1 before WLAST");

            // B
            if (b_pend && !m_axi_bvalid) begin
                if (b_delay == 0) m_axi_bvalid <= 1'b1;
                else b_delay <= b_delay - 1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
                b_pend       <= 1'b0;
            end
        end
    end

//---------------------------------------------------------------- VALID stability checks
    reg        p_arv, p_arr, p_awv, p_awr, p_wv, p_wr, p_wl;
    reg [31:0] p_araddr, p_awaddr, p_wdata;
    reg [7:0]  p_arlen, p_awlen;
    always @(posedge clk) begin
        if (!rst) begin
            if (p_arv && !p_arr) begin
                if (!m_axi_arvalid) err("ARVALID dropped before ARREADY");
                else if (m_axi_araddr !== p_araddr || m_axi_arlen !== p_arlen)
                    err("ARADDR/ARLEN changed while waiting for ARREADY");
            end
            if (p_awv && !p_awr) begin
                if (!m_axi_awvalid) err("AWVALID dropped before AWREADY");
                else if (m_axi_awaddr !== p_awaddr || m_axi_awlen !== p_awlen)
                    err("AWADDR/AWLEN changed while waiting for AWREADY");
            end
            if (p_wv && !p_wr) begin
                if (!m_axi_wvalid) err("WVALID dropped before WREADY");
                else if (m_axi_wdata !== p_wdata || m_axi_wlast !== p_wl)
                    err("WDATA/WLAST changed while waiting for WREADY");
            end
        end
        p_arv <= m_axi_arvalid; p_arr <= m_axi_arready; p_araddr <= m_axi_araddr; p_arlen <= m_axi_arlen;
        p_awv <= m_axi_awvalid; p_awr <= m_axi_awready; p_awaddr <= m_axi_awaddr; p_awlen <= m_axi_awlen;
        p_wv  <= m_axi_wvalid;  p_wr  <= m_axi_wready;  p_wdata  <= m_axi_wdata;  p_wl    <= m_axi_wlast;
    end

//---------------------------------------------------------------- driver
    integer i, r, cyc, words, t0;
    integer rd_base_i, rd_len_i;
    reg     read_only;

    task do_read(input integer base, input integer len);
    begin
        for (i = 0; i < len; i = i + 1) begin got_mem[i] = 32'hDEAD_BEEF; got_seen[i] = 1'b0; end
        strm_count = 0;
        @(negedge clk);
        mm2s_base = base; mm2s_len = len; mm2s_req = 1'b1;
        cyc = 0;
        @(posedge clk);
        while (!mm2s_done && cyc < TIMEOUT) begin @(posedge clk); cyc = cyc + 1; end
        @(negedge clk);
        mm2s_req = 1'b0;
        if (cyc >= TIMEOUT) begin
            $display("TIMEOUT : read base=%0d len=%0d never finished (read path not done yet?)", base, len);
            $display(">>> FAIL"); $finish;
        end
        if (strm_count != len) err("strm_vld count != mm2s_len");
        for (i = 0; i < len; i = i + 1) begin
            words = words + 1;
            if (got_mem[i] !== ddr_mem[(base + i) % DEPTH]) begin
                errors = errors + 1;
                if (errors <= 30)
                    $display("READ MISMATCH base=%0d len=%0d i=%0d got=%08h exp=%08h",
                             base, len, i, got_mem[i], ddr_mem[(base + i) % DEPTH]);
            end
        end
    end
    endtask

    task do_write(input integer base, input integer len);
    reg [31:0] guard_lo, guard_hi;
    begin
        for (i = 0; i < len; i = i + 1) src_mem[i] = $random;
        guard_lo = ddr_mem[(base + DEPTH - 1) % DEPTH];
        guard_hi = ddr_mem[(base + len) % DEPTH];
        @(negedge clk);
        s2mm_base = base; s2mm_len = len; s2mm_req = 1'b1;
        cyc = 0;
        @(posedge clk);
        while (!s2mm_done && cyc < TIMEOUT) begin @(posedge clk); cyc = cyc + 1; end
        @(negedge clk);
        s2mm_req = 1'b0;
        if (cyc >= TIMEOUT) begin
            $display("TIMEOUT : write base=%0d len=%0d never finished (write path not done yet?)", base, len);
            $display(">>> FAIL"); $finish;
        end
        repeat (2) @(posedge clk);
        for (i = 0; i < len; i = i + 1) begin
            words = words + 1;
            if (ddr_mem[(base + i) % DEPTH] !== src_mem[i]) begin
                errors = errors + 1;
                if (errors <= 30)
                    $display("WRITE MISMATCH base=%0d len=%0d i=%0d got=%08h exp=%08h",
                             base, len, i, ddr_mem[(base + i) % DEPTH], src_mem[i]);
            end
        end
        if (ddr_mem[(base + DEPTH - 1) % DEPTH] !== guard_lo) err("write touched the word before base");
        if (ddr_mem[(base + len) % DEPTH] !== guard_hi)       err("write touched the word after the end");
    end
    endtask

    // (base, len) pairs aimed at the burst-splitting edges
    integer fx_base [0:9];
    integer fx_len  [0:9];

    initial begin
        clk = 0; rst = 1; errors = 0; words = 0; strm_count = 0;
        mm2s_req = 0; mm2s_base = 0; mm2s_len = 0;
        s2mm_req = 0; s2mm_base = 0; s2mm_len = 0;
        if (!$value$plusargs("STALL=%d", stall_pct)) stall_pct = 30;
        read_only = $test$plusargs("READ_ONLY");
        for (i = 0; i < DEPTH; i = i + 1) ddr_mem[i] = $random;
        for (i = 0; i < 8192; i = i + 1) begin src_mem[i] = 0; got_seen[i] = 0; end

        fx_base[0] = 0;      fx_len[0] = 1;      // single word
        fx_base[1] = 0;      fx_len[1] = 256;    // exactly one full burst
        fx_base[2] = 0;      fx_len[2] = 257;    // one full burst + 1
        fx_base[3] = 255;    fx_len[3] = 2;      // straddles a 256-word boundary
        fx_base[4] = 240;    fx_len[4] = 100;    // 16 + 84
        fx_base[5] = 1020;   fx_len[5] = 10;     // straddles a 4 KB page (word 1024)
        fx_base[6] = 1000;   fx_len[6] = 700;    // several bursts
        fx_base[7] = 3;      fx_len[7] = 6272;   // the largest transfer the CNN makes
        fx_base[8] = 511;    fx_len[8] = 1;
        fx_base[9] = 4000;   fx_len[9] = 513;

        repeat (5) @(posedge clk); rst = 0; @(posedge clk);

        // ---------------- reads
        for (r = 0; r < 10; r = r + 1) do_read(fx_base[r], fx_len[r]);
        for (r = 0; r < 30; r = r + 1) begin
            rd_len_i  = 1 + ($unsigned($random) % 600);
            rd_base_i = $unsigned($random) % (DEPTH - 700);
            do_read(rd_base_i, rd_len_i);
        end
        $display("[TB] reads  : %0d words checked, %0d AR bursts", words, n_ar);

        // ---------------- writes (and write-then-read chains)
        if (!read_only) begin
            for (r = 0; r < 10; r = r + 1) do_write(fx_base[r] + 8192, fx_len[r]);
            for (r = 0; r < 30; r = r + 1) begin
                rd_len_i  = 1 + ($unsigned($random) % 600);
                rd_base_i = $unsigned($random) % (DEPTH - 700);
                do_write(rd_base_i, rd_len_i);
                do_read(rd_base_i, rd_len_i);
            end
            $display("[TB] writes : done, %0d AW bursts", n_aw);
        end

        // ---------------- throughput with no stalls
        stall_pct = 0;
        t0 = $time; do_read(0, 6272);
        $display("[TB] read  6272 words, no stalls : %0d cycles", ($time - t0) / 10);
        if (!read_only) begin
            t0 = $time; do_write(0, 6272);
            $display("[TB] write 6272 words, no stalls : %0d cycles", ($time - t0) / 10);
        end

        if (errors == 0) $display(">>> PASS : dma_axi_burst, %0d words%0s", words,
                                  read_only ? " (READ_ONLY)" : "");
        else             $display(">>> FAIL : %0d errors", errors);
        $finish;
    end

endmodule
