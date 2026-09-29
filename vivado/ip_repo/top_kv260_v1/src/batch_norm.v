`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/15 13:37:26
// Design Name: 
// Module Name: batch_norm
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


//////////////////////////////////////////////////////////////////////////////////
// S1 IS A PER-LAYER INPUT, NOT A PARAMETER
//
//   Quantisation picks s1 = max(A_W-1 - ceil(log2(max|a|)), 0) so the 4-bit
//   BN multiplier keeps as much of `a` as it can. In the MLP every layer landed
//   on s1 = 2 and it was compiled in. The CNN does not:
//
//     Conv1_1 0   Conv1_2 2   Conv2_1 3   Conv2_2 2   Conv3 3
//
//   Measured on 500 MNIST images: forcing every layer to s1 = 2 gives 81.6%
//   against 98.6% with the per-layer shift, because Conv1_1's `a` saturates the
//   4-bit field. 17 points is not a rounding difference, so the shift comes in
//   from the CSR now (CSR8[14:13]).
//////////////////////////////////////////////////////////////////////////////////
module batch_norm#(
    parameter CH    = 32,
    parameter ACC_W = 24,
    parameter A_W   = 4,
    parameter B_W   = 20,
    parameter OUT_W = ACC_W + A_W,
    parameter S_W   = 2
)(
    input  wire                clk,
    input  wire [CH*ACC_W-1:0] i_acc,
    input  wire [CH*A_W-1:0]   i_a,
    input  wire [CH*B_W-1:0]   i_b,
    input  wire [S_W-1:0]      i_s1,
    input  wire                i_bn_en,
    output wire [CH*OUT_W-1:0] o_data
);
    reg  [S_W-1:0] s1_r;
    reg            bn_en_r;
    reg  [CH*B_W-1:0] b_r;

    always @(posedge clk) begin
        s1_r    <= i_s1;
        bn_en_r <= i_bn_en;
        b_r     <= i_b;
    end

    genvar ch;
    generate
        for (ch = 0; ch < CH; ch = ch + 1) begin : g_bn
            wire signed [ACC_W-1:0] acc = $signed(i_acc[ch*ACC_W +: ACC_W]);
            wire signed [A_W-1:0]   a   = $signed(i_a  [ch*A_W   +: A_W  ]);
            wire signed [OUT_W-1:0] prod = acc * a;

            reg signed [OUT_W-1:0] prod_r;
            reg signed [OUT_W-1:0] acc_r;
            always @(posedge clk) begin
                prod_r <= prod;
                acc_r  <= {{A_W{acc[ACC_W-1]}}, acc};
            end

            wire signed [B_W-1:0]   b   = $signed(b_r[ch*B_W +: B_W]);
            wire signed [OUT_W-1:0] sum = (prod_r >>> s1_r) + b;

            assign o_data[ch*OUT_W +: OUT_W] = bn_en_r ? sum : acc_r;
        end
    endgenerate
endmodule

