`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : axi4_master_dram     (AXI4 master, wraps dma.v's DRAM-side port)
//
//   dma.v issues one word at a time : dram_en/dram_we/dram_addr(/dram_wdata)
//   in, dram_rdata out one cycle later (it was written for a synchronous
//   single-port BRAM model). This wrapper translates each single-word request
//   into a burst-length-1 AXI4 transaction against the PS's DDR (via an HP
//   slave port). dma.v itself is untouched.
//
//   Address translation : dma.v addresses are 16-bit WORD addresses (0..65535,
//   4 bytes each). AXI wants BYTE addresses, so this wrapper left-shifts by 2
//   and adds the DDR region base the PS assigns to this HP port.
//
//   Not pipelined : one AXI transaction must fully complete (response
//   received) before dram_en is deasserted and dma.v can issue the next word.
//   This is slower than a real burst, but keeps dma.v's FSM completely
//   unchanged, which matches today's goal (get a working bitstream, optimise
//   later).
//////////////////////////////////////////////////////////////////////////////////
module axi4_master_dram #(
    parameter AXI_ADDR_WIDTH = 32,
    parameter DDR_BASE       = 32'h0000_0000   // byte address of dma.v's word 0
)(
    input                          clk,
    input                          rst,            // active HIGH, matches dma.v

    //---- dma.v side (drop-in replacement for the old synchronous BRAM) --------
    input                          dram_en,
    input                          dram_we,
    input      [15:0]              dram_addr,      // WORD address from dma.v
    input      [31:0]              dram_wdata,
    output reg [31:0]              dram_rdata,
    output reg                     dram_rdy,       // 1-cyc pulse: dram_rdata valid (read) / write committed
    
    //---- AXI4 master : write address channel -----------------------------------
    output reg [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output reg [7:0]                m_axi_awlen,    // 0 = 1 beat
    output reg [2:0]                m_axi_awsize,   // 3'b010 = 4 bytes/beat
    output reg [1:0]                m_axi_awburst,  // 2'b01 = INCR
    output reg                      m_axi_awvalid,
    input                           m_axi_awready,

    //---- write data channel -----------------------------------------------------
    output reg [31:0]               m_axi_wdata,
    output reg [3:0]                m_axi_wstrb,
    output reg                      m_axi_wlast,
    output reg                      m_axi_wvalid,
    input                           m_axi_wready,

    //---- write response channel --------------------------------------------------
    input      [1:0]                m_axi_bresp,
    input                            m_axi_bvalid,
    output reg                       m_axi_bready,

    //---- read address channel ------------------------------------------------------
    output reg [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output reg [7:0]                m_axi_arlen,
    output reg [2:0]                m_axi_arsize,
    output reg [1:0]                m_axi_arburst,
    output reg                      m_axi_arvalid,
    input                            m_axi_arready,

    //---- read data channel -----------------------------------------------------------
    input      [31:0]                m_axi_rdata,
    input      [1:0]                 m_axi_rresp,
    input                            m_axi_rlast,
    input                            m_axi_rvalid,
    output reg                       m_axi_rready
);
    localparam [2:0]
        S_IDLE  = 3'd0,
        S_AR    = 3'd1,   // read address outstanding
        S_R     = 3'd2,   // waiting for read data
        S_AW_W  = 3'd3,   // write address + write data outstanding (issued together)
        S_B     = 3'd4;   // waiting for write response

    reg [2:0] state;

    wire [AXI_ADDR_WIDTH-1:0] byte_addr = DDR_BASE + ({16'd0, dram_addr} << 2);

    // latch aw/w acceptance independently, same pattern as the CSR slave :
    // AXI does not guarantee AWREADY and WREADY assert on the same cycle
    reg aw_done, w_done;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            aw_done <= 1'b0; w_done <= 1'b0;
            dram_rdata <= 32'd0;
            dram_rdy   <= 1'b0;
            m_axi_awvalid <= 1'b0; m_axi_wvalid <= 1'b0; m_axi_bready <= 1'b0;
            m_axi_arvalid <= 1'b0; m_axi_rready <= 1'b0;
            m_axi_awlen <= 8'd0; m_axi_awsize <= 3'b010; m_axi_awburst <= 2'b01;
            m_axi_arlen <= 8'd0; m_axi_arsize <= 3'b010; m_axi_arburst <= 2'b01;
            m_axi_wstrb <= 4'b1111; m_axi_wlast <= 1'b1;
        end else begin
            dram_rdy <= 1'b0;   // default low, 1-cycle pulse like everything else here
            case (state)
            S_IDLE: begin
                if (dram_en && !dram_we) begin
                    m_axi_araddr  <= byte_addr;
                    m_axi_arvalid <= 1'b1;
                    state         <= S_AR;
                end else if (dram_en && dram_we) begin
                    m_axi_awaddr  <= byte_addr;
                    m_axi_awvalid <= 1'b1;
                    m_axi_wdata   <= dram_wdata;
                    m_axi_wvalid  <= 1'b1;
                    aw_done       <= 1'b0;
                    w_done        <= 1'b0;
                    state         <= S_AW_W;
                end
            end

            // ---- read ----
            S_AR: begin
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b1;
                    state         <= S_R;
                end
            end
            S_R: begin
                if (m_axi_rvalid && m_axi_rready) begin
                    dram_rdata   <= m_axi_rdata;    // valid together with dram_rdy, next cycle
                    dram_rdy     <= 1'b1;
                    m_axi_rready <= 1'b0;
                    state        <= S_IDLE;
                end
            end

            // ---- write ----
            S_AW_W: begin
                if (m_axi_awvalid && m_axi_awready) begin
                    m_axi_awvalid <= 1'b0;
                    aw_done       <= 1'b1;
                end
                if (m_axi_wvalid && m_axi_wready) begin
                    m_axi_wvalid <= 1'b0;
                    w_done       <= 1'b1;
                end
                if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
                    (w_done  || (m_axi_wvalid  && m_axi_wready))) begin
                    m_axi_bready <= 1'b1;
                    state        <= S_B;
                end
            end
            S_B: begin
                if (m_axi_bvalid && m_axi_bready) begin
                    dram_rdy     <= 1'b1;
                    m_axi_bready <= 1'b0;
                    state        <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule