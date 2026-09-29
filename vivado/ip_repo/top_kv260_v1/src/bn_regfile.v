`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/21 11:29:20
// Design Name: 
// Module Name: bn_regfile
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


module bn_regfile#(
    parameter NUM_CH  = 384,
    parameter CH_WIN  = 32,
    parameter A_W     = 4,
    parameter B_W     = 20,
    parameter A_WORDS = 48          // NUM_CH*A_W/32
)(
    input                       clk,
    input                       we,
    input      [8:0]            waddr,      // 0..431
    input      [31:0]           wdata,

    input      [8:0]            bn_base,    // bn_grp * 32
    output     [CH_WIN*A_W-1:0] o_a,        // 128 bit
    output     [CH_WIN*B_W-1:0] o_b         // 640 bit
    );
localparam GRP = 12;

    reg [A_W-1:0] a_mem [0:31][0:GRP-1];      // [lane][group]
    reg [B_W-1:0] b_mem [0:31][0:GRP-1];

    // a: one word carries 8 channels starting at waddr*8
    wire [3:0] a_grp  = waddr[8:2];           // (waddr*8)/32
    wire [4:0] a_lane = {waddr[1:0], 3'b000};

    wire [8:0] b_idx  = waddr - A_WORDS;
    wire [3:0] b_grp  = b_idx[8:5];
    wire [4:0] b_lane = b_idx[4:0];

    integer k;
    always @(posedge clk) begin
        if (we) begin
            if (waddr < A_WORDS)
                for (k = 0; k < 8; k = k + 1)
                    a_mem[a_lane + k[4:0]][a_grp] <= wdata[k*A_W +: A_W];
            else
                b_mem[b_lane][b_grp] <= wdata[B_W-1:0];
        end
    end

    wire [3:0] grp = bn_base[8:5];            // bn_grp

    genvar i;
    generate
        for (i = 0; i < CH_WIN; i = i + 1) begin : g_rd
            assign o_a[i*A_W +: A_W] = a_mem[i][grp];
            assign o_b[i*B_W +: B_W] = b_mem[i][grp];
        end
    endgenerate
endmodule