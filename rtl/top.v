`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : top     (synthesis top : core + dma)
//
//   In silicon the CSR port becomes AXI-Lite (slave) and the DRAM port becomes
//   an AXI-Full master. The tester/DRAM model is NOT part of this hierarchy.
//////////////////////////////////////////////////////////////////////////////////
module top (
    input               clk,
    input               rst,            // async, active HIGH

    // CSR in (AXI-Lite in silicon)
    input               csr_we,
    input      [3:0]    csr_addr,
    input      [31:0]   csr_data,
    output              done,           // 1-cycle pulse : layer finished

    // DRAM port out (AXI-Full master in silicon)
    output              dram_en,
    output              dram_we,
    output     [15:0]   dram_addr,
    output     [31:0]   dram_wdata,
    input      [31:0]   dram_rdata,
    input               dram_rdy
);
    // descriptor handshake, controller -> dma
    wire         mm2s_req, s2mm_req;
    wire [15:0]  mm2s_base, s2mm_base;
    wire [12:0]  mm2s_len,  s2mm_len;
    wire         mm2s_done, s2mm_done;

    // inbound word stream, dma -> core
    wire         strm_vld;
    wire [31:0]  strm_data;
    wire [12:0]  strm_idx;

    // writeback word request, dma -> core -> dma
    wire         wb_req;
    wire [12:0]  wb_idx;
    wire [31:0]  wb_data;

    core u_core (
        .clk(clk), .rst(rst),
        .csr_we(csr_we), .csr_addr(csr_addr), .csr_data(csr_data), .done(done),
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
        .dram_rdy(dram_rdy)
    );
endmodule