`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : axi_lite_csr     (AXI4-Lite slave, wraps the controller's CSR port)
//
//   PS writes one CSR register per AXI-Lite write transaction:
//     AWADDR[5:2] selects csr_addr (16 registers, only 0..9 used by controller)
//     WDATA       becomes csr_data
//     one cycle after WVALID&WREADY, csr_we pulses for one cycle
//
//   PS reads 'done' back through a fixed offset (register 0xF, address 0x3C).
//   Any other read address returns 0. This keeps the wrapper tiny: the
//   controller has no other reads besides 'done'.
//
//   AXI4-Lite has 5 channels (AW, W, B, AR, R), each with its own valid/ready
//   handshake. This slave accepts one outstanding write and one outstanding
//   read at a time, which is all AXI4-Lite requires.
//////////////////////////////////////////////////////////////////////////////////
module axi_lite_csr #(
    parameter ADDR_WIDTH = 6      // 64 bytes of address space, 16 x 32-bit regs
)(
    input                        s_axi_aclk,
    input                        s_axi_aresetn,     // active LOW, AXI convention

    //---- write address channel ------------------------------------------------
    input      [ADDR_WIDTH-1:0]  s_axi_awaddr,
    input                        s_axi_awvalid,
    output reg                   s_axi_awready,

    //---- write data channel -----------------------------------------------------
    input      [31:0]            s_axi_wdata,
    input      [3:0]             s_axi_wstrb,       // ignored : CSR writes are always 32-bit
    input                        s_axi_wvalid,
    output reg                   s_axi_wready,

    //---- write response channel -------------------------------------------------
    output reg [1:0]             s_axi_bresp,       // always OKAY (2'b00)
    output reg                   s_axi_bvalid,
    input                        s_axi_bready,

    //---- read address channel ---------------------------------------------------
    input      [ADDR_WIDTH-1:0]  s_axi_araddr,
    input                        s_axi_arvalid,
    output reg                   s_axi_arready,

    //---- read data channel --------------------------------------------------------
    output reg [31:0]            s_axi_rdata,
    output reg [1:0]             s_axi_rresp,       // always OKAY (2'b00)
    output reg                   s_axi_rvalid,
    input                        s_axi_rready,

    //---- controller side (matches controller.v's CSR port exactly) ----------------
    output reg                   csr_we,
    output reg [3:0]             csr_addr,
    output reg [31:0]            csr_data,
    input                        done
);
    // fixed offset for reading 'done' : register 0xF -> byte address 0x3C
    localparam [3:0] DONE_REG = 4'hF;

    // controller.v's `done` is a ONE-CYCLE pulse (done <= state_q==ST_DONE).
    // At 100 MHz that is a 10 ns window; a PS polling loop reading this
    // register over AXI-Lite has no realistic chance of ever sampling that
    // exact cycle. Latch it here so software sees a level that stays high
    // until it programs the NEXT layer (csr_addr 7 = start_pulse), which is
    // exactly the point software has already observed the previous done and
    // moved on - same convention tester.v uses internally (T_WAIT waits for
    // the pulse, T_F0 immediately starts the next program's CSR writes).
    reg done_latch;
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn)
            done_latch <= 1'b0;
        else if (done)
            done_latch <= 1'b1;
        else if (csr_we && csr_addr == 4'd7)
            done_latch <= 1'b0;
    end

    //------------------------------------------------------------------
    // write path
    //   S_IDLE  : wait for both AWVALID and WVALID (accept them independently,
    //             AXI does not guarantee they arrive together)
    //   S_RESP  : pulse csr_we, present BVALID until BREADY
    //------------------------------------------------------------------
    localparam [1:0] W_IDLE = 2'd0, W_RESP = 2'd1;
    reg [1:0] wstate;
    reg       aw_done, w_done;      // latched : AW or W already accepted this xfer

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            wstate         <= W_IDLE;
            aw_done        <= 1'b0;
            w_done         <= 1'b0;
            s_axi_awready  <= 1'b0;
            s_axi_wready   <= 1'b0;
            s_axi_bvalid   <= 1'b0;
            s_axi_bresp    <= 2'b00;
            csr_we         <= 1'b0;
            csr_addr       <= 4'd0;
            csr_data       <= 32'd0;
        end else begin
            csr_we        <= 1'b0;          // one-cycle pulse, default low
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;

            case (wstate)
            W_IDLE: begin
                // accept AW whenever it's offered and we haven't already latched it
                if (s_axi_awvalid && !aw_done) begin
                    s_axi_awready <= 1'b1;
                    csr_addr      <= s_axi_awaddr[5:2];
                    aw_done       <= 1'b1;
                end
                // accept W whenever it's offered and we haven't already latched it
                if (s_axi_wvalid && !w_done) begin
                    s_axi_wready <= 1'b1;
                    csr_data     <= s_axi_wdata;
                    w_done       <= 1'b1;
                end
                // both arrived (this cycle or a previous one) : commit the write
                if ((aw_done || (s_axi_awvalid && !aw_done)) &&
                    (w_done  || (s_axi_wvalid  && !w_done))) begin
                    csr_we  <= 1'b1;
                    aw_done <= 1'b0;
                    w_done  <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp  <= 2'b00;
                    wstate  <= W_RESP;
                end
            end
            W_RESP: begin
                if (s_axi_bvalid && s_axi_bready) begin
                    s_axi_bvalid <= 1'b0;
                    wstate       <= W_IDLE;
                end
            end
            default: wstate <= W_IDLE;
            endcase
        end
    end

    //------------------------------------------------------------------
    // read path
    //   Only 'done' is readable. Everything else returns 0. One-cycle
    //   latency : accept ARADDR, register the result, present RVALID.
    //------------------------------------------------------------------
    localparam [1:0] R_IDLE = 2'd0, R_DATA = 2'd1;
    reg [1:0] rstate;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rstate         <= R_IDLE;
            s_axi_arready  <= 1'b0;
            s_axi_rvalid   <= 1'b0;
            s_axi_rdata    <= 32'd0;
            s_axi_rresp    <= 2'b00;
        end else begin
            s_axi_arready <= 1'b0;

            case (rstate)
            R_IDLE: begin
                if (s_axi_arvalid) begin
                    s_axi_arready <= 1'b1;
                    s_axi_rdata   <= (s_axi_araddr[5:2] == DONE_REG)
                                    ? {31'd0, done_latch} : 32'd0;
                    s_axi_rresp   <= 2'b00;
                    s_axi_rvalid  <= 1'b1;
                    rstate        <= R_DATA;
                end
            end
            R_DATA: begin
                if (s_axi_rvalid && s_axi_rready) begin
                    s_axi_rvalid <= 1'b0;
                    rstate       <= R_IDLE;
                end
            end
            default: rstate <= R_IDLE;
            endcase
        end
    end

endmodule