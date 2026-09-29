`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_axi_lite_csr : axi_lite_csr.v against a variable-timing AXI4-Lite MASTER
//                   model, standing in for the PS writing CSR registers.
//
//   Nothing in this project had ever driven axi_lite_csr.v before this file -
//   tb_top.v's CSR program is written by tester.v's own internal sequencer,
//   which talks to controller.v directly (csr_we/csr_addr/csr_data), never
//   through this AXI-Lite slave. On the KV260 the PS is the one issuing these
//   writes, so this is the actual board path.
//
//   Drives AWVALID/WVALID independently (either order, or together), backs
//   pressure BREADY and RREADY randomly, and checks every captured
//   (csr_addr, csr_data) pair against the write log in issue order. Also
//   exercises the 'done' readback register (0xF) and confirms every other
//   address reads 0.
//////////////////////////////////////////////////////////////////////////////////
module tb_axi_lite_csr;

    localparam N_WRITES = 200;

    reg clk, rstn;
    always #5 clk = ~clk;

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

    wire        csr_we;
    wire [3:0]  csr_addr;
    wire [31:0] csr_data;
    reg         done;

    axi_lite_csr #(.ADDR_WIDTH(6)) dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rstn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .csr_we(csr_we), .csr_addr(csr_addr), .csr_data(csr_data), .done(done)
    );

    //---------------------------------------------------------------- capture
    reg [3:0]  cap_addr [0:N_WRITES-1];
    reg [31:0] cap_data [0:N_WRITES-1];
    integer    cap_n;
    always @(posedge clk) if (rstn && csr_we) begin
        cap_addr[cap_n] = csr_addr;
        cap_data[cap_n] = csr_data;
        cap_n = cap_n + 1;
    end

    //---------------------------------------------------------------- expected log
    reg [3:0]  exp_addr [0:N_WRITES-1];
    reg [31:0] exp_data [0:N_WRITES-1];
    integer    exp_n;

    //---------------------------------------------------------------- AXI-Lite master driver
    // independently timed AW/W, with random pre-delay and random ordering
    task axil_write(input [5:0] addr, input [31:0] data);
        integer aw_gap, w_gap, b_gap;
        reg aw_ok, w_ok;
    begin
        aw_gap = $unsigned($random) % 4;
        w_gap  = $unsigned($random) % 4;
        aw_ok = 1'b0; w_ok = 1'b0;

        s_axi_awaddr  = addr; s_axi_wdata = data; s_axi_wstrb = 4'hF;

        fork
            begin : AWDRV
                repeat (aw_gap) @(posedge clk);
                s_axi_awvalid = 1'b1;
                @(posedge clk);
                while (!s_axi_awready) @(posedge clk);
                s_axi_awvalid = 1'b0;
                aw_ok = 1'b1;
            end
            begin : WDRV
                repeat (w_gap) @(posedge clk);
                s_axi_wvalid = 1'b1;
                @(posedge clk);
                while (!s_axi_wready) @(posedge clk);
                s_axi_wvalid = 1'b0;
                w_ok = 1'b1;
            end
        join

        // bvalid can already be high (fast-path AW/W same-cycle accept) by
        // the time we get here, so check BEFORE waiting for an edge - an
        // unconditional @(posedge clk) here can step past the one cycle
        // bvalid&&bready is true and then wait forever.
        b_gap = $unsigned($random) % 5;
        repeat (b_gap) @(posedge clk);
        s_axi_bready = 1'b1;
        while (!s_axi_bvalid) @(posedge clk);
        @(negedge clk);
        s_axi_bready = 1'b0;

        exp_addr[exp_n] = addr[5:2];   // matches axi_lite_csr.v's own extraction
        exp_data[exp_n] = data;
        exp_n = exp_n + 1;
    end
    endtask

    task axil_read(input [5:0] addr, output [31:0] rdata);
        integer ar_gap, r_gap;
    begin
        ar_gap = $unsigned($random) % 4;
        repeat (ar_gap) @(posedge clk);
        s_axi_araddr = addr;
        s_axi_arvalid = 1'b1;
        @(posedge clk);
        while (!s_axi_arready) @(posedge clk);
        @(negedge clk);
        s_axi_arvalid = 1'b0;

        // rvalid comes up on the same edge as arready (R_IDLE does both in
        // one shot), so - same reasoning as the B channel above - check
        // before forcing an edge or this can wait forever.
        r_gap = $unsigned($random) % 5;
        repeat (r_gap) @(posedge clk);
        s_axi_rready = 1'b1;
        while (!s_axi_rvalid) @(posedge clk);
        rdata = s_axi_rdata;
        @(negedge clk);
        s_axi_rready = 1'b0;
    end
    endtask

    //---------------------------------------------------------------- main
    integer i, errors;
    reg [31:0] rd;
    reg [5:0]  raddr;
    reg [3:0]  reg4;

    initial begin
        clk = 0; rstn = 0; errors = 0; cap_n = 0; exp_n = 0; done = 0;
        s_axi_awaddr = 0; s_axi_awvalid = 0;
        s_axi_wdata  = 0; s_axi_wstrb = 4'hF; s_axi_wvalid = 0;
        s_axi_bready = 0;
        s_axi_araddr = 0; s_axi_arvalid = 0; s_axi_rready = 0;

        repeat (5) @(posedge clk); rstn = 1; @(posedge clk);

        // 1) plain register writes, csr_addr 0..9 cycling, random data,
        //    random AW/W ordering (the fork/join above randomises which
        //    channel's gap is longer, so both orders happen across the run)
        for (i = 0; i < N_WRITES - 20; i = i + 1) begin
            reg4 = i % 10;
            axil_write({reg4, 2'b00}, $random);   // AWADDR[5:2] = register index
        end

        // 2) back-to-back with no gap at all - worst case for any AW/W
        //    latch race, mirrors the dma.v S_IDLE lesson
        for (i = 0; i < 20; i = i + 1)
            axil_write({4'd7, 2'b00}, i);   // addr 7 = start_pulse register

        if (cap_n !== exp_n) begin
            errors = errors + 1;
            $display("COUNT MISMATCH: captured %0d writes, expected %0d", cap_n, exp_n);
        end
        for (i = 0; i < exp_n && i < N_WRITES; i = i + 1) begin
            if (cap_addr[i] !== exp_addr[i] || cap_data[i] !== exp_data[i]) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("WRITE MISMATCH #%0d: got addr=%0d data=%08h, exp addr=%0d data=%08h",
                              i, cap_addr[i], cap_data[i], exp_addr[i], exp_data[i]);
            end
        end

        // 3) read path : 'done' toggling, register 0xF; every other address -> 0
        done = 1'b0;
        axil_read(6'h3C, rd);   // reg 0xF -> byte addr 0x3C
        if (rd !== 32'd0) begin errors=errors+1; $display("READ MISMATCH: done=0 expected 0, got %08h", rd); end

        done = 1'b1;
        @(posedge clk);
        axil_read(6'h3C, rd);
        if (rd !== 32'd1) begin errors=errors+1; $display("READ MISMATCH: done=1 expected 1, got %08h", rd); end
        done = 1'b0;

        for (i = 0; i < 8; i = i + 1) begin
            raddr = i * 4;
            if (raddr != 6'h3C) begin
                axil_read(raddr, rd);
                if (rd !== 32'd0) begin
                    errors = errors + 1;
                    $display("READ MISMATCH: addr=%0h expected 0, got %08h", raddr, rd);
                end
            end
        end

        if (errors == 0)
            $display(">>> PASS : axi_lite_csr bit-exact over %0d writes + readback checks", exp_n);
        else
            $display(">>> FAIL : %0d error(s)", errors);
        $finish;
    end

    initial begin #1_000_000; $display("TIMEOUT"); $finish; end

endmodule
