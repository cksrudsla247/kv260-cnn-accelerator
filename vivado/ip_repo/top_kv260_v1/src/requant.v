`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/13 02:51:59
// Design Name: 
// Module Name: requant
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


module requant#(
    parameter CH    = 32,
    parameter IN_W  = 30,
    parameter M_W   = 4,
    parameter OUT_W = 8,
    parameter PRD_W = IN_W + M_W + 1
)(
    input  wire                clk,
    input  wire [CH*IN_W-1:0]  i_data,
    input  wire [M_W-1:0]      i_m2,
    input  wire [3:0]          i_shift,
    output reg  [CH*OUT_W-1:0] o_data
);
    wire signed [M_W:0] m2_s = $signed({1'b0, i_m2});

    reg  [3:0] shift_r;
    reg signed [PRD_W-1:0] prod_r [0:CH-1];
    
    always @(posedge clk) begin
        shift_r <= i_shift;
    end
    
    genvar ch;
    generate
        for (ch = 0; ch < CH; ch = ch + 1) begin : g_rq
            wire signed [IN_W-1:0]  din = $signed(i_data[ch*IN_W +: IN_W]);
            always @(posedge clk) begin
                prod_r[ch] <= din * m2_s;
            end 

            wire signed [PRD_W-1:0] shf = prod_r[ch] >>> shift_r;
            wire signed [OUT_W-1:0] sat =
                (shf >  9'sd127) ? 8'sd127 :
                (shf < -9'sd128) ? -8'sd128 :
                shf[OUT_W-1:0];

            always @(posedge clk) o_data[ch*OUT_W +: OUT_W] <= sat;
        end
    endgenerate
endmodule
