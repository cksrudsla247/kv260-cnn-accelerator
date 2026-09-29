`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/30 11:20:33
// Design Name: 
// Module Name: pe_array
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


module pe_array#(
    parameter DATA_WIDTH = 8,
    parameter SIZE = 32,
    localparam OUTPUT_WIDTH = $clog2(SIZE) + (DATA_WIDTH*2)
)(
    input clk, rst,
    input we_w,
    input signed [DATA_WIDTH-1:0] i_data [0:SIZE-1],
    input signed [DATA_WIDTH-1:0] i_weight [0:SIZE-1][0:SIZE-1],
    output signed [OUTPUT_WIDTH-1:0] o_result [0:SIZE-1]
    );
    
    wire signed [(DATA_WIDTH*2)-1:0] pe_out [0:SIZE-1][0:SIZE-1];
    
    genvar i,j,k;
    
    generate
        for(i = 0; i < SIZE; i = i+1) begin : pe_array_row
            for(j = 0; j < SIZE; j = j+1) begin : pe_array_col
                PE #(.DATA_WIDTH(DATA_WIDTH)) pe_inst (.clk(clk), .rst(rst), .we_w(we_w), .i_data(i_data[i]), .i_weight(i_weight[j][i]), .o_product(pe_out[j][i]));
            end
        end
        
        for(k = 0; k < SIZE; k = k+1) begin : pe_array_adder
            adder_tree #(.DATA_WIDTH(DATA_WIDTH*2), .PE_SIZE(SIZE)) adder_inst (.i_pe_out(pe_out[k]), .o_result(o_result[k]));
        end
    endgenerate
       
endmodule
