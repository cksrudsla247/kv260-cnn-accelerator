`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/29 13:34:17
// Design Name: 
// Module Name: full_adder
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


module full_adder(
    input i_a,
    input i_b,
    input i_cin,
    output o_sum,
    output o_cout
    );
    
    assign o_cout = ((i_a^i_b)&i_cin)|(i_a&i_b);
    assign o_sum = (i_a^i_b)^i_cin;
    
endmodule
