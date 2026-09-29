`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/29 16:20:02
// Design Name: 
// Module Name: tb_cla_32
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


module tb_cla_32();
    reg [31:0] i_a;
    reg [31:0] i_b;
    wire [31:0] o_sum;
    wire o_cout;
    
    cla_32 dut (
        .i_a(i_a), .i_b(i_b), .i_cin(1'b0),
        .o_sum(o_sum), .o_cout(o_cout)
    );
    
    initial begin
        i_a = 32'd192749;
        i_b = 32'd485920;
        #10
        $display ("result: %d", o_sum);
        
    end
endmodule
