`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : top_kv260     (board top : Zynq UltraScale+ PS <-> top (core+dma) via AXI)
//
//   Wraps the simulation-only top.v (CSR/DRAM as plain wires) with the two
//   AXI adapters so it can sit behind a real Zynq PS. top.v itself, core.v,
//   and dma.v are all untouched.
//////////////////////////////////////////////////////////////////////////////////
module top_kv260 (
    input                        clk,
    input                        rst,              // active HIGH (rst_ps8_0_96M peripheral_reset)

    //---- AXI4-Lite slave : PS master port -> here (CSR control) --------------
    input      [5:0]             s_axi_awaddr,
    input                         s_axi_awvalid,
    output                        s_axi_awready,
    input      [31:0]             s_axi_wdata,
    input      [3:0]              s_axi_wstrb,
    input                         s_axi_wvalid,
    output                        s_axi_wready,
    output     [1:0]              s_axi_bresp,
    output                        s_axi_bvalid,
    input                         s_axi_bready,
    input      [5:0]              s_axi_araddr,
    input                         s_axi_arvalid,
    output                        s_axi_arready,
    output     [31:0]             s_axi_rdata,
    output     [1:0]              s_axi_rresp,
    output                        s_axi_rvalid,
    input                         s_axi_rready,

    //---- AXI4 master : here -> PS slave port (DDR access via HP port) --------
    output     [31:0]             m_axi_awaddr,
    output     [7:0]              m_axi_awlen,
    output     [2:0]              m_axi_awsize,
    output     [1:0]              m_axi_awburst,
    output                        m_axi_awvalid,
    input                         m_axi_awready,
    output     [31:0]             m_axi_wdata,
    output     [3:0]              m_axi_wstrb,
    output                        m_axi_wlast,
    output                        m_axi_wvalid,
    input                         m_axi_wready,
    input      [1:0]              m_axi_bresp,
    input                         m_axi_bvalid,
    output                        m_axi_bready,
    output     [31:0]             m_axi_araddr,
    output     [7:0]              m_axi_arlen,
    output     [2:0]              m_axi_arsize,
    output     [1:0]              m_axi_arburst,
    output                        m_axi_arvalid,
    input                         m_axi_arready,
    input      [31:0]             m_axi_rdata,
    input      [1:0]              m_axi_rresp,
    input                         m_axi_rlast,
    input                         m_axi_rvalid,
    output                        m_axi_rready
);
    // axi_lite_csr <-> top.v CSR wires
    wire        csr_we;
    wire [3:0]  csr_addr;
    wire [31:0] csr_data;
    wire        done;

    // axi4_master_dram <-> top.v DRAM wires
    wire        dram_en, dram_we;
    wire [15:0] dram_addr;
    wire [31:0] dram_wdata, dram_rdata;
    wire        dram_rdy;

    // NOTE: s_axi_aresetn is active LOW (AXI convention), rst here is active
    // HIGH (matches core.v/dma.v). Board-level reset wiring must invert once;
    // this module inverts it right here so both sub-blocks see the polarity
    // they each expect.
    wire s_axi_aresetn = ~rst;

    axi_lite_csr u_csr (
        .s_axi_aclk    (clk),
        .s_axi_aresetn (s_axi_aresetn),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),
        .csr_we   (csr_we),
        .csr_addr (csr_addr),
        .csr_data (csr_data),
        .done     (done)
    );

    axi4_master_dram u_axi_dma (
        .clk (clk),
        .rst (rst),
        .dram_en    (dram_en),
        .dram_we    (dram_we),
        .dram_addr  (dram_addr),
        .dram_wdata (dram_wdata),
        .dram_rdata (dram_rdata),
        .dram_rdy   (dram_rdy),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready)
    );

    top u_top (
        .clk(clk), .rst(rst),
        .csr_we(csr_we), .csr_addr(csr_addr), .csr_data(csr_data), .done(done),
        .dram_en(dram_en), .dram_we(dram_we), .dram_addr(dram_addr),
        .dram_wdata(dram_wdata), .dram_rdata(dram_rdata),
        .dram_rdy(dram_rdy)
    );

endmodule