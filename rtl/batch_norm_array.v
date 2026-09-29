`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/20 16:42:52
// Design Name: 
// Module Name: batch_norm_array
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


module batch_norm_array#(
    parameter CH = 32, 
    parameter ACC_W = 39, 
    parameter A_W = 4, 
    parameter B_W = 20, 
    parameter OUT_W = 43, 
    parameter S1 = 2
)(
    input  [CH*ACC_W-1:0] i_acc,
    input  [CH*A_W-1:0]   i_a,
    input  [CH*B_W-1:0]   i_b,
    input                 i_bn_en,
    output [CH*OUT_W-1:0] o_data
    );
    genvar i;
        generate 
            for (i=0; i<CH; i=i+1) begin : BN
                batch_norm #(ACC_W, A_W, B_W, OUT_W, S1) u_bn (
                    .i_acc   (i_acc[i*ACC_W +: ACC_W]),
                    .i_a     (i_a  [i*A_W   +: A_W  ]),
                    .i_b     (i_b  [i*B_W   +: B_W  ]),
                    .i_bn_en (i_bn_en),
                    .o_data  (o_data[i*OUT_W +: OUT_W])
            );
        end 
    endgenerate
endmodule
