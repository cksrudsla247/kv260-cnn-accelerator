`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/29 13:58:28
// Design Name: 
// Module Name: multiplier
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


module multiplier#(
    parameter DATA_WIDTH = 8
)(
    input signed [DATA_WIDTH-1:0] i_a,
    input signed [DATA_WIDTH-1:0] i_b,
    output signed  [(DATA_WIDTH*2)-1:0] o_product
    );
    
    wire [DATA_WIDTH-1:0] pp [0:DATA_WIDTH-1];
    wire [(DATA_WIDTH*2)-1:0] partial_sum [0:DATA_WIDTH-1];
    genvar i,j;
    
    generate
        for(i = 0; i < DATA_WIDTH; i = i+1) begin : pp_row
            for(j = 0; j < DATA_WIDTH; j = j+1) begin : pp_col
                if((i==DATA_WIDTH-1) ^ (j == DATA_WIDTH-1)) begin
                    assign pp[i][j] = ~(i_a[j] & i_b[i]);
                end
                else begin
                   assign pp[i][j] = i_a[j] & i_b[i];
                end
            end
        end
    endgenerate  
    
    assign partial_sum[0] = pp[0];
    
    generate
        for(i = 1; i < DATA_WIDTH; i = i+1) begin : sum_tree
            assign partial_sum[i] = partial_sum[i-1] + (pp[i] << i);
        end
    endgenerate
    
    assign o_product = partial_sum[DATA_WIDTH-1] + (1 << DATA_WIDTH) + (1 << (2*DATA_WIDTH-1));
    
    
endmodule
