`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/01 16:31:46
// Design Name: 
// Module Name: bank_unpack
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


module bank_unpack#(
    parameter MEMORY_WIDTH = 32,
    parameter DATA_WIDTH = 8,
    parameter ROW_SIZE = 32,
    localparam NUM_BANKS = ROW_SIZE*DATA_WIDTH/MEMORY_WIDTH
)(
    input [(MEMORY_WIDTH*NUM_BANKS)-1:0] bank_dout,
    output signed [(DATA_WIDTH*ROW_SIZE)-1:0] ch_out
    );
    
    localparam CH_PER_BANK = MEMORY_WIDTH/DATA_WIDTH;

    genvar i, j;
    generate
        for (i = 0; i < NUM_BANKS; i = i+1) begin : bank
            for (j = 0; j < CH_PER_BANK; j = j+1) begin : ch
                assign ch_out[(i*CH_PER_BANK + j)*DATA_WIDTH +: DATA_WIDTH] = bank_dout[i*MEMORY_WIDTH + j*DATA_WIDTH +: DATA_WIDTH];
            end
        end
    endgenerate
    
endmodule
