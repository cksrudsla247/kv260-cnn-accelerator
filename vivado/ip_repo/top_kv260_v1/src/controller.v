`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : controller     (CNN, row-streaming dataflow)
//
// Loop order   ft -> ct -> fh -> fw -> oh -> ow      (output pixel INNERMOST)
//
//   for ft (0..ft_max):                 output-channel tile, COL_SIZE wide
//     for ct (0..ct_max):               input-channel tile,  ROW_SIZE wide
//       for fh (0..fh_max):             filter row
//         for fw (0..fw_max):           filter column
//           load W tile (ft,ct,fh,fw)   ROW_SIZE x COL_SIZE INT8
//           for oh (0..oh_max):         output row
//             load input row (oh+fh-pad) of channel group ct
//             for ow (0..ow_max):       output column
//               acc[slot] += in_row[ow+fw-pad] . W
//       drain the COL_SIZE channels of every pixel out to DRAM
//
//   The textbook names are used throughout, so the RTL reads like the layer
//   equation instead of like the hardware:
//
//     out[fn][oh][ow] = SUM_c SUM_fh SUM_fw W[fn][c][fh][fw]
//                                           . in[c][oh+fh-pad][ow+fw-pad]
//
//   Only the summed axes may sit on PE rows, because the adder tree adds all
//   ROW_SIZE products unconditionally. c goes on the rows (ROW_SIZE at a time,
//   hence ct); fh and fw do not fit, so they become separate passes that
//   accumulate. fn is not summed, so it goes on the columns (hence ft), and
//   (oh,ow) is not summed, so it goes on the time axis.
//
// WHY THE PIXEL LOOP IS INNERMOST
//   One weight tile is pushed into the PE array and then serves every output
//   pixel before it is swapped. That is (oh_max+1)*(ow_max+1) reuses - 784 for
//   Conv1_2 - which is what makes weight-stationary pay off here when it did
//   nothing for the MLP at B=1.
//
// WHY THE INPUT IS STREAMED BY ROW
//   Holding a whole feature map would need H*W*(C/ROW_SIZE) ibuf rows: 3136 for
//   Conv1_2, which is 100x the buffer that exists. It is not needed. With
//   (ct,fh,fw) fixed, output pixel (oh,ow) reads input (oh+fh-pad, ow+fw-pad),
//   so sweeping ow walks ONE input row. The fh loop has already separated the
//   vertical spread of the window, so only a single row is ever live:
//
//     ibuf rows needed = W        28 for Conv1_2, against a depth of 32
//
//   The cost is that each input row is re-read FH*FW times. That lands almost
//   free because of an exact match: one ibuf row is NB_IN = 2 DRAM words, and
//   one output pixel takes 2 cycles, so the load of row oh+1 hides completely
//   underneath the pixel sweep of row oh. ibuf ping-pong is what makes that
//   overlap possible and is therefore load-bearing, not an optimisation.
//
// ACTIVATION LAYOUT IN DRAM   (C/ROW_SIZE, H, W, ROW_SIZE)
//   Channel-group major, NOT pixel major. Group ct of row h is then contiguous:
//
//     word(ct,h,w) = base + (ct*ct_stride) + (h*W + w)*NB_IN
//
//   so one input row is a single linear burst, which is all dma.v can do. A
//   pixel-major layout would scatter a row with stride C/ROW_SIZE and could not
//   be fetched at all. The drain writes the same layout back: one s2mm burst
//   per output channel group, selected by wb_grp.
//
// BRAM LATENCY - the dominant bug source in this project
//   Three places, all of them "address leads, consumer lags":
//     wbuf -> PE      wbuf_raddr = push_cnt   , pe_row_addr = push_cnt_d1
//     ibuf -> PE      ST_PIX_RD drives the address, ST_PIX_WR consumes the data
//     acc  -> obuf    dr_en/dr_addr combinational, obuf_we/obuf_waddr registered
//   ibuf_oob is registered on the ST_PIX_RD edge for exactly the same reason:
//   the mask has to arrive with the data, not with the address.
//
// PIXEL TIMING   2 cycles, always
//   ST_PIX_RD   ibuf_raddr out; accumulator READ if this is not the first tile
//   ST_PIX_WR   ibuf data (and therefore pe_result) valid; accumulator WRITE
//   acc_first does not get a 1-cycle fast path: the PE result does not exist
//   yet in the first cycle. Nothing is lost - the input DMA also needs 2 words
//   per pixel, so 2 cycles per pixel is already the floor.
//
// GLOSSARY
//   ft     output-channel tile : COL_SIZE channels           (was og)
//   ct     input-channel tile  : ROW_SIZE channels           (was part of ig)
//   fh,fw  filter tap                                        (was r,s)
//   oh,ow  output pixel
//   slot   accumulator address = the output pixel being built
//   chunk  one obuf-full of drained pixels, one s2mm burst per channel group
//   _q     flip-flop output      _nxt  combinational next value
//   _d1    one-cycle delayed copy
//
// Sections : [1]FSM [2]CSR [3]counters [4]address gen [5]DMA desc
//            [6]stream sink [7]ping-pong [8]FSM-next [9]weight push
//            [10]compute [11]drain
//
//////////////////////////////////////////////////////////////////////////////////
module controller #(
    parameter ROW_SIZE   = 8,     // PE rows    : reduction width
    parameter COL_SIZE   = 32,    // PE columns : output channels in parallel
    parameter NB_IN      = 2,     // ibuf banks : ROW_SIZE*8/32
    parameter NB_W       = 8,     // wbuf banks : COL_SIZE*8/32
    parameter NB_OUT     = 8,     // obuf banks : COL_SIZE*8/32
    parameter ROW_BIT    = 3,     // clog2(ROW_SIZE)
    parameter IB_A_BIT   = 5,     // ibuf depth 32 : holds W input columns
    parameter WB_A_BIT   = 5,     // wbuf depth 32 : one tile is ROW_SIZE rows
    parameter OB_A_BIT   = 6,     // obuf depth 64 : one drain chunk
    parameter ACC_A_BIT  = 10,    // accumulator slots : OH*OW
    parameter LEN_W      = 13     // burst length / word index
)(
    input                        clk,
    input                        rst,           // async, active HIGH

    //---- CSR : per-layer config, written once by the host before start -------
    input                        csr_we,        // 1-cycle write strobe
    input      [3:0]             csr_addr,      // register index (0..9 used)
    input      [31:0]            csr_data,      // value to store
    output reg                   done,          // 1-cycle pulse : layer finished

    //---- mm2s : DRAM read descriptor out, data stream in ---------------------
    output reg                   mm2s_req,      // level, held until mm2s_done
    output reg [15:0]            mm2s_base,     // first DRAM word address
    output reg [LEN_W-1:0]       mm2s_len,      // burst length in words
    input                        mm2s_done,     // 1-cycle pulse from the DMA

    //---- s2mm : DRAM write descriptor out ------------------------------------
    output reg                   s2mm_req,
    output reg [15:0]            s2mm_base,
    output reg [LEN_W-1:0]       s2mm_len,
    input                        s2mm_done,

    //---- inbound word stream (from the DMA) ----------------------------------
    input                        strm_vld,
    input      [31:0]            strm_data,
    input      [LEN_W-1:0]       strm_idx,      // index inside the burst

    //---- stream sink : where the inbound word is written ---------------------
    output     [NB_W-1:0]        wbuf_we,
    output     [NB_IN-1:0]       ibuf_we,
    output     [WB_A_BIT-1:0]    wbuf_waddr,
    output     [IB_A_BIT-1:0]    ibuf_waddr,
    output     [31:0]            strm_wdata,

    //---- ping-pong selects (0/1 = which physical buffer) ---------------------
    output                       wbuf_wr_sel,   // side the DMA is filling
    output                       wbuf_rd_sel,   // side the PE is reading
    output                       ibuf_wr_sel,
    output                       ibuf_rd_sel,
    output                       obuf_wr_sel,   // side the drain is filling
    output                       obuf_rd_sel,   // side s2mm is reading

    //---- compute-side buffer reads -------------------------------------------
    output reg [WB_A_BIT-1:0]    wbuf_raddr,    // weight row during ST_PUSH
    output reg [IB_A_BIT-1:0]    ibuf_raddr,    // input column ow+fw-pad
    output reg                   ibuf_oob,      // force the lanes to zero
                                                // registered: arrives with data

    //---- BN constant regfile --------------------------------------------------
    output                       bn_rf_we,
    output     [8:0]             bn_rf_waddr,
    output     [8:0]             bn_group_base,

    //---- PE array -------------------------------------------------------------
    output reg                   pe_w_en,       // write one weight row
    output reg [ROW_BIT-1:0]     pe_row_addr,   // lags wbuf_raddr by one

    //---- accumulator (BRAM, read-modify-write driven from here) ---------------
    output reg                   acc_en,
    output reg                   acc_ph,        // 0 = read/load, 1 = write back
    output reg                   acc_first,     // first tile : load, do not add
    output reg [ACC_A_BIT-1:0]   acc_addr,
    output reg                   dr_en,         // drain read (never with acc_en)
    output reg [ACC_A_BIT-1:0]   dr_addr,

    //---- post-path mode flags (constant for the whole layer) -----------------
    output reg [3:0]             rq_shift,      // CSR8[3:0]
    output reg [3:0]             rq_mult,       // CSR8[7:4]
    output reg [1:0]             bn_shift,      // CSR8[14:13] : BN s1, 0..3
    output reg                   bn_en,         // CSR0[17]
    output reg                   relu_en,       // CSR0[18]
    output reg                   wide_out,      // CSR0[19] : 32-bit logits
    output reg                   wide_half_sel, // which 16 channels this row is
    output reg                   wide_half_sel_d1, // ... as seen by the obuf WRITE

    //---- 2x2 maxpool on the drain path ---------------------------------------
    //   All four are registered, so they line up with the requant result rather
    //   than with dr_addr. pool_en itself is a layer constant from the CSR.
    output reg                   pool_en,
    output reg                   pool_vld,      // a drained pixel is on the bus
    output reg [7:0]             pool_oh,       // its output row
    output reg [7:0]             pool_ow,       // its output column

    //---- output buffer fill ---------------------------------------------------
    output reg                   obuf_we,       // registered one behind dr_en
    output reg [OB_A_BIT-1:0]    obuf_waddr,
    output reg [1:0]             wb_grp         // which channel group s2mm reads
);

//---------------------------------------------------------------- [1] FSM
    localparam PIPE_N = 4;
    localparam [4:0]
        ST_IDLE      = 5'd0,   // wait for the CSR start pulse
        ST_BN_REQ    = 5'd1,   // issue the BN constant load
        ST_BN_WAIT   = 5'd2,
        ST_TILE_REQ  = 5'd3,   // blocking load of the first weight tile
        ST_TILE_WAIT = 5'd4,
        ST_TSWAP     = 5'd5,   // hand the tile to the PE, prefetch the next
        ST_PUSH      = 5'd6,   // ROW_SIZE+1 cycles : wbuf -> PE registers
        ST_ROW_REQ   = 5'd7,   // blocking load of this sweep's first input row
        ST_ROW_WAIT  = 5'd8,
        ST_RSWAP     = 5'd9,   // hand the row to the PE, prefetch the next row
        ST_PIX_RD    = 5'd10,  // ibuf address out ; accumulator read
        ST_PIX_WR    = 5'd11,  // ibuf data in     ; accumulator write
        ST_PIX_SUM   = 5'd20,
        ST_PIX_ACC   = 5'd21,  // PE result now valid (1-cycle PE pipeline) ; accumulator RMW happens here
        ST_ROW_END   = 5'd12,  // wait for the row prefetch, then next oh
        ST_TILE_END  = 5'd13,  // advance fw / fh / ct, or go and drain
        ST_DRAIN     = 5'd14,  // accumulator -> post path -> obuf (pipelined)
        ST_DR_TAIL   = 5'd15,  // one extra cycle : the last obuf write lags
        ST_OUT_REQ   = 5'd16,  // s2mm one channel group of this chunk
        ST_OUT_WAIT  = 5'd17,
        ST_CHUNK_END = 5'd18,  // next group / next chunk / next ft / finish
        ST_DONE      = 5'd19;

    reg [4:0] state_q, state_nxt;

//---------------------------------------------------------------- [2] CSR
    localparam IB_BANK_BIT = (NB_IN  > 1) ? $clog2(NB_IN)  : 1;   // 1
    localparam WB_BANK_BIT = (NB_W   > 1) ? $clog2(NB_W)   : 1;   // 3
    localparam [LEN_W-1:0] TILE_WORDS = ROW_SIZE * NB_W;          // 64
    localparam GRP_PER_TILE = COL_SIZE / ROW_SIZE;                // 4
    localparam OB_DEPTH     = 1 << OB_A_BIT;                      // 64

    reg  [7:0]  ct_max;      // C/ROW_SIZE - 1        (Affine: 143)
    reg  [1:0]  fh_max;      // FH - 1
    reg  [1:0]  fw_max;      // FW - 1
    reg  [3:0]  ft_max;      // FN/COL_SIZE - 1
    reg  [1:0]  pad;
    reg  [7:0]  h_max;       // H  - 1     input  geometry
    reg  [7:0]  w_max;       // W  - 1
    reg  [7:0]  oh_max;      // OH - 1     output geometry
    reg  [7:0]  ow_max;      // OW - 1
    reg  [15:0] in_base;
    reg  [LEN_W-1:0] in_words;
    reg  [15:0] w_base;
    reg  [15:0] out_base;
    reg  [LEN_W-1:0] out_words;
    reg  [15:0] ct_stride;   // input  words per channel group = H*W*NB_IN
    reg  [15:0] og_stride;   // output words per channel group = OH*OW*NB_IN
    reg  [4:0]  bn_group;
    reg         start_pulse;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ct_max<=0; fh_max<=0; fw_max<=0; ft_max<=0; pad<=0; pool_en<=0;
            bn_en<=0; relu_en<=0; wide_out<=0;
            h_max<=0; w_max<=0; oh_max<=0; ow_max<=0;
            in_base<=0; in_words<=0; w_base<=0;
            out_base<=0; out_words<=0;
            ct_stride<=0; og_stride<=0;
            rq_shift<=0; rq_mult<=0; bn_group<=0; bn_shift<=0;
            start_pulse<=0;
        end else begin
            start_pulse <= 1'b0;                       // auto-clear
            if (csr_we) begin
                case (csr_addr)
                4'd0: begin ct_max   <= csr_data[7:0];
                            fh_max   <= csr_data[9:8];
                            fw_max   <= csr_data[11:10];
                            ft_max   <= csr_data[15:12];
                            pool_en  <= csr_data[16];
                            bn_en    <= csr_data[17];
                            relu_en  <= csr_data[18];
                            wide_out <= csr_data[19];
                            pad      <= csr_data[21:20]; end
                4'd1: begin h_max    <= csr_data[7:0];
                            w_max    <= csr_data[15:8];
                            oh_max   <= csr_data[23:16];
                            ow_max   <= csr_data[31:24]; end
                4'd2: in_base   <= csr_data[15:0];
                4'd3: in_words  <= csr_data[LEN_W-1:0];
                4'd4: w_base    <= csr_data[15:0];
                4'd5: out_base  <= csr_data[15:0];
                4'd6: out_words <= csr_data[LEN_W-1:0];
                4'd7: start_pulse <= csr_data[0];
                4'd8: begin rq_shift <= csr_data[3:0];
                            rq_mult  <= csr_data[7:4];
                            bn_group <= csr_data[12:8];
                            bn_shift <= csr_data[14:13]; end
                4'd9: begin ct_stride <= csr_data[15:0];
                            og_stride <= csr_data[31:16]; end
                default: ;
                endcase
            end
        end
    end

    // one input row = W entries of NB_IN words each
    wire [LEN_W-1:0] row_words = ({{(LEN_W-8){1'b0}}, w_max} + 1'b1) * NB_IN;
    wire [15:0]      row_step  = ({8'd0, w_max} + 16'd1) * NB_IN;

//---------------------------------------------------------------- [3] counters
    reg  [3:0]  ft_cnt;      // output-channel tile
    reg  [7:0]  ct_cnt;      // input-channel tile
    reg  [1:0]  fh_cnt, fw_cnt;
    reg  [7:0]  oh_cnt, ow_cnt;
    reg  [ROW_BIT:0]     push_cnt;   // 0..ROW_SIZE
    reg  [ACC_A_BIT-1:0] slot;       // accumulator address, = oh*OW+ow
    reg  [15:0] ct_base;     // in_base  + ct*ct_stride
    reg  [15:0] row_base;    // ct_base  + (oh+fh-pad)*row_step
    reg  [15:0] w_ptr;       // DRAM address of the NEXT weight tile
    reg  [15:0] ft_base;     // out_base + ft*GRP_PER_TILE*og_stride
    reg  [15:0] grp_base;    // ft_base  + wb_grp*og_stride

    // drain side : its own pixel walk, so OH*OW never has to be multiplied out
    reg  [7:0]  dr_oh, dr_ow;
    reg  [ACC_A_BIT-1:0] dr_slot;         // accumulator slot being read
    reg  [ACC_A_BIT-1:0] chunk_first;     // first OUTPUT pixel of this chunk
    reg  [OB_A_BIT:0]    out_row;         // EMITTED pixels in this chunk
                                          // (one spare bit : reaches OB_DEPTH)
    reg                  chunk_done;      // this chunk is the layer's last

    wire fw_last  = (fw_cnt == fw_max);
    wire fh_last  = (fh_cnt == fh_max);
    wire ct_last  = (ct_cnt == ct_max);
    wire ft_last  = (ft_cnt == ft_max);
    wire oh_last  = (oh_cnt == oh_max);
    wire ow_last  = (ow_cnt == ow_max);
    wire tile_last = ct_last && fh_last && fw_last;   // last tile of this ft
    wire acc_load  = (ct_cnt == 8'd0) && (fh_cnt == 2'd0) && (fw_cnt == 2'd0);

    wire single_row = (oh_max == 8'd0);   // no row sweep to hide behind
    wire dr_oh_last = (dr_oh == oh_max);
    wire dr_ow_last = (dr_ow == ow_max);
    wire dr_last    = dr_oh_last && dr_ow_last;       // last pixel of the map
    // 2x2 pooling emits one pixel for every four drained, so obuf fills four
    // times slower than the accumulator drains and the two counters diverge.
    // chunk_first is in OUTPUT pixels because that is what the s2mm base needs;
    // using the accumulator slot there would scatter the writes 4x apart.
    wire dr_emit    = !pool_en || (dr_ow[0] && dr_oh[0]);
    wire chunk_full = dr_emit && (out_row == OB_DEPTH-1);
    wire grp_last   = (wb_grp == GRP_PER_TILE-1);

    // wide mode emits two obuf rows per slot, so the pixel only advances on
    // the second one. obuf_waddr advances on BOTH, or the two halves would
    // land on top of each other.
    wire wide_last  = wide_out ? wide_half_sel : 1'b1;

    // stop this chunk : the obuf is full, or the map is finished. The map end
    // only counts once the slot has emitted all of its obuf rows.
    wire dr_stop    = chunk_full || (dr_last && wide_last);

    // BN group for the current ft. bn_group is the layer's first group.
    wire [4:0] bn_group_sel = bn_group + {1'b0, ft_cnt};
    assign bn_group_base = {bn_group_sel[3:0], 5'b00000};   // 32 words per group

//---------------------------------------------------------------- [4] address gen
//   Unsigned compare catches both ends at once : oh+fh-pad = -1 wraps to a
//   large value and fails > h_max, which is exactly the padding condition.
    wire [9:0] in_h    = {2'd0, oh_cnt} + {8'd0, fh_cnt} - {8'd0, pad};
    wire [9:0] in_w    = {2'd0, ow_cnt} + {8'd0, fw_cnt} - {8'd0, pad};
    wire       row_oob = (in_h > {2'd0, h_max});
    wire       col_oob = (in_w > {2'd0, w_max});

    // start of an oh sweep : (fh - pad) rows away from this group's base.
    //
    // Both products are formed UNSIGNED and then subtracted, instead of
    // computing a signed (fh - pad) and multiplying it. Verilog makes an
    // ENTIRE expression unsigned as soon as any operand is unsigned, and
    // ct_base is unsigned, so the signed multiply that used to sit here was
    // evaluated unsigned: fh - pad = -1 became +15 and every fh=0 sweep
    // started 15*row_step FORWARD instead of one row back. Wrapping the
    // operands in $signed() does NOT help - a context-determined operand takes
    // the signedness of the expression it sits in, not its own. The bug was
    // invisible whenever pad = 0, which is every layer Conv1_1 exercises.
    wire [15:0] fh_fwd    = {14'd0, fh_cnt} * row_step;
    wire [15:0] pad_back  = {14'd0, pad}    * row_step;
    wire [15:0] row_base0 = ct_base + fh_fwd - pad_back;

//---------------------------------------------------------------- [5] DMA desc
    // Task 1's 0x9000 is inside the CNN weight table, which now spans
    // 0x0000..0xAB80 (606 tiles x 64 words end at 0x9780; the rest is slack). See docs/DESIGN_NOTES.md section 7 for the
    // full map; Python must place the BN table here.
    localparam [15:0]      BN_DRAM_BASE = 16'hAB80;
    localparam [LEN_W-1:0] BN_WORDS     = 13'd432;

    reg        mm2s_busy;
    reg [1:0]  mm2s_kind;     // 0 = weight tile, 1 = input row, 2 = BN
    reg [15:0] mm2s_addr;
    reg        mm2s_issue;
    reg [1:0]  mm2s_kind_nxt;
    reg [15:0] mm2s_addr_nxt;

    wire [1:0] strm_dest = mm2s_kind;   // sink follows the LOAD, not the state

    // the row AFTER this one is out of bounds : skip its load and let the mask
    // feed zeros, rather than fetching a row that does not exist
    wire [9:0] in_h_nxt    = in_h + 10'd1;
    wire       row_oob_nxt = (in_h_nxt > {2'd0, h_max});

    always @(*) begin
        mm2s_issue    = 1'b0;
        mm2s_kind_nxt = 2'd0;
        mm2s_addr_nxt = 16'd0;
        case (state_q)
        ST_BN_REQ: begin
            mm2s_issue = 1'b1; mm2s_kind_nxt = 2'd2; mm2s_addr_nxt = BN_DRAM_BASE;
        end
        ST_TILE_REQ: begin
            mm2s_issue = 1'b1; mm2s_kind_nxt = 2'd0; mm2s_addr_nxt = w_ptr;
        end
        // A layer with a single output row (Affine) has no sweep to hide the
        // prefetch behind, and the ST_RSWAP placement below would leave ST_PUSH
        // uncovered instead. Post it here in that case.
        ST_TSWAP: begin
            if (single_row && !(ft_last && tile_last)) begin
                mm2s_issue = 1'b1; mm2s_kind_nxt = 2'd0; mm2s_addr_nxt = w_ptr;
            end
        end
        ST_ROW_REQ: begin                  // first row of this tile's sweep
            if (!row_oob) begin
                mm2s_issue = 1'b1; mm2s_kind_nxt = 2'd1; mm2s_addr_nxt = row_base;
            end
        end
        // On every row but the last, prefetch the next row. On the LAST row
        // there is no next row, and leaving the port idle for a whole pixel
        // sweep is the largest single stall in the design, so the next weight
        // tile is fetched there instead. The wbuf write side is free (the PE is
        // reading the other half) and ST_TILE_END waits for it to land.
        ST_RSWAP: begin
            if (!oh_last) begin
                if (!row_oob_nxt) begin
                    mm2s_issue = 1'b1; mm2s_kind_nxt = 2'd1;
                    mm2s_addr_nxt = row_base + row_step;
                end
            end else if (!single_row && !(ft_last && tile_last)) begin
                mm2s_issue = 1'b1; mm2s_kind_nxt = 2'd0; mm2s_addr_nxt = w_ptr;
            end
        end
        default: ;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mm2s_busy <= 1'b0; mm2s_kind <= 2'd0; mm2s_addr <= 16'd0;
        end else if (mm2s_issue && !mm2s_busy) begin
            mm2s_busy <= 1'b1;
            mm2s_kind <= mm2s_kind_nxt;
            mm2s_addr <= mm2s_addr_nxt;
        end else if (mm2s_done) begin
            mm2s_busy <= 1'b0;
        end
    end

    always @(*) begin
        mm2s_req  = mm2s_busy;
        mm2s_base = mm2s_addr;
        case (mm2s_kind)
        2'd2   : mm2s_len = BN_WORDS;      // BN constants
        2'd1   : mm2s_len = row_words;     // one input row of one group
        default: mm2s_len = TILE_WORDS;    // one weight tile
        endcase
    end

    // s2mm : one burst per (chunk, channel group). Narrow mode walks the groups
    // through wb_grp; wide mode is the last layer and emits one flat burst.
    reg        s2mm_busy;
    reg [15:0] s2mm_addr;
    reg [LEN_W-1:0] s2mm_words;

    // pixels in this chunk = out_row+1 at the moment the chunk closed
    wire [LEN_W-1:0] chunk_words =
        {{(LEN_W-OB_A_BIT-1){1'b0}}, out_row} * NB_IN;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            s2mm_busy <= 1'b0; s2mm_addr <= 16'd0; s2mm_words <= {LEN_W{1'b0}};
        end else if ((state_q == ST_OUT_REQ) && !s2mm_busy) begin
            s2mm_busy  <= 1'b1;
            s2mm_addr  <= wide_out ? out_base
                                   : (grp_base + {{(16-ACC_A_BIT){1'b0}},
                                                  chunk_first} * NB_IN);
            s2mm_words <= wide_out ? out_words : chunk_words;
        end else if (s2mm_done) begin
            s2mm_busy <= 1'b0;
        end
    end
    always @(*) begin
        s2mm_req  = s2mm_busy;
        s2mm_base = s2mm_addr;
        s2mm_len  = s2mm_words;
    end

//---------------------------------------------------------------- [6] stream sink
//   strm_idx picks the bank in its low bits and the row above them.
//   Weight burst : TILE_WORDS words -> rows 0..ROW_SIZE-1
//   Input  burst : row_words  words -> rows 0..W-1
    assign wbuf_we = (strm_vld && strm_dest == 2'd0)
                   ? ({{(NB_W-1){1'b0}},1'b1} << strm_idx[WB_BANK_BIT-1:0])
                   : {NB_W{1'b0}};
    assign ibuf_we = (strm_vld && strm_dest == 2'd1)
                   ? ({{(NB_IN-1){1'b0}},1'b1} << strm_idx[IB_BANK_BIT-1:0])
                   : {NB_IN{1'b0}};
    assign bn_rf_we    = strm_vld && strm_dest == 2'd2;
    assign bn_rf_waddr = strm_idx[8:0];
    assign wbuf_waddr  = strm_idx[WB_BANK_BIT +: WB_A_BIT];
    assign ibuf_waddr  = strm_idx[IB_BANK_BIT +: IB_A_BIT];
    assign strm_wdata  = strm_data;

//---------------------------------------------------------------- [7] ping-pong
//   wbuf : swapped once per weight tile, so the next tile prefetches into the
//          other side while the PE uses this one.
//   ibuf : swapped once per input row. This is what hides the row load under
//          the pixel sweep, and the whole row-streaming idea depends on it.
//   obuf : swapped once per drain chunk, so s2mm reads one chunk while the
//          drain fills the next.
    reg wbuf_wr_ping, wbuf_rd_ping;
    reg ibuf_wr_ping, ibuf_rd_ping;
    reg obuf_wr_ping, obuf_rd_ping;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wbuf_wr_ping<=1'b0; wbuf_rd_ping<=1'b0;
            ibuf_wr_ping<=1'b0; ibuf_rd_ping<=1'b0;
            obuf_wr_ping<=1'b0; obuf_rd_ping<=1'b0;
        end else begin
            if (state_q == ST_TSWAP) begin
                wbuf_rd_ping <= wbuf_wr_ping;
                wbuf_wr_ping <= ~wbuf_wr_ping;
            end
            if (state_q == ST_RSWAP) begin
                ibuf_rd_ping <= ibuf_wr_ping;
                ibuf_wr_ping <= ~ibuf_wr_ping;
            end
            // ONCE PER CHUNK, not once per burst. ST_OUT_REQ is entered
            // GRP_PER_TILE times per chunk - one burst per output channel
            // group - and swapping on each of them handed the read side to the
            // empty half after group 0, so groups 1..3 streamed zeros. The
            // symptom was the first og_stride words correct and the rest of the
            // map blank.
            if ((state_q == ST_OUT_REQ) && (wb_grp == 2'd0)) begin
                obuf_rd_ping <= obuf_wr_ping;
                obuf_wr_ping <= ~obuf_wr_ping;
            end
        end
    end
    assign wbuf_wr_sel = wbuf_wr_ping;
    assign wbuf_rd_sel = wbuf_rd_ping;
    assign ibuf_wr_sel = ibuf_wr_ping;
    assign ibuf_rd_sel = ibuf_rd_ping;
    assign obuf_wr_sel = obuf_wr_ping;
    assign obuf_rd_sel = obuf_rd_ping;

//---------------------------------------------------------------- [8] FSM next
    always @(posedge clk or posedge rst) begin
        if (rst) state_q <= ST_IDLE;
        else     state_q <= state_nxt;
    end

    always @(*) begin
        state_nxt = state_q;
        case (state_q)
        ST_IDLE     : if (start_pulse)          state_nxt = ST_BN_REQ;
        ST_BN_REQ   :                           state_nxt = ST_BN_WAIT;
        ST_BN_WAIT  : if (!mm2s_busy)           state_nxt = ST_TILE_REQ;
        ST_TILE_REQ :                           state_nxt = ST_TILE_WAIT;
        ST_TILE_WAIT: if (!mm2s_busy)           state_nxt = ST_TSWAP;
        ST_TSWAP    :                           state_nxt = ST_PUSH;
        ST_PUSH     : if (push_cnt == ROW_SIZE) state_nxt = ST_ROW_REQ;
        // ST_TSWAP started the next tile's prefetch and the DMA serves one
        // request at a time, so this has to wait for the port before its own
        // issue is accepted. Leaving on the first cycle would drop the request
        // and start the pixel sweep on an ibuf that was never filled.
        ST_ROW_REQ  : if (!mm2s_busy)           state_nxt = ST_ROW_WAIT;
        ST_ROW_WAIT : if (!mm2s_busy)           state_nxt = ST_RSWAP;
        ST_RSWAP    :                           state_nxt = ST_PIX_RD;
        ST_PIX_RD   :                           state_nxt = ST_PIX_WR;
        ST_PIX_WR   :                           state_nxt = ST_PIX_SUM;
        ST_PIX_SUM  :                           state_nxt = ST_PIX_ACC;
        ST_PIX_ACC  : if (!ow_last)             state_nxt = ST_PIX_RD;
                      else                      state_nxt = ST_ROW_END;
        // the next row was prefetched during the sweep; wait for it to land
        // the weight prefetch posted at the last ST_RSWAP is waited for in
        // ST_TILE_END, not here, so the last row leaves immediately
        ST_ROW_END  : if (oh_last)              state_nxt = ST_TILE_END;
                      else if (!mm2s_busy)      state_nxt = ST_RSWAP;
        // the next tile was prefetched at ST_TSWAP, so no blocking load here
        ST_TILE_END : if (!mm2s_busy) begin
                          if (!tile_last)       state_nxt = ST_TSWAP;
                          else                  state_nxt = ST_DRAIN;
                      end
        ST_DRAIN    : if (dr_stop)              state_nxt = ST_DR_TAIL;
        ST_DR_TAIL  : if (tail_cnt == PIPE_N-1) state_nxt = ST_OUT_REQ;
        ST_OUT_REQ  :                           state_nxt = ST_OUT_WAIT;
        ST_OUT_WAIT : if (!s2mm_busy)           state_nxt = ST_CHUNK_END;
        ST_CHUNK_END: if (wide_out)             state_nxt = ST_DONE;
                      else if (!grp_last)       state_nxt = ST_OUT_REQ;
                      else if (!chunk_done)     state_nxt = ST_DRAIN;
                      else if (!ft_last)        state_nxt = ST_TSWAP;
                      else                      state_nxt = ST_DONE;
        ST_DONE     :                           state_nxt = ST_IDLE;
        default     :                           state_nxt = ST_IDLE;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) done <= 1'b0;
        else     done <= (state_q == ST_DONE);
    end

//---------------------------------------------------------------- [3b] counters
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ft_cnt<=0; ct_cnt<=0; fh_cnt<=0; fw_cnt<=0;
            oh_cnt<=0; ow_cnt<=0; push_cnt<=0; slot<=0;
            ct_base<=0; row_base<=0; w_ptr<=0; ft_base<=0; grp_base<=0;
            dr_oh<=0; dr_ow<=0; dr_slot<=0; chunk_first<=0; out_row<=0;
            chunk_done<=0; wb_grp<=0; wide_half_sel<=0;
        end else begin
            case (state_q)
            ST_IDLE: begin
                ft_cnt<=0; ct_cnt<=0; fh_cnt<=0; fw_cnt<=0;
                oh_cnt<=0; ow_cnt<=0; push_cnt<=0; slot<=0;
                dr_oh<=0; dr_ow<=0; dr_slot<=0; chunk_first<=0; out_row<=0;
                chunk_done<=0; wb_grp<=0; wide_half_sel<=0;
                w_ptr    <= w_base;
                ct_base  <= in_base;
                ft_base  <= out_base;
                grp_base <= out_base;      // group 0 of the first chunk
            end
            ST_TILE_REQ: begin
                w_ptr <= w_ptr + TILE_WORDS;      // now points at the next tile
            end
            ST_TSWAP: begin
                if (single_row && !(ft_last && tile_last))
                    w_ptr <= w_ptr + TILE_WORDS;
                push_cnt <= 0;                    // arm the PUSH counter
                oh_cnt   <= 0;
                ow_cnt   <= 0;
                slot     <= 0;
                row_base <= row_base0;            // (fh - pad) rows from ct_base
            end
            ST_RSWAP: if (oh_last && !single_row && !(ft_last && tile_last))
                w_ptr <= w_ptr + TILE_WORDS;      // consumed by this prefetch
            ST_PUSH: begin
                push_cnt <= push_cnt + 1'b1;      // 0..ROW_SIZE
            end
            ST_PIX_ACC: begin
                slot <= slot + 1'b1;
                if (!ow_last) ow_cnt <= ow_cnt + 1'b1;
            end
            ST_ROW_END: if (oh_last || !mm2s_busy) begin
                ow_cnt <= 0;
                if (!oh_last) begin
                    oh_cnt   <= oh_cnt + 1'b1;
                    row_base <= row_base + row_step;
                end
            end
            ST_TILE_END: if (!mm2s_busy) begin
                if (!fw_last) fw_cnt <= fw_cnt + 1'b1;
                else begin
                    fw_cnt <= 0;
                    if (!fh_last) fh_cnt <= fh_cnt + 1'b1;
                    else begin
                        fh_cnt <= 0;
                        if (!ct_last) begin
                            ct_cnt  <= ct_cnt + 1'b1;
                            ct_base <= ct_base + ct_stride;
                        end
                    end
                end
            end
            ST_DRAIN: begin
                if (wide_out) wide_half_sel <= ~wide_half_sel;
                if (dr_stop) begin
                    chunk_done <= dr_last;        // remember why we stopped
                end else if (wide_last) begin  // one pixel per accumulator slot
                    dr_slot <= dr_slot + 1'b1;
                    if (!dr_ow_last) dr_ow <= dr_ow + 1'b1;
                    else begin dr_ow <= 0; dr_oh <= dr_oh + 1'b1; end
                end
                // counted even on the cycle that closes the chunk
                if (dr_emit) out_row <= out_row + 1'b1;
            end
            ST_OUT_REQ: begin
                grp_base <= grp_base + og_stride; // next group's DRAM region
            end
            ST_CHUNK_END: begin
                if (!grp_last) begin
                    wb_grp <= wb_grp + 1'b1;
                end else begin
                    wb_grp   <= 0;
                    grp_base <= ft_base;          // rewind for the next chunk
                    if (!chunk_done) begin        // more chunks in this ft
                        dr_slot     <= dr_slot + 1'b1;
                        chunk_first <= chunk_first + out_row;
                        out_row     <= 0;
                        if (!dr_ow_last) dr_ow <= dr_ow + 1'b1;
                        else begin dr_ow <= 0; dr_oh <= dr_oh + 1'b1; end
                    end else if (!ft_last) begin  // next output-channel tile
                        ft_cnt      <= ft_cnt + 1'b1;
                        ct_cnt      <= 0;
                        ct_base     <= in_base;
                        ft_base     <= ft_base + (og_stride * GRP_PER_TILE);
                        grp_base    <= ft_base + (og_stride * GRP_PER_TILE);
                        dr_oh<=0; dr_ow<=0; dr_slot<=0;
                        chunk_first<=0; out_row<=0; chunk_done<=0;
                    end
                end
            end
            default: ;
            endcase
        end
    end

//---------------------------------------------------------------- [9] weight push
//   BRAM read latency 1 : issue the address combinationally, write the PE row
//   one cycle behind. Registering the address instead collapses the offset to
//   zero and silently corrupts the weights.
    reg [ROW_BIT-1:0] push_cnt_d1;
    always @(posedge clk or posedge rst) begin
        if (rst) push_cnt_d1 <= 0;
        else     push_cnt_d1 <= push_cnt[ROW_BIT-1:0];
    end

    always @(*) begin
        wbuf_raddr  = {WB_A_BIT{1'b0}};
        pe_w_en     = 1'b0;
        pe_row_addr = {ROW_BIT{1'b0}};
        if (state_q == ST_PUSH) begin
            wbuf_raddr  = {{(WB_A_BIT-ROW_BIT){1'b0}}, push_cnt[ROW_BIT-1:0]};
            pe_w_en     = (push_cnt != 0);        // no data yet on cycle 0
            pe_row_addr = push_cnt_d1;            // write lags by one
        end
    end

//---------------------------------------------------------------- [10] compute
//   ST_PIX_RD drives ibuf_raddr; the lanes (and so the combinational PE result)
//   are valid in ST_PIX_WR. The accumulator read is issued in the same cycle as
//   the ibuf read so the two latencies overlap instead of stacking.
    always @(*) begin
        ibuf_raddr = in_w[IB_A_BIT-1:0];
        acc_addr   = slot;
        acc_first  = acc_load;
        acc_en     = (state_q == ST_PIX_RD)  ? !acc_load
                   : (state_q == ST_PIX_WR)  ? !acc_load
                   : (state_q == ST_PIX_SUM) ? !acc_load
                   : (state_q == ST_PIX_ACC) ? 1'b1
                   :                           1'b0;
        acc_ph     = (state_q == ST_PIX_ACC) && !acc_load;
    end

    // the mask has to arrive with the data, not with the address
    always @(posedge clk or posedge rst) begin
        if (rst)                        ibuf_oob <= 1'b0;
        else if (state_q == ST_PIX_RD)  ibuf_oob <= row_oob || col_oob;
    end

        always @(*) begin
        dr_en   = (state_q == ST_DRAIN);
        dr_addr = dr_slot;
    end

    // tail counter : ST_DR_TAIL now waits PIPE_N cycles, not 1, so the last
    // narrow-mode pixels clear the BN/requant pipeline before s2mm starts.
    reg [1:0] tail_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst) tail_cnt <= 2'd0;
        else if (state_q == ST_DR_TAIL) tail_cnt <= tail_cnt + 1'b1;
        else tail_cnt <= 2'd0;
    end

    // narrow mode : PIPE_N-deep delay line, aligned to the BN/requant latency
    reg                 we_pipe   [0:PIPE_N-1];
    reg [OB_A_BIT-1:0]  waddr_pipe[0:PIPE_N-1];
    reg                 pv_pipe   [0:PIPE_N-1];
    reg [7:0]           oh_pipe   [0:PIPE_N-1];
    reg [7:0]           ow_pipe   [0:PIPE_N-1];

    // wide mode : unchanged 1-cycle delay (wide mode reads acc_result raw,
    // bypassing BN/requant entirely, so it must NOT use the deeper pipeline)
    reg                 we_wide_r;
    reg [OB_A_BIT-1:0]  waddr_wide_r;
    reg                 whs_d1_r;

    integer p;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (p = 0; p < PIPE_N; p = p + 1) begin
                we_pipe[p]    <= 1'b0;
                waddr_pipe[p] <= {OB_A_BIT{1'b0}};
                pv_pipe[p]    <= 1'b0;
                oh_pipe[p]    <= 8'd0;
                ow_pipe[p]    <= 8'd0;
            end
            we_wide_r    <= 1'b0;
            waddr_wide_r <= {OB_A_BIT{1'b0}};
            whs_d1_r     <= 1'b0;
        end else begin
            we_pipe[0]    <= (state_q == ST_DRAIN) && dr_emit;
            waddr_pipe[0] <= out_row[OB_A_BIT-1:0];
            pv_pipe[0]    <= (state_q == ST_DRAIN);
            oh_pipe[0]    <= dr_oh;
            ow_pipe[0]    <= dr_ow;
            for (p = 1; p < PIPE_N; p = p + 1) begin
                we_pipe[p]    <= we_pipe[p-1];
                waddr_pipe[p] <= waddr_pipe[p-1];
                pv_pipe[p]    <= pv_pipe[p-1];
                oh_pipe[p]    <= oh_pipe[p-1];
                ow_pipe[p]    <= ow_pipe[p-1];
            end

            we_wide_r    <= (state_q == ST_DRAIN) && dr_emit;
            waddr_wide_r <= out_row[OB_A_BIT-1:0];
            whs_d1_r     <= wide_half_sel;
        end
    end

    // output : combinational passthrough of the last pipeline stage, so no
    // extra register is added beyond the PIPE_N stages above
    always @(*) begin
        obuf_we           = wide_out ? we_wide_r    : we_pipe[PIPE_N-1];
        obuf_waddr        = wide_out ? waddr_wide_r : waddr_pipe[PIPE_N-1];
        pool_vld          = pv_pipe[PIPE_N-1];
        pool_oh           = oh_pipe[PIPE_N-1];
        pool_ow           = ow_pipe[PIPE_N-1];
        wide_half_sel_d1  = whs_d1_r;
    end

endmodule
