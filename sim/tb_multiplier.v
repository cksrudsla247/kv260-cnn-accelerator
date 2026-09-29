`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/29 17:48:36
// Design Name: 
// Module Name: tb_multiplier
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


module tb_multiplier();

    reg [7:0] i_a;
    reg [7:0] i_b;
    wire [15:0] o_product;
    
    multiplier dut (
        .i_a(i_a), .i_b(i_b),
        .o_product(o_product)
    );
    
    initial begin
        i_a = 16'd749;
        i_b = 16'd920;
        #10
        $display ("result: %d", o_product);
        
        i_a = -16'd19;
        i_b = 16'd1020;
        #10
        $display ("result: %d", o_product);
        
        i_a = -16'd381;
        i_b = -16'd321;
        #10
        $display ("result: %d", o_product);
        
    end

endmodule
