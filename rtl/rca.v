    `timescale 1ns / 1ps
    //////////////////////////////////////////////////////////////////////////////////
    // Company: 
    // Engineer: 
    // 
    // Create Date: 2026/06/29 13:58:56
    // Design Name: 
    // Module Name: rca
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
    
    
    module rca#(
        parameter DATA_WIDTH = 16
    )(
        input [DATA_WIDTH-1:0] i_a,
        input [DATA_WIDTH-1:0] i_b,
        output [DATA_WIDTH-1:0] o_sum,
        output o_cout
        );
        
        wire [DATA_WIDTH-1:0] carry;
        
        ha_adder ha (.i_a(i_a[0]), .i_b(i_b[0]), .o_sum(o_sum[0]), .o_cout(carry[0]));
        
        genvar i;
        
        generate
            for(i = 1; i < DATA_WIDTH; i = i+1 ) begin : rca_adder
                full_adder full (.i_a(i_a[i]), .i_b(i_b[i]), .i_cin(carry[i-1]), .o_sum(o_sum[i]), .o_cout(carry[i]));
            end
        endgenerate
        
        assign o_cout = carry[DATA_WIDTH-1];
        
    endmodule
