`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/02 10:33:52
// Design Name: 
// Module Name: tb_memory_test
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


module tb_memory_test();

    reg clk = 0;
    always #5 clk = ~clk;
    
    reg in_we;
    reg [0:0] in_addr;
    reg [31:0] in_din [0:7];
    wire [31:0] in_dout [0:7];
    wire [7:0] row_input [0:31];
    
    multi_bank_input u_input_mem (
        .clk(clk), .we(in_we),
        .input_addr(in_addr),
        .input_din(in_din),
        .input_dout(in_dout)
    );

    bank_unpack u_unpack (  
        .bank_dout(in_dout),
        .ch_out(row_input)
    );
    
    reg w_we;
    reg [4:0] w_addr;
    reg [7:0] w_din [0:31];
    wire [7:0] w_dout [0:31];
    
    multi_bank_weight u_weight_mem (
        .clk(clk), .we(w_we),
        .weight_addr(w_addr),
        .weight_din(w_din),
        .weight_dout(w_dout)
    );
    
integer i;
integer ch0, ch1, ch2, ch3;
integer w_row; 


    initial begin
        in_we = 0; in_addr = 0;
        @(posedge clk);
        for (i = 0; i < 8; i = i+1) begin
            ch0 = 4*i + 0;
            ch1 = 4*i + 1;
            ch2 = 4*i + 2;
            ch3 = 4*i + 3;
            in_din[i] = {ch3[7:0], ch2[7:0], ch1[7:0], ch0[7:0]};
        end
        
        in_we = 1;
        @(posedge clk);
        in_we = 0;
        
        in_addr = 0;
        @(posedge clk);
        #1;
        for (i = 0; i < 32; i = i+1)
            if (row_input[i] !== i)
                $display("INPUT FAIL ch%0d: expected %0d got %0d", i, i, row_input[i]);
        $display("Input memory check done");
        
        w_we = 0;
        @(posedge clk);
        for (w_row = 0; w_row < 32; w_row = w_row + 1) begin
            w_addr = w_row[4:0];     
            for (i = 0; i < 32; i = i+1)
                w_din[i] = i + w_row;
            w_we = 1;
            @(posedge clk);
        end
        w_we = 0; 
        
        w_addr = 5;
        @(posedge clk);
        #1;
        for (i = 0; i < 32; i = i+1)
            if (w_dout[i] !== (i+5))
                $display("WEIGHT FAIL col%0d: expected %0d got %0d", i, i+5, w_dout[i]);
        $display("Weight memory check done");

        $finish;
    end

endmodule
