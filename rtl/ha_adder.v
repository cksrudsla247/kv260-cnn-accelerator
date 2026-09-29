`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/29 13:33:35
// Design Name: 
// Module Name: ha_adder
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


module ha_adder(
    input i_a,
    input i_b,
    output o_sum,
    output o_cout
    );
    
    assign o_sum = i_a ^ i_b;
    assign o_cout = i_a& i_b;
    
endmodule
