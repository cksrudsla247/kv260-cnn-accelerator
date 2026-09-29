`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : dma     (linear burst engine)
//
//   Serves one request at a time, mm2s or s2mm. Handshake with the controller:
//     *_req  (in)  : level, held until *_done
//     *_done (out) : 1-cycle completion pulse
//
//   DRAM side : variable-latency, single-outstanding. dram_en/dram_we/
//   dram_addr(/dram_wdata) are pulsed for exactly one cycle to KICK OFF a
//   transaction; dram_rdy pulses for exactly one cycle, some unknown number
//   of cycles later, to signal completion (read: dram_rdata is valid this
//   cycle / write: the word has been committed). No new dram_en is issued
//   until the previous dram_rdy has been seen.
//
//   For a real synchronous BRAM (fixed latency 1, e.g. the old `dram` IP in
//   tb_top), tie dram_rdy to dram_en delayed by one cycle.
//
//   Address of word w = base + w,  w in 0..len-1.
//
//   mm2s : read DRAM, stream out on strm_vld / strm_data / strm_idx
//   s2mm : ask the core for a word (wb_req / wb_idx), write wb_data to DRAM
//////////////////////////////////////////////////////////////////////////////////
module dma #(
    parameter LEN_W = 13
)(
    input               clk,
    input               rst,               // async, active HIGH

    input               mm2s_req,          // read request, level
    input      [15:0]   mm2s_base,         // first word address
    input      [LEN_W-1:0] mm2s_len,     // words to read
    output reg          mm2s_done,         // 1-cycle completion pulse

    input               s2mm_req,          // write request, level
    input      [15:0]   s2mm_base,         // first word address
    input      [LEN_W-1:0] s2mm_len,     // words to write
    output reg          s2mm_done,         // 1-cycle completion pulse

    output reg          strm_vld,          // outbound word valid
    output reg [31:0]   strm_data,         // the word read from DRAM
    output reg [LEN_W-1:0] strm_idx,     // its index inside the burst

    output reg          wb_req,            // ask the core for a word
    output reg [LEN_W-1:0] wb_idx,       // which word
    input      [31:0]   wb_data,           // the core's answer (1 cycle later)

    output reg          dram_en,
    output reg          dram_we,
    output reg [15:0]   dram_addr,
    output reg [31:0]   dram_wdata,
    input      [31:0]   dram_rdata,
    input               dram_rdy           // 1-cycle pulse, transaction complete
);
    localparam [2:0]
        S_IDLE     = 3'd0,
        S_RD_WAIT  = 3'd1,   // read issued, waiting for dram_rdy
        S_WR_FETCH = 3'd2,   // wb_req just issued, waiting 1 cyc for wb_data
        S_WR_ISSUE = 3'd3,   // present dram_wdata/dram_addr to DRAM
        S_WR_WAIT  = 3'd4,   // write issued, waiting for dram_rdy
        S_DONE_M   = 3'd5,   // pulse mm2s_done
        S_DONE_S   = 3'd6;   // pulse s2mm_done

    reg [2:0] state;
    reg [LEN_W-1:0] w;                // single word-index counter

    wire [15:0] wr_addr   = s2mm_base + {{(16-LEN_W){1'b0}}, w};
    wire        mm2s_last = (w == mm2s_len - 1'b1);
    wire        s2mm_last = (w == s2mm_len - 1'b1);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state<=S_IDLE; w<=0;
            mm2s_done<=0; s2mm_done<=0;
            strm_vld<=0; strm_data<=0; strm_idx<=0;
            wb_req<=0; wb_idx<=0;
            dram_en<=0; dram_we<=0; dram_addr<=0; dram_wdata<=0;
        end else begin
            mm2s_done<=0; s2mm_done<=0;
            strm_vld<=0; wb_req<=0;
            dram_en<=0; dram_we<=0;
            case (state)
            S_IDLE: begin
                w<=0;
                // *_req is a level held by the controller until it sees our
                // *_done pulse; busy/req only drops the cycle AFTER that, so
                // on the very cycle we assert *_done and land back in S_IDLE,
                // the old request is technically still asserted. Without this
                // guard that stale level looks like a brand-new request and
                // we launch a 1-word phantom transfer at the OLD base/index
                // before the controller reprograms it for the real next
                // burst - corrupting one word at every mm2s/s2mm boundary.
                if (mm2s_done || s2mm_done) begin
                    // just finished; wait one cycle for req to actually drop
                end else if (mm2s_req) begin
                    dram_en   <= 1'b1;
                    dram_we   <= 1'b0;
                    dram_addr <= mm2s_base;
                    state     <= S_RD_WAIT;
                end else if (s2mm_req) begin
                    wb_req <= 1'b1;
                    wb_idx <= {LEN_W{1'b0}};
                    state  <= S_WR_FETCH;
                end
            end

            S_RD_WAIT: begin
                if (dram_rdy) begin
                    strm_vld  <= 1'b1;
                    strm_data <= dram_rdata;
                    strm_idx  <= w;
                    if (mm2s_last) begin
                        state <= S_DONE_M;
                    end else begin
                        w         <= w + 1'b1;
                        dram_en   <= 1'b1;
                        dram_we   <= 1'b0;
                        dram_addr <= mm2s_base + {{(16-LEN_W){1'b0}}, (w + 1'b1)};
                        state     <= S_RD_WAIT;
                    end
                end
            end
            S_DONE_M: begin mm2s_done <= 1'b1; state <= S_IDLE; end

            S_WR_FETCH: begin
                state <= S_WR_ISSUE;
            end
            S_WR_ISSUE: begin
                dram_en    <= 1'b1;
                dram_we    <= 1'b1;
                dram_addr  <= wr_addr;
                dram_wdata <= wb_data;
                state      <= S_WR_WAIT;
            end
            S_WR_WAIT: begin
                if (dram_rdy) begin
                    if (s2mm_last) begin
                        state <= S_DONE_S;
                    end else begin
                        w      <= w + 1'b1;
                        wb_req <= 1'b1;
                        wb_idx <= w + 1'b1;
                        state  <= S_WR_FETCH;
                    end
                end
            end
            S_DONE_S: begin s2mm_done <= 1'b1; state <= S_IDLE; end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule