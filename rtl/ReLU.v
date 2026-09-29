`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/14 17:51:27
// Design Name: 
// Module Name: ReLU
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


module ReLU#(
    parameter COL        = 32,
    parameter DATA_WIDTH = 30          // BN output width
)(
    input   [DATA_WIDTH*COL-1:0] i_data,
    input                        i_relu_en,
    output  [DATA_WIDTH*COL-1:0] o_data
);
    genvar c;
    generate
        for (c = 0; c < COL; c = c + 1) begin : g_relu
            wire signed [DATA_WIDTH-1:0] din = $signed(i_data[DATA_WIDTH*c +: DATA_WIDTH]);
            assign o_data[DATA_WIDTH*c +: DATA_WIDTH] = (i_relu_en && din < 0) ? {DATA_WIDTH{1'b0}} : din;
        end
    endgenerate
endmodule