`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/30 15:19:39
// Design Name: 
// Module Name: pe_adder_tree
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


module pe_adder_tree#(
    parameter DATA_WIDTH = 8,
    parameter ROW_SIZE   = 32,
    localparam OUTPUT_WIDTH = $clog2(ROW_SIZE) + (DATA_WIDTH*2)
)(
    input                              clk, rst, we_w,
    input [$clog2(ROW_SIZE)-1:0]       row_addr,
    input [ROW_SIZE*DATA_WIDTH-1:0]    i_data,        // packed
    input signed [DATA_WIDTH-1:0]      i_weight,      // scalar, stays as is
    output [OUTPUT_WIDTH-1:0]          o_result
    );

    wire [ROW_SIZE*DATA_WIDTH*2-1:0] pe_col_output;   // packed

    pe_col #(
        .DATA_WIDTH (DATA_WIDTH),
        .ROW_SIZE   (ROW_SIZE)
    ) pe_col_inst (
        .clk       (clk),
        .rst       (rst),
        .we_w      (we_w),
        .row_addr  (row_addr),
        .i_data    (i_data),
        .i_weight  (i_weight),
        .o_product (pe_col_output)
    );

    reg [ROW_SIZE*DATA_WIDTH*2-1:0] pe_col_output_r;
    always @(posedge clk) pe_col_output_r <= pe_col_output;
    
    wire [OUTPUT_WIDTH-1:0] sum_result;
    adder_tree #(
        .DATA_WIDTH (DATA_WIDTH*2),
        .PE_SIZE    (ROW_SIZE)
    ) adder_col (
        .i_pe_out (pe_col_output_r),
        .o_result (sum_result)
    );
    
    reg [OUTPUT_WIDTH-1:0] o_result_r;
    always @(posedge clk) o_result_r <= sum_result;
    assign o_result = o_result_r;

endmodule
