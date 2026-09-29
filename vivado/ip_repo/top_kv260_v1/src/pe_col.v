`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/30 14:48:42
// Design Name: 
// Module Name: pe_col
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


module pe_col#(
    parameter DATA_WIDTH = 8,
    parameter ROW_SIZE   = 32
)(
    input                            clk, rst, we_w,
    input [$clog2(ROW_SIZE)-1:0]     row_addr,
    input [ROW_SIZE*DATA_WIDTH-1:0]  i_data,        // packed
    input signed [DATA_WIDTH-1:0]    i_weight,
    output [ROW_SIZE*DATA_WIDTH*2-1:0] o_product    // packed
    );

    genvar i;
    generate
        for (i = 0; i < ROW_SIZE; i = i+1) begin : col_gen
            wire pe_we = we_w && (row_addr == i);

            PE #(.DATA_WIDTH(DATA_WIDTH)) pe_col_inst (
                .clk       (clk),
                .rst       (rst),
                .we_w      (pe_we),
                .i_data    ($signed(i_data[i*DATA_WIDTH +: DATA_WIDTH])),
                .i_weight  (i_weight),
                .o_product (o_product[i*DATA_WIDTH*2 +: DATA_WIDTH*2])
            );
        end
    endgenerate

endmodule