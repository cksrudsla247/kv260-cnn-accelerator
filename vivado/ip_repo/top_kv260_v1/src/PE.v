`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/29 22:39:15
// Design Name: 
// Module Name: PE
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


module PE#(
    parameter DATA_WIDTH = 8
)(
    input clk, rst,
    input we_w,
    input signed [DATA_WIDTH-1:0] i_data,
    input signed [DATA_WIDTH-1:0] i_weight,
    output signed [(DATA_WIDTH*2)-1:0] o_product
    );
    
    reg signed [DATA_WIDTH-1:0] weight_data;
    
    always @(posedge clk) begin
        if(rst) begin
            weight_data <= 0;
        end
        else if (we_w) begin
            weight_data <= i_weight;
        end
    end
    
    multiplier #(.DATA_WIDTH(DATA_WIDTH)) mul(.i_a(i_data), .i_b(weight_data), .o_product(o_product)); 
    
endmodule
