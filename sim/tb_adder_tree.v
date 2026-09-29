`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/30 10:56:16
// Design Name: 
// Module Name: tb_adder_tree
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


module tb_adder_tree();
    reg signed [15:0] i_pe_out [0:31];  
    wire signed [20:0] o_result; 
    
    adder_tree dut (
    .i_pe_out(i_pe_out),
    .o_result(o_result)   
    );
    
    initial begin

    for(integer k=0; k<32; k=k+1)
        i_pe_out[k] = 16'sd1;
    #10;
    $display("all 1: %d (expected 32)", o_result);
    
   
    for(integer k=0; k<32; k=k+1)
        i_pe_out[k] = -16'sd1;
    #10;
    $display("all -1: %d (expected -32)", o_result);
end
endmodule
