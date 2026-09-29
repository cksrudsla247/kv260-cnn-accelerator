`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_top_kv260 : the actual KV260 board topology, end to end.
//
//   PS (this testbench) programs each layer's CSR registers over AXI4-Lite,
//   pulses start, and polls the 'done' register over AXI4-Lite - exactly
//   what embedded software on the Zynq PS would do. top_kv260's AXI4 master
//   (axi4_master_dram.v) talks to a variable-latency AXI4 slave model here
//   that stands in for the PS's DDR HP port, preloaded from the SAME
//   dram.txt tb_top.v uses. The final DDR content is checked against the
//   SAME gold.txt / gold_addr.txt.
//
//   Nothing before this file had ever driven top_kv260 as a whole - tb_top.v
//   bypasses both AXI interfaces entirely (dma.v wired straight to a fixed-
//   latency BRAM, CSR driven directly by tester.v's internal sequencer).
//   This is the first simulation of the path the bitstream actually uses.
//////////////////////////////////////////////////////////////////////////////////
module tb_top_kv260;

    localparam DRAM_DEPTH = 65536;
    localparam GMAX       = 8192;
    localparam PROG_BASE  = 16'hEA80;
    localparam POLL_GAP   = 37;     // cycles between 'done' polls - not a
                                     // power of 2, deliberately unaligned
                                     // with the core's own cadence

    reg clk, rst;
    always #5 clk = ~clk;
    wire rstn = ~rst;

    //---- AXI4-Lite master (this tb, playing the PS) --------------------------
    reg  [5:0]  s_axi_awaddr;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [31:0] s_axi_wdata;
    reg  [3:0]  s_axi_wstrb;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg         s_axi_bready;
    reg  [5:0]  s_axi_araddr;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rvalid;
    reg         s_axi_rready;

    //---- AXI4 master (top_kv260's u_axi_dma) <-> DDR slave model here --------
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

    top_kv260 dut (
        .clk(clk), .rst(rst),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
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

//---------------------------------------------------------------- AXI4-Lite master tasks (PS side)
    task axil_write(input [5:0] addr, input [31:0] data);
        integer aw_gap, w_gap;
        reg aw_ok, w_ok;
    begin
        aw_gap = $unsigned($random) % 4;
        w_gap  = $unsigned($random) % 4;
        aw_ok = 1'b0; w_ok = 1'b0;
        s_axi_awaddr = addr; s_axi_wdata = data; s_axi_wstrb = 4'hF;
        fork
            begin
                repeat (aw_gap) @(posedge clk);
                s_axi_awvalid = 1'b1;
                @(posedge clk);
                while (!s_axi_awready) @(posedge clk);
                s_axi_awvalid = 1'b0;
                aw_ok = 1'b1;
            end
            begin
                repeat (w_gap) @(posedge clk);
                s_axi_wvalid = 1'b1;
                @(posedge clk);
                while (!s_axi_wready) @(posedge clk);
                s_axi_wvalid = 1'b0;
                w_ok = 1'b1;
            end
        join
        s_axi_bready = 1'b1;
        while (!s_axi_bvalid) @(posedge clk);
        @(negedge clk);
        s_axi_bready = 1'b0;
    end
    endtask

    task axil_read(input [5:0] addr, output [31:0] rdata);
    begin
        s_axi_araddr = addr;
        s_axi_arvalid = 1'b1;
        @(posedge clk);
        while (!s_axi_arready) @(posedge clk);
        @(negedge clk);
        s_axi_arvalid = 1'b0;
        s_axi_rready = 1'b1;
        while (!s_axi_rvalid) @(posedge clk);
        rdata = s_axi_rdata;
        @(negedge clk);
        s_axi_rready = 1'b0;
    end
    endtask

    // realistic PS polling loop: read the 'done' register every POLL_GAP
    // cycles until it reads back 1. With the raw one-cycle done pulse this
    // would spin until the hard timeout; the sticky done_latch in
    // axi_lite_csr.v is what makes this actually terminate.
    task wait_done;
        reg [31:0] rd;
        integer polls;
    begin
        rd = 0; polls = 0;
        while (rd[0] !== 1'b1) begin
            repeat (POLL_GAP) @(posedge clk);
            axil_read(6'h3C, rd);
            polls = polls + 1;
            if (polls % 200 == 0)
                $display("  ... still polling 'done', %0d polls so far, cyc=%0t", polls, $time);
        end
    end
    endtask

//---------------------------------------------------------------- AXI4 DDR slave model (PS's DDR, HP port)
    reg [31:0] ddr_mem [0:DRAM_DEPTH-1];

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
                    r_delay       <= $unsigned($random) % 6;
                end else ar_delay <= ar_delay - 1;
            end
            if (ar_pending && !m_axi_rvalid) begin
                if (r_delay == 0) begin
                    m_axi_rvalid <= 1'b1;
                    m_axi_rlast  <= 1'b1;
                    m_axi_rresp  <= 2'b00;
                    m_axi_rdata  <= ddr_mem[ar_addr_r[31:2]];
                end else r_delay <= r_delay - 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                ar_pending   <= 1'b0;
                ar_delay     <= $unsigned($random) % 4;
            end
        end
    end

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
            if (!bw_pending &&
                (aw_pend || (m_axi_awvalid && m_axi_awready)) &&
                (w_pend  || (m_axi_wvalid  && m_axi_wready))) begin
                wr_addr_word = (m_axi_awready ? m_axi_awaddr : aw_addr_r) >> 2;
                ddr_mem[wr_addr_word] <= (m_axi_wready ? m_axi_wdata : w_data_r);
                bw_pending <= 1'b1;
                aw_pend    <= 1'b0;
                w_pend     <= 1'b0;
                b_delay    <= $unsigned($random) % 6;
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

//---------------------------------------------------------------- progress heartbeat
    integer cyc, lyr, hbfd;
    always @(posedge clk) if (!rst) cyc <= cyc + 1;
    always @(posedge clk) if (!rst && (cyc % 5000 == 0)) begin
        hbfd = $fopen("heartbeat_kv260.txt", "w");
        $fdisplay(hbfd, "cyc=%0d lyr=%0d", cyc, lyr);
        $fclose(hbfd);
    end

//---------------------------------------------------------------- main : replay the CSR program over AXI-Lite
    reg [31:0] golden [0:GMAX-1];
    reg [15:0] gaddr  [0:GMAX-1];
    integer i, gn, errors;
    integer ptr;
    reg [3:0]  e_addr;
    reg [31:0] e_data;
    reg [5:0]  byte_addr6;

    initial begin
        clk = 0; rst = 1; errors = 0; cyc = 0; lyr = 0;
        s_axi_awaddr=0; s_axi_awvalid=0; s_axi_wdata=0; s_axi_wstrb=4'hF; s_axi_wvalid=0;
        s_axi_bready=0; s_axi_araddr=0; s_axi_arvalid=0; s_axi_rready=0;

        for (i = 0; i < DRAM_DEPTH; i = i + 1) ddr_mem[i] = 32'd0;
        for (i = 0; i < GMAX; i = i + 1) begin
            golden[i] = 32'hx; gaddr[i] = 16'hffff;
        end
        $readmemh("dram.txt",      ddr_mem);
        $readmemh("gold.txt",      golden);
        $readmemh("gold_addr.txt", gaddr);
        gn = 0;
        for (i = 0; i < GMAX; i = i + 1) if (gaddr[i] !== 16'hffff) gn = gn + 1;

        repeat (5) @(posedge clk); rst = 0; @(posedge clk);
        $display("[TB] DDR preloaded (%0d words), %0d golden words to check", DRAM_DEPTH, gn);

        // replay the CSR program at PROG_BASE exactly like tester.v's own
        // sequencer does, but issuing every write over AXI4-Lite and every
        // 'done' check as a realistic periodic poll - this is what PS
        // software actually does, nothing here is a hierarchical shortcut.
        ptr = PROG_BASE;
        // NOTE: `disable <label>` only unwinds the block IT labels. Labeling
        // the while-loop's own body (`while(1) begin: prog_loop ... end`)
        // means disable only aborts the CURRENT iteration - the while(1)
        // immediately re-enters, and the "terminator" branch becomes a
        // no-op, so the loop walks off the end of the real CSR program and
        // off the end of DRAM itself, forever. The label must be on a block
        // that WRAPS the while statement so disabling it unwinds the loop.
        begin : prog_loop
        while (1) begin
            e_addr = ddr_mem[ptr][3:0];
            e_data = ddr_mem[ptr+1];
            ptr = ptr + 2;
            if (e_addr == 4'hE) begin
                $display("[TB] end of CSR program at ptr=0x%04h", ptr);
                disable prog_loop;
            end else if (e_addr == 4'hF) begin
                byte_addr6 = {4'd7, 2'b00};
                axil_write(byte_addr6, 32'd1);
                lyr = lyr + 1;
                $display("===== LAYER %0d : start pulse sent, polling done =====", lyr);
                wait_done;
                $display("===== LAYER %0d : done =====", lyr);
            end else begin
                byte_addr6 = {e_addr, 2'b00};
                axil_write(byte_addr6, e_data);
            end
        end
        end

        // verify : read the DDR model directly, same as a PS memcpy would
        errors = 0;
        for (i = 0; i < gn; i = i + 1) begin
            if (ddr_mem[gaddr[i]] !== golden[i]) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("MISMATCH addr=%04h got=%08h exp=%08h",
                             gaddr[i], ddr_mem[gaddr[i]], golden[i]);
            end
        end
        if (errors == 0)
            $display(">>> PASS : top_kv260 (AXI-Lite CSR + AXI4 DDR) bit-exact (%0d words)", gn);
        else
            $display(">>> FAIL : %0d/%0d mismatches", errors, gn);
        $finish;
    end

    initial begin #200_000_000; $display("HARD TIMEOUT"); $finish; end

endmodule
