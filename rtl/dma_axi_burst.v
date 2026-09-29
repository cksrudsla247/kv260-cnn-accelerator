`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : dma_axi_burst     (linear DMA + AXI4 burst master in one block)
//
//   Replaces the dma.v + axi4_master_dram.v pair on the KV260 path.
//
//   dma.v asks for one word at a time (dram_en / dram_rdy), so the AXI side
//   never knows how long a transfer is and every word pays a full DDR round
//   trip. This block sees the whole request (base + length) and issues INCR
//   bursts instead: one address, up to 256 data beats.
//
//   Controller side : identical to dma.v (mm2s_*, s2mm_*, strm_*, wb_*), so
//                     core.v / controller.v do not change.
//   DDR side        : identical to axi4_master_dram.v (m_axi_*), so the
//                     block design does not change.
//
//   Burst splitting : a burst never crosses a 256-WORD boundary. 256 words
//   = 1 KB, and 1 KB-aligned chunks never straddle a 4 KB page, which is
//   the AXI rule. Max 256 beats is the AXI4 INCR limit.
//
//   mm2s (read)  : ARVALID -> R beats -> strm_vld per beat. RREADY can stay
//                  high while a burst is open: core.v writes every strm word
//                  straight into a buffer and never pushes back.
//   s2mm (write) : wb_req -> wb_data one cycle later -> small FIFO -> W beats.
//                  The FIFO exists because W can be stalled by WREADY at any
//                  time but the core's read cannot: a word requested now
//                  arrives next cycle no matter what.
//
//   STATUS : skeleton. Burst-length math and the port list are done; the
//            read and write state machines are TODO (see markers below).
//////////////////////////////////////////////////////////////////////////////////
module dma_axi_burst #(
    parameter LEN_W          = 13,
    parameter AXI_ADDR_WIDTH = 32,
    parameter DDR_BASE       = 32'h0000_0000,   // byte address of word 0
    parameter WFIFO_DEPTH    = 4                // power of two, >= 2
)(
    input                           clk,
    input                           rst,           // async, active HIGH

    //---- controller side (same contract as dma.v) ---------------------------
    input                           mm2s_req,      // level, held until mm2s_done
    input      [15:0]               mm2s_base,     // first WORD address
    input      [LEN_W-1:0]          mm2s_len,      // words to read
    output reg                      mm2s_done,     // 1-cycle pulse

    input                           s2mm_req,
    input      [15:0]               s2mm_base,
    input      [LEN_W-1:0]          s2mm_len,
    output reg                      s2mm_done,

    output reg                      strm_vld,      // one word read from DDR
    output reg [31:0]               strm_data,
    output reg [LEN_W-1:0]          strm_idx,      // its index inside the transfer

    output reg                      wb_req,        // ask the core for word wb_idx
    output reg [LEN_W-1:0]          wb_idx,
    input      [31:0]               wb_data,       // valid the cycle AFTER wb_req

    //---- AXI4 master : write address ----------------------------------------
    output reg [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output reg [7:0]                m_axi_awlen,   // beats - 1
    output     [2:0]                m_axi_awsize,
    output     [1:0]                m_axi_awburst,
    output reg                      m_axi_awvalid,
    input                           m_axi_awready,

    //---- write data ---------------------------------------------------------
    output     [31:0]               m_axi_wdata,
    output     [3:0]                m_axi_wstrb,
    output                          m_axi_wlast,
    output                          m_axi_wvalid,
    input                           m_axi_wready,

    //---- write response -----------------------------------------------------
    input      [1:0]                m_axi_bresp,
    input                           m_axi_bvalid,
    output reg                      m_axi_bready,

    //---- read address -------------------------------------------------------
    output reg [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output reg [7:0]                m_axi_arlen,
    output     [2:0]                m_axi_arsize,
    output     [1:0]                m_axi_arburst,
    output reg                      m_axi_arvalid,
    input                           m_axi_arready,

    //---- read data ----------------------------------------------------------
    input      [31:0]               m_axi_rdata,
    input      [1:0]                m_axi_rresp,
    input                           m_axi_rlast,
    input                           m_axi_rvalid,
    output reg                      m_axi_rready
);
    // fixed burst attributes : 4 bytes per beat, incrementing address
    assign m_axi_arsize  = 3'b010;
    assign m_axi_arburst = 2'b01;
    assign m_axi_awsize  = 3'b010;
    assign m_axi_awburst = 2'b01;
    assign m_axi_wstrb   = 4'b1111;

//---------------------------------------------------------------- burst length
    // beats for the NEXT burst = min(words left, words to the next 256-word
    // boundary). Both are at most 256, so beats fits 9 bits and beats-1
    // fits AxLEN's 8 bits.
    function [8:0] burst_beats(input [15:0] addr, input [LEN_W-1:0] rem);
        reg [8:0] to_bound;
        begin
            to_bound = 9'd256 - {1'b0, addr[7:0]};
            burst_beats = (rem < to_bound) ? rem[8:0] : to_bound;
        end
    endfunction

    function [AXI_ADDR_WIDTH-1:0] byte_addr(input [15:0] word_addr);
        byte_addr = DDR_BASE + {{(AXI_ADDR_WIDTH-18){1'b0}}, word_addr, 2'b00};
    endfunction

//================================================================ READ (mm2s)
    localparam [1:0] R_IDLE = 2'd0,   // wait for mm2s_req
                     R_AR   = 2'd1,   // present one burst address
                     R_DATA = 2'd2,   // take the burst's beats
                     R_DONE = 2'd3;   // pulse mm2s_done

    reg [1:0]       rs;
    reg [15:0]      r_addr;           // word address of the next burst
    reg [LEN_W-1:0] r_rem;            // words still to read
    reg [8:0]       r_beats;          // beats in the burst currently open
    reg [LEN_W-1:0] r_idx;            // strm_idx of the next beat

    wire [8:0] r_next_beats = burst_beats(r_addr, r_rem);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rs <= R_IDLE;
            r_addr <= 16'd0; r_rem <= {LEN_W{1'b0}};
            r_beats <= 9'd0; r_idx <= {LEN_W{1'b0}};
            mm2s_done <= 1'b0;
            strm_vld <= 1'b0; strm_data <= 32'd0; strm_idx <= {LEN_W{1'b0}};
            m_axi_araddr <= {AXI_ADDR_WIDTH{1'b0}}; m_axi_arlen <= 8'd0;
            m_axi_arvalid <= 1'b0; m_axi_rready <= 1'b0;
        end else begin
            mm2s_done <= 1'b0;        // pulses default low
            strm_vld  <= 1'b0;

            case (rs)
            // TODO(read) R_IDLE : on mm2s_req, latch base/len, clear r_idx,
            //   go to R_AR. Skip the cycle right after mm2s_done - the
            //   controller's req is still high for one cycle (see dma.v).
            // TODO(read) R_AR   : set araddr = byte_addr(r_addr),
            //   arlen = r_next_beats - 1, remember r_beats, raise ARVALID.
            //   Hold address and ARVALID until ARREADY, then drop ARVALID,
            //   raise RREADY, go to R_DATA.
            // TODO(read) R_DATA : every RVALID beat -> strm_vld / strm_data /
            //   strm_idx, r_idx + 1. On RLAST : drop RREADY, advance r_addr
            //   and r_rem by r_beats; next burst (R_AR) or R_DONE.
            // TODO(read) R_DONE : pulse mm2s_done, back to R_IDLE.
            default: rs <= R_IDLE;
            endcase
        end
    end

//================================================================ WRITE (s2mm)
    // TODO(write) : AW / W-FIFO / B machine.
    //   - per burst : w_beats = burst_beats(w_addr, w_rem); AWVALID with
    //     awaddr = byte_addr(w_addr), awlen = w_beats - 1.
    //   - fetch     : wb_req when (fifo count + words in flight) < WFIFO_DEPTH
    //                 and this burst still has words to fetch.
    //   - push      : wb_req delayed one cycle => wb_data goes into the FIFO.
    //   - W         : WVALID = FIFO not empty, WLAST on the burst's last beat,
    //                 pop on WVALID && WREADY.
    //   - B         : after the last beat AND the AW handshake, take one BVALID.
    //   - AW and W are independent channels; latch each handshake separately
    //     (same idea as aw_done / w_done in axi4_master_dram.v).
    assign m_axi_wdata  = 32'd0;
    assign m_axi_wvalid = 1'b0;
    assign m_axi_wlast  = 1'b0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s2mm_done <= 1'b0;
            wb_req <= 1'b0; wb_idx <= {LEN_W{1'b0}};
            m_axi_awaddr <= {AXI_ADDR_WIDTH{1'b0}}; m_axi_awlen <= 8'd0;
            m_axi_awvalid <= 1'b0; m_axi_bready <= 1'b0;
        end else begin
            s2mm_done <= 1'b0;
            wb_req    <= 1'b0;
        end
    end

endmodule
