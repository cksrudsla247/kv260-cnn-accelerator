`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : maxpool     (2x2 stride 2, on the drain path)
//
//   Sits between requant and the output buffer, so pooling costs no extra pass
//   and no DRAM round trip: the drain already walks the output map in raster
//   order, which is exactly the order a 2x2 pool wants.
//
//     for oh, ow in raster order:
//       h = (ow odd) ? max(left, cur) : cur        horizontal pair
//       oh even : line_buf[ow>>1] <= h             stash, emit nothing
//       oh odd  : emit max(line_buf[ow>>1], h)     vertical pair
//
//   So one value comes out for every four that go in, and only on the cycle
//   where both oh and ow are odd.
//
// WHY INT8 AND NOT THE BN WIDTH
//   requant is a per-channel multiply by a positive constant followed by a
//   right shift, which is monotonic, so max(requant(a), requant(b)) equals
//   requant(max(a,b)). Pooling after requant is therefore bit-identical to
//   pooling before it, and compares 8 bits instead of 28.
//
// WHY THE LINE BUFFER IS NOT A BRAM
//   It is (OW/2) x COL_SIZE bytes - 14 x 32 for the widest layer here, 4 kbit
//   in total. As a register array it reads asynchronously, so this module adds
//   ZERO latency and the drain pipeline keeps the single "obuf write lags the
//   accumulator read by one" rule it already has. A BRAM would add a second
//   lead/lag relationship to the one part of the design that has caused the
//   most bugs, to save a few hundred LUTs. Synthesis infers distributed RAM.
//
// COMPARISON IS SIGNED
//   The values are INT8 activations. With relu_en on they are non-negative and
//   an unsigned compare would agree, but relu_en is a per-layer CSR bit and
//   nothing here should depend on it being set.
//
// BYPASS
//   pool_en = 0 passes i_data straight through and o_valid follows en, so a
//   layer that does not pool needs no separate path.
//////////////////////////////////////////////////////////////////////////////////
module maxpool #(
    parameter COL_SIZE   = 32,   // lanes = output channels in parallel
    parameter DATA_WIDTH = 8,    // INT8 activations
    parameter LB_A_BIT   = 4     // line buffer depth : OW/2, 14 at OW = 28
)(
    input                                 clk,
    input                                 rst,       // async, active HIGH

    input                                 en,        // i_data is a valid pixel
    input                                 pool_en,   // 0 = straight through
    input                                 ow_odd,    // right half of the pair
    input                                 oh_odd,    // lower half of the pair
    input      [LB_A_BIT-1:0]             col,       // ow >> 1
    input      [COL_SIZE*DATA_WIDTH-1:0]  i_data,

    output     [COL_SIZE*DATA_WIDTH-1:0]  o_data,
    output                                o_valid    // emit this cycle
);
    localparam LB_DEPTH = 1 << LB_A_BIT;

    // the pixel to the left of this one, held one cycle
    reg  [COL_SIZE*DATA_WIDTH-1:0] left;
    // one horizontal max per column pair, carried from the even row to the odd
    reg  [COL_SIZE*DATA_WIDTH-1:0] line_buf [0:LB_DEPTH-1];

    wire [COL_SIZE*DATA_WIDTH-1:0] lb_rd = line_buf[col];   // async read

    wire [COL_SIZE*DATA_WIDTH-1:0] h_max;   // after the horizontal pair
    wire [COL_SIZE*DATA_WIDTH-1:0] v_max;   // after the vertical pair

    genvar g;
    generate
        for (g = 0; g < COL_SIZE; g = g+1) begin : g_lane
            wire signed [DATA_WIDTH-1:0] cur =
                $signed(i_data[g*DATA_WIDTH +: DATA_WIDTH]);
            wire signed [DATA_WIDTH-1:0] lft =
                $signed(left  [g*DATA_WIDTH +: DATA_WIDTH]);
            wire signed [DATA_WIDTH-1:0] stash =
                $signed(lb_rd [g*DATA_WIDTH +: DATA_WIDTH]);

            // on an even column there is nothing to pair with yet
            wire signed [DATA_WIDTH-1:0] hm =
                ow_odd ? ((lft > cur) ? lft : cur) : cur;
            assign h_max[g*DATA_WIDTH +: DATA_WIDTH] = hm;

            assign v_max[g*DATA_WIDTH +: DATA_WIDTH] =
                (stash > hm) ? stash : hm;
        end
    endgenerate

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            left <= {(COL_SIZE*DATA_WIDTH){1'b0}};
            for (i = 0; i < LB_DEPTH; i = i+1)
                line_buf[i] <= {(COL_SIZE*DATA_WIDTH){1'b0}};
        end else if (en) begin
            left <= i_data;
            // the even row stashes its horizontal max for the odd row below it
            if (pool_en && ow_odd && !oh_odd) line_buf[col] <= h_max;
        end
    end

    assign o_data  = pool_en ? v_max : i_data;
    assign o_valid = pool_en ? (en && ow_odd && oh_odd) : en;

endmodule
