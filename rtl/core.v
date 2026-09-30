`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : core     (controller + buffers + PE array + post path)
//
//   ibuf(pp) --unpack--> PE --+
//   wbuf(pp) --unpack--> PE --+--> accumulator (COL_SIZE x ACCUM_WIDTH)
//                                       |
//                     [drain] acc --> BN --> ReLU --> requant --+
//                                     (or sign-extended logit) --+--> obuf(pp) -> s2mm
//
//   BN / ReLU / requant sit on the DRAIN path only. During compute the
//   accumulator just adds. See controller.v for the loop order and glossary.
//
// ROW_SIZE vs COL_SIZE
//   ROW_SIZE = PE rows    = reduction width. One ibuf row is ROW_SIZE bytes and
//              feeds every column; the adder tree sums all ROW_SIZE products.
//   COL_SIZE = PE columns = output channels produced in parallel. One wbuf row
//              is COL_SIZE bytes: the weights of one reduction index across all
//              output channels.
//   These used to be the same number, which hid three places where the wrong
//   one was used. They are now independent, so every net below states which
//   dimension it belongs to.
//
//   Bank counts follow from the widths, not the other way round:
//     NB_IN  = ROW_SIZE*8/32     ibuf row  = ROW_SIZE bytes
//     NB_W   = COL_SIZE*8/32     wbuf row  = COL_SIZE bytes
//     NB_OUT = COL_SIZE*8/32     obuf row  = COL_SIZE bytes
//
//   A weight tile is ROW_SIZE x COL_SIZE INT8 = ROW_SIZE*NB_W DRAM words.
//   At 8x32 that is 64 words, NOT the 256 the controller still assumes.
//////////////////////////////////////////////////////////////////////////////////
module core #(
    parameter ROW_SIZE     = 8,    // PE rows    : reduction width
    parameter COL_SIZE     = 32,   // PE columns : output channels in parallel
    parameter DATA_WIDTH   = 8,    // INT8 activations and weights
    parameter MEMORY_WIDTH = 32,   // DRAM / buffer word width
    parameter LEN_W        = 13    // burst length / word index. 6272 > 1023.
)(
    input               clk,
    input               rst,                    // async, active HIGH

    // CSR : per-layer config, written once by the host before start and held
    // constant for the whole layer (DRAM bases, loop bounds, mode flags).
    input               csr_we,                 // 1-cycle write strobe
    input      [3:0]    csr_addr,               // register index
    input      [31:0]   csr_data,               // value to store
    output              done,                   // 1-cycle pulse : layer finished

    // mm2s : descriptor out, word stream in
    output              mm2s_req,
    output     [15:0]   mm2s_base,
    output     [LEN_W-1:0] mm2s_len,
    input               mm2s_done,
    input               strm_vld,               // inbound word valid
    input      [31:0]   strm_data,              // inbound word
    input      [LEN_W-1:0] strm_idx,            // its index inside the burst

    // s2mm : descriptor out, word served on request
    output              s2mm_req,
    output     [15:0]   s2mm_base,
    output     [LEN_W-1:0] s2mm_len,
    input               s2mm_done,
    input               wb_req,                 // DMA asks for the word at wb_idx
    input      [LEN_W-1:0] wb_idx,              // word index inside the burst
    output     [31:0]   wb_data                 // the requested word
);
    //------------------------------------------------------------------
    // derived sizes. Nothing below hardcodes 32, 8, 21 or 26 any more.
    //------------------------------------------------------------------
    localparam NB_IN  = (ROW_SIZE*DATA_WIDTH)/MEMORY_WIDTH;  // ibuf banks : 2
    localparam NB_W   = (COL_SIZE*DATA_WIDTH)/MEMORY_WIDTH;  // wbuf banks : 8
    localparam NB_OUT = (COL_SIZE*DATA_WIDTH)/MEMORY_WIDTH;  // obuf banks : 8

    localparam ROW_BIT       = $clog2(ROW_SIZE);             // 3
    localparam BANK_BIT      = $clog2(NB_OUT);               // 3
    localparam PE_OUT_WIDTH  = ROW_BIT + (DATA_WIDTH*2);     // 19 : ROW_SIZE MACs
    localparam ACCUM_WIDTH   = PE_OUT_WIDTH + 5;             // 24 : + ig tiles
    localparam A_W           = 4;                            // BN scale width
    localparam B_W           = 20;                           // BN offset width
    localparam BN_WIDTH      = ACCUM_WIDTH + A_W;            // 28
    localparam REQ_W         = 8;                            // requant out = INT8

    // Buffer depths are pinned to the blk_mem_gen IPs already generated.
    // Bump these together with the IP when the CNN loops need deeper buffers.
    localparam IB_A_BIT  = 5;    // ibuf depth 32 : holds W input columns (28)
    localparam WB_A_BIT  = 5;    // wbuf depth 32 : one tile is ROW_SIZE rows (8)
    localparam OB_A_BIT  = 6;    // obuf depth 64 : one drain chunk
    
    localparam ACC_A_BIT = 10;
    wire [ACC_A_BIT-1:0] acc_addr;      // controller -> accumulator
    
    //------------------------------------------------------------------
    // controller <-> the rest
    //------------------------------------------------------------------
    wire [NB_W-1:0]       wbuf_we;               // one-hot bank write enable
    wire [NB_IN-1:0]      ibuf_we;               // one-hot bank write enable
    wire [WB_A_BIT-1:0]  wbuf_waddr;            // wbuf row being filled
    wire [IB_A_BIT-1:0]  ibuf_waddr;            // ibuf row being filled
    wire [31:0]           strm_wdata;            // word being filled
    wire wbuf_wr_sel, wbuf_rd_sel;               // weight buffer ping-pong
    wire ibuf_wr_sel, ibuf_rd_sel;               // input  buffer ping-pong
    wire obuf_wr_sel, obuf_rd_sel;               // output buffer ping-pong
    wire [WB_A_BIT-1:0]  wbuf_raddr;            // PE weight row 0..ROW_SIZE-1
    wire [IB_A_BIT-1:0]  ibuf_raddr;            // this image's ig tile
    wire                  bn_rf_we;              // BN regfile write strobe
    wire [8:0]            bn_rf_waddr;           // BN regfile write index
    wire [8:0]            bn_group_base;         // BN regfile read base
    wire                  pe_w_en;               // PE weight row write
    wire [ROW_BIT-1:0]    pe_row_addr;           // which PE row
    wire                  acc_en, acc_ph, acc_first;   // accumulator control
    wire                  dr_en;                 // accumulator drain read
    wire [ACC_A_BIT-1:0]  dr_addr;
    wire                  ibuf_oob;              // this lane set is padding
    wire [1:0]            wb_grp;                // obuf group s2mm is reading
    wire                  pool_en, pool_vld;     // 2x2 maxpool control
    wire [7:0]            pool_oh, pool_ow;
    wire [3:0]            rq_shift, rq_mult;     // requant parameters
    wire [1:0]            bn_shift;              // BN s1, per layer
    wire                  bn_en, relu_en;        // post-path enables
    wire                  wide_out;              // 32-bit logit mode (L5)
    wire                  wide_half_sel;         // which half of the columns
    wire                  wide_half_sel_d1;      // the same, aligned to obuf_we
    wire                  obuf_we;               // drain write strobe
    wire [OB_A_BIT-1:0]   obuf_waddr;            // drain write row

    //------------------------------------------------------------------
    // datapath nets.  ROW_SIZE-wide on the activation side, COL_SIZE-wide
    // from the weights onward.
    //------------------------------------------------------------------
    wire [NB_IN*32-1:0]              ibuf_rdata;   // ROW_SIZE bytes
    wire [NB_W*32-1:0]               wbuf_rdata;   // COL_SIZE bytes
    wire [ROW_SIZE*DATA_WIDTH-1:0]   ibuf_raw;     // straight out of the buffer
    wire [ROW_SIZE*DATA_WIDTH-1:0]   ibuf_lanes;   // ... after the padding mask
    wire [COL_SIZE*DATA_WIDTH-1:0]   wbuf_lanes;   // COL_SIZE INT8 weights
    wire [COL_SIZE*PE_OUT_WIDTH-1:0] pe_result;    // COL_SIZE dot products
    wire [COL_SIZE*ACCUM_WIDTH-1:0]  acc_result;   // COL_SIZE partial sums
    wire [COL_SIZE*BN_WIDTH-1:0]     bn_result;    // after BN
    wire [COL_SIZE*BN_WIDTH-1:0]     relu_result;  // after ReLU
    wire [COL_SIZE*REQ_W-1:0]        rq_result;    // after requant
    wire [COL_SIZE*A_W-1:0]          bn_a;         // BN scale,  per channel
    wire [COL_SIZE*B_W-1:0]          bn_b;         // BN offset, per channel

    //------------------------------------------------------------------
    // controller
    //------------------------------------------------------------------
    controller #(
        .ROW_SIZE(ROW_SIZE), .COL_SIZE(COL_SIZE),
        .NB_IN(NB_IN), .NB_W(NB_W), .NB_OUT(NB_OUT),
        .ROW_BIT(ROW_BIT), .IB_A_BIT(IB_A_BIT), .WB_A_BIT(WB_A_BIT),
        .OB_A_BIT(OB_A_BIT), .ACC_A_BIT(ACC_A_BIT), .LEN_W(LEN_W)
    ) u_ctrl (
        .clk(clk), .rst(rst),
        .csr_we(csr_we), .csr_addr(csr_addr), .csr_data(csr_data), .done(done),
        .mm2s_req(mm2s_req), .mm2s_base(mm2s_base), .mm2s_len(mm2s_len),
        .mm2s_done(mm2s_done),
        .s2mm_req(s2mm_req), .s2mm_base(s2mm_base), .s2mm_len(s2mm_len),
        .s2mm_done(s2mm_done),
        .strm_vld(strm_vld), .strm_data(strm_data), .strm_idx(strm_idx),
        .wbuf_we(wbuf_we), .ibuf_we(ibuf_we),
        .wbuf_waddr(wbuf_waddr), .ibuf_waddr(ibuf_waddr),
        .strm_wdata(strm_wdata),
        .wbuf_wr_sel(wbuf_wr_sel), .wbuf_rd_sel(wbuf_rd_sel),
        .ibuf_wr_sel(ibuf_wr_sel), .ibuf_rd_sel(ibuf_rd_sel),
        .obuf_wr_sel(obuf_wr_sel), .obuf_rd_sel(obuf_rd_sel),
        .wbuf_raddr(wbuf_raddr), .ibuf_raddr(ibuf_raddr), .ibuf_oob(ibuf_oob),
        .bn_rf_we(bn_rf_we), .bn_rf_waddr(bn_rf_waddr),
        .bn_group_base(bn_group_base),
        .pe_w_en(pe_w_en), .pe_row_addr(pe_row_addr),
        .acc_en(acc_en), .acc_ph(acc_ph), .acc_first(acc_first),
        .acc_addr(acc_addr), .dr_en(dr_en), .dr_addr(dr_addr),
        .rq_shift(rq_shift), .rq_mult(rq_mult), .bn_shift(bn_shift),
        .bn_en(bn_en), .relu_en(relu_en),
        .wide_out(wide_out), .wide_half_sel(wide_half_sel),
        .wide_half_sel_d1(wide_half_sel_d1),
        .pool_en(pool_en), .pool_vld(pool_vld),
        .pool_oh(pool_oh), .pool_ow(pool_ow),
        .obuf_we(obuf_we), .obuf_waddr(obuf_waddr), .wb_grp(wb_grp)
    );

    //------------------------------------------------------------------
    // input / weight buffers (ping-pong)
    //   ld_* = DMA fill side, cp_* = compute read side (module port names)
    //   The two buffers now have DIFFERENT bank counts, so they also need
    //   separate fill addresses: one DRAM word lands in a different row of
    //   each buffer.
    //------------------------------------------------------------------
    input_buffer #(.NUM_BANKS(NB_IN), .A_BIT(IB_A_BIT)) u_in_buf (
        .clk(clk), .ld_sel(ibuf_wr_sel), .cp_sel(ibuf_rd_sel),
        .ld_we(ibuf_we), .ld_addr(ibuf_waddr), .ld_din(strm_wdata),
        .cp_addr(ibuf_raddr), .cp_dout(ibuf_rdata)
    );
    weight_buffer #(.NUM_BANKS(NB_W), .A_BIT(WB_A_BIT)) u_w_buf (
        .clk(clk), .ld_sel(wbuf_wr_sel), .cp_sel(wbuf_rd_sel),
        .ld_we(wbuf_we), .ld_addr(wbuf_waddr), .ld_din(strm_wdata),
        .cp_addr(wbuf_raddr), .cp_dout(wbuf_rdata)
    );

    //------------------------------------------------------------------
    // unpack a buffer row into INT8 lanes.  bank_unpack derives its own bank
    // count from the lane count, so the activation side gets ROW_SIZE and the
    // weight side COL_SIZE.
    //------------------------------------------------------------------
    bank_unpack #(.MEMORY_WIDTH(MEMORY_WIDTH), .DATA_WIDTH(DATA_WIDTH),
                  .ROW_SIZE(ROW_SIZE))
    u_in_unpack (.bank_dout(ibuf_rdata), .ch_out(ibuf_raw));

    // Zero-padding. The window position (oh+fh-pad, ow+fw-pad) can fall outside
    // the input map; the adder tree adds all ROW_SIZE products unconditionally,
    // so those lanes have to be forced to zero rather than skipped. ibuf_oob is
    // registered inside the controller so it arrives WITH the buffer data, not
    // with the address - the same lead/lag rule as every other BRAM here.
    assign ibuf_lanes = ibuf_oob ? {(ROW_SIZE*DATA_WIDTH){1'b0}} : ibuf_raw;

    bank_unpack #(.MEMORY_WIDTH(MEMORY_WIDTH), .DATA_WIDTH(DATA_WIDTH),
                  .ROW_SIZE(COL_SIZE))
    u_w_unpack  (.bank_dout(wbuf_rdata), .ch_out(wbuf_lanes));

    //------------------------------------------------------------------
    // PE array : weight-stationary. Once a tile is pushed, i_data -> o_result
    // is fully combinational (latency 0).
    //   i_data   is ROW_SIZE lanes, broadcast down every column
    //   i_weight is COL_SIZE lanes, one scalar per column
    //------------------------------------------------------------------
    pe_array_hier #(.DATA_WIDTH(DATA_WIDTH),
                    .ROW_SIZE(ROW_SIZE), .COL_SIZE(COL_SIZE))
    u_pe (
        .clk(clk), .rst(rst),
        .we_w(pe_w_en), .row_addr(pe_row_addr),
        .i_data(ibuf_lanes), .i_weight(wbuf_lanes),
        .o_result(pe_result)
    );

    //------------------------------------------------------------------
    // accumulator : COL_SIZE lanes, one live partial-sum set
    //------------------------------------------------------------------
    accumulator #(.COL_SIZE(COL_SIZE), .PE_OUT_WIDTH(PE_OUT_WIDTH),
                  .ACCUM_WIDTH(ACCUM_WIDTH), .ACC_A_BIT(ACC_A_BIT))
    u_acc (
        .clk(clk), .rst(rst),
        .acc_en(acc_en), .acc_ph(acc_ph), .acc_first(acc_first),
        .acc_addr(acc_addr), .i_pe_result(pe_result),
        .dr_en(dr_en), .dr_addr(dr_addr),
        .o_accum_result(acc_result)
    );

    //------------------------------------------------------------------
    // BN constant regfile : written from the stream, read by group.
    // Sized in output channels, so it tracks COL_SIZE.
    //------------------------------------------------------------------
    bn_regfile u_bn_rf (
        .clk(clk), .we(bn_rf_we), .waddr(bn_rf_waddr), .wdata(strm_data),
        .bn_base(bn_group_base), .o_a(bn_a), .o_b(bn_b)
    );

    //------------------------------------------------------------------
    // drain post path : acc -> BN -> ReLU -> requant   (all combinational)
    //------------------------------------------------------------------
    // S1 is a CSR value, not a parameter : the five conv layers want
    // 0, 2, 3, 2, 3 and forcing them all to 2 costs 17 points of accuracy.
    batch_norm #(.CH(COL_SIZE), .ACC_W(ACCUM_WIDTH), .A_W(A_W), .B_W(B_W),
                 .OUT_W(BN_WIDTH), .S_W(2))
    u_bn (.clk(clk), .i_acc(acc_result), .i_a(bn_a), .i_b(bn_b),
          .i_s1(bn_shift), .i_bn_en(bn_en), .o_data(bn_result));

    ReLU #(.COL(COL_SIZE), .DATA_WIDTH(BN_WIDTH))
    u_relu (.i_data(bn_result), .i_relu_en(relu_en), .o_data(relu_result));

    requant #(.CH(COL_SIZE), .IN_W(BN_WIDTH), .M_W(4), .OUT_W(REQ_W))
    u_rq (.clk(clk), .i_data(relu_result), .i_m2(rq_mult), .i_shift(rq_shift),
          .o_data(rq_result));

    //------------------------------------------------------------------
    // 2x2 maxpool, last stage of the drain. Pooling AFTER requant is
    // bit-identical to pooling before it (requant is monotonic) and compares
    // INT8 instead of BN_WIDTH. The module has zero latency, so the drain
    // keeps its single "obuf write lags the accumulator read by one" rule.
    // The controller already gates obuf_we on the same emit condition, so
    // o_valid is left unconnected and only o_data is used.
    //------------------------------------------------------------------
    localparam LB_A_BIT = 4;          // line buffer : OW/2, 14 at OW = 28
    wire [COL_SIZE*REQ_W-1:0] pool_result;

    maxpool #(.COL_SIZE(COL_SIZE), .DATA_WIDTH(REQ_W), .LB_A_BIT(LB_A_BIT))
    u_pool (
        .clk(clk), .rst(rst),
        .en(pool_vld), .pool_en(pool_en),
        .ow_odd(pool_ow[0]), .oh_odd(pool_oh[0]),
        .col(pool_ow[LB_A_BIT:1]),
        .i_data(rq_result), .o_data(pool_result), .o_valid()
    );

    //------------------------------------------------------------------
    // wide mode (L5) : emit sign-extended 32-bit logits instead of INT8.
    // Only NB_OUT lanes fit in one row, so wide_half_sel picks the lower or
    // upper half of the columns and the drain runs twice per og.
    //------------------------------------------------------------------
    wire [NB_OUT*32-1:0] wide_wdata;
    genvar j;
    generate
        for (j = 0; j < NB_OUT; j = j+1) begin : g_wide
            wire signed [ACCUM_WIDTH-1:0] logit =
                $signed(acc_result[((wide_half_sel_d1 ? NB_OUT : 0) + j)*ACCUM_WIDTH
                                   +: ACCUM_WIDTH]);
            assign wide_wdata[j*32 +: 32] =
                {{(32-ACCUM_WIDTH){logit[ACCUM_WIDTH-1]}}, logit};
        end
    endgenerate

    // normal mode : 4 INT8 channels per 32-bit word, NB_OUT words = COL_SIZE
    wire [NB_OUT*32-1:0] narrow_wdata;
    generate
        for (j = 0; j < NB_OUT; j = j+1) begin : g_narrow
            assign narrow_wdata[j*32 +: 32] = {
                pool_result[(j*4+3)*REQ_W +: REQ_W],
                pool_result[(j*4+2)*REQ_W +: REQ_W],
                pool_result[(j*4+1)*REQ_W +: REQ_W],
                pool_result[(j*4+0)*REQ_W +: REQ_W]
            };
        end
    endgenerate

    wire [NB_OUT*32-1:0] obuf_wdata = wide_out ? wide_wdata : narrow_wdata;

    //------------------------------------------------------------------
    // output buffer (ping-pong) : filled by the drain, read out by s2mm.
    // The DMA asks for words by index; each row is NB_OUT words, so
    //   wb_idx[BANK_BIT +: OB_A_BIT] = row (og)
    //   wb_idx[BANK_BIT-1:0]         = bank inside the row
    // The row address is driven one cycle ahead because the buffer is a BRAM
    // with read latency 1.
    //   fl_* = fill side, dr_* = drain side (module port names)
    //------------------------------------------------------------------
    wire [NB_OUT*32-1:0] obuf_rdata;

    // NARROW : the activation layout in DRAM is channel-group major, so s2mm
    // emits ONE output channel group at a time and wb_grp says which. A group
    // is ROW_SIZE bytes = GRP_WORDS words, so the burst walks two words per
    // obuf row and picks the banks belonging to that group.
    // WIDE : the last layer writes 32-bit logits and has no next layer to feed,
    // so it keeps the flat row-major walk the MLP used.
    localparam GRP_WORDS = (ROW_SIZE*DATA_WIDTH)/MEMORY_WIDTH;   // 2
    localparam GRP_BIT   = (GRP_WORDS > 1) ? $clog2(GRP_WORDS) : 1;

    wire [OB_A_BIT-1:0]  wb_row  = wide_out ? wb_idx[BANK_BIT +: OB_A_BIT]
                                            : wb_idx[GRP_BIT  +: OB_A_BIT];
    wire [BANK_BIT-1:0]  wb_bank = wide_out ? wb_idx[BANK_BIT-1:0]
                                            : {wb_grp, wb_idx[GRP_BIT-1:0]};
    wire                 wb_row_end = wide_out ? (wb_idx[BANK_BIT-1:0] == NB_OUT-1)
                                               : (wb_idx[GRP_BIT-1:0] == GRP_WORDS-1);
    wire [OB_A_BIT-1:0]  wb_row_nxt = wb_row;

    output_buffer #(.NUM_BANKS(NB_OUT), .A_BIT(OB_A_BIT)) u_ob (
        .clk(clk), .fl_sel(obuf_wr_sel), .dr_sel(obuf_rd_sel),
        .fl_we(obuf_we), .fl_addr(obuf_waddr), .fl_din(obuf_wdata),
        .dr_addr(wb_row_nxt), .dr_dout(obuf_rdata)
    );

    // pick the requested 32-bit word out of the row. obuf_rdata is the row
    // addressed LAST cycle (synchronous BRAM), so the word select has to be
    // the bank of that same request, not of whatever wb_idx says now. dma.v
    // holds wb_idx for several cycles and never noticed; a burst DMA that
    // asks for a new word every cycle would pick the neighbouring word.
    reg [BANK_BIT-1:0] wb_bank_d1;
    always @(posedge clk) wb_bank_d1 <= wb_bank;
    assign wb_data = obuf_rdata[wb_bank_d1*32 +: 32];

endmodule