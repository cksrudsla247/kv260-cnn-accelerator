`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/30 13:55:55
// Design Name: 
// Module Name: tb_pe_array
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


module tb_pe_array();
    reg clk;
    reg rst;
    reg we_w;
    reg signed [7:0] data [0:31];
    reg signed [7:0] weight [0:31][0:31];
    wire signed [20:0] o_result [0:31];
    
    integer i,j;
    
    pe_array_hier #(.DATA_WIDTH(8), .SIZE(32)) pe_array_inst (.clk(clk), .rst(rst), .we_w(we_w), .i_data(data), .i_weight(weight), .o_result(o_result));

    always #5 clk = ~clk;
    
    initial begin
        clk = 0;
        rst = 1;
        we_w = 0;
        #1;
        rst = 0;
        #1;
  
        for(i = 0; i < 32; i = i+1)
            for(j = 0; j < 32; j = j+1)
                weight[i][j] = 8'sd1;
                
        we_w = 1;  
        @(posedge clk); 
        #1;
        we_w = 0;

       
        for(i = 0; i < 32; i = i+1)
            data[i] = 8'sd2;

        #10; 
 
        for(i = 0; i < 32; i = i+1)
            for(j = 0; j < 32; j = j+1)
                weight[i][j] = 8'sd2;

        we_w = 1;
        @(posedge clk);
        #1;
        we_w = 0;

        for(i = 0; i < 32; i = i+1)
            data[i] = -8'sd1;

        #10;

        $finish;
    end
    
endmodule
