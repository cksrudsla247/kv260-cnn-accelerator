`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/29 23:02:08
// Design Name: 
// Module Name: adder_tree
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


module adder_tree#(
    parameter DATA_WIDTH = 16,
    parameter PE_SIZE = 32,
    localparam NUM_LEVELS = $clog2(PE_SIZE),
    localparam OUTPUT_WIDTH = $clog2(PE_SIZE) + DATA_WIDTH
)(
    input [PE_SIZE*DATA_WIDTH-1:0] i_pe_out,
    output [OUTPUT_WIDTH-1:0] o_result
    );
    
    

    // stage s holds PE_SIZE>>s live values, flattened into one 1-D array
    wire signed [OUTPUT_WIDTH-1:0] stage [0:(NUM_LEVELS+1)*PE_SIZE-1];

    genvar i, s;
    generate
        for (i = 0; i < PE_SIZE; i = i+1) begin : g_ext
            assign stage[i] = $signed(i_pe_out[i*DATA_WIDTH +: DATA_WIDTH]);
        end
        for (s = 0; s < NUM_LEVELS; s = s+1) begin : g_level
            for (i = 0; i < (PE_SIZE >> (s+1)); i = i+1) begin : g_add
                assign stage[(s+1)*PE_SIZE + i] =
                       stage[s*PE_SIZE + 2*i] + stage[s*PE_SIZE + 2*i + 1];
            end
        end
    endgenerate

    assign o_result = stage[NUM_LEVELS*PE_SIZE];
endmodule
    