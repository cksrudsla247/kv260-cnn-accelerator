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
    
    //wire signed [OUTPUT_WIDTH-1:0] level0 [0:31];
    //wire signed [OUTPUT_WIDTH-1:0] level1 [0:15];
    //wire signed [OUTPUT_WIDTH-1:0] level2 [0:7];
    //wire signed [OUTPUT_WIDTH-1:0] level3 [0:3];
    //wire signed [OUTPUT_WIDTH-1:0] level4 [0:1];
    //wire signed [OUTPUT_WIDTH-1:0] level5;
    
    
    //genvar i;
    //generate
    //    for(i = 0; i < 32; i = i+1) begin : level0_sign_ext
    //            assign level0[i] = $signed(i_pe_out[i*DATA_WIDTH +: DATA_WIDTH]);
    //    end
        
    //    for(i = 0; i < 16; i = i+1) begin : level1_add
    //            rca #(.DATA_WIDTH(OUTPUT_WIDTH)) u_rca0 (.i_a(level0[2*i]), .i_b(level0[(2*i)+1]), .o_sum(level1[i]), .o_cout()); 
    //    end
        
    //    for(i = 0; i < 8; i = i+1) begin : level2_add
    //            rca #(.DATA_WIDTH(OUTPUT_WIDTH)) u_rca1 (.i_a(level1[2*i]), .i_b(level1[(2*i)+1]), .o_sum(level2[i]), .o_cout()); 
    //    end
        
    //    for(i = 0; i < 4; i = i+1) begin : level3_add
    //            rca #(.DATA_WIDTH(OUTPUT_WIDTH)) u_rca2 (.i_a(level2[2*i]), .i_b(level2[(2*i)+1]), .o_sum(level3[i]), .o_cout()); 
    //   end
        
    //  for(i = 0; i < 2; i = i+1) begin : level4_add
    //           rca #(.DATA_WIDTH(OUTPUT_WIDTH)) u_rca3 (.i_a(level3[2*i]), .i_b(level3[(2*i)+1]), .o_sum(level4[i]), .o_cout()); 
    //    end
    //endgenerate 
    
    //rca #(.DATA_WIDTH(OUTPUT_WIDTH)) u_rca4 (.i_a(level4[0]), .i_b(level4[1]), .o_sum(level5), .o_cout()); 
    
    //assign o_result = level5;
    

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
    