`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/30 16:02:35
// Design Name: 
// Module Name: pe_array_hier
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


module pe_array_hier#(
    parameter DATA_WIDTH = 8,
    parameter ROW_SIZE = 8,
    parameter COL_SIZE = 32,
    // The adder tree sums ROW_SIZE products, so the growth is clog2(ROW_SIZE),
    // not clog2(COL_SIZE). The two were the same number at 32x32 and this read
    // as correct; at 8x32 it made o_result 21 bits per lane against the adder
    // tree's real 19, misaligning every lane. Same trap as i_weight above.
    localparam OUTPUT_WIDTH = $clog2(ROW_SIZE) + (DATA_WIDTH*2)
)(
    input clk, rst,
    input we_w,
    input [$clog2(ROW_SIZE)-1:0] row_addr,
    input  [ROW_SIZE*DATA_WIDTH-1:0]     i_data,
    input  [COL_SIZE*DATA_WIDTH-1:0]     i_weight,
    output [COL_SIZE*OUTPUT_WIDTH-1:0]   o_result
    );
       
    genvar i;
    generate
        for(i = 0; i < COL_SIZE; i = i+1) begin : row_gen
            pe_adder_tree #(
                .DATA_WIDTH(DATA_WIDTH), 
                .ROW_SIZE(ROW_SIZE)
            ) pe_adder (
                .clk(clk), 
                .rst(rst), 
                .we_w(we_w), 
                .row_addr(row_addr), 
                .i_data   (i_data),                                   
                .i_weight (i_weight[i*DATA_WIDTH +: DATA_WIDTH]),     
                .o_result (o_result[i*OUTPUT_WIDTH +: OUTPUT_WIDTH])
            );
        end
    endgenerate
    
endmodule
