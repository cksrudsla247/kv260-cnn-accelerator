`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: weight_buffer   (ping-pong, 8 banks x 32-bit, depth 32)
//
//   One weight tile = 32in x 32out INT8 = 1024 byte = 256 word.
//   256 word / 8 banks = 32 rows -> depth 32.
//   sel=0 -> buf0 compute / buf1 load ;  sel=1 -> swap.
//   Each bank : blk_mem_gen_1 (SP, width 32, depth 32, output reg OFF).
//////////////////////////////////////////////////////////////////////////////////
module weight_buffer #(
    parameter NUM_BANKS = 8,
    parameter A_BIT     = 5
)(
    input                        clk,
    input                        ld_sel,
    input                        cp_sel,
    input      [NUM_BANKS-1:0]   ld_we,
    input      [A_BIT-1:0]       ld_addr,
    input      [31:0]            ld_din,
    input      [A_BIT-1:0]       cp_addr,
    output     [NUM_BANKS*32-1:0] cp_dout
);
    wire [NUM_BANKS*32-1:0] dout0, dout1;
    genvar i;
    generate
        for (i = 0; i < NUM_BANKS; i = i+1) begin : buf0_bank
            wire wr0 = (ld_sel == 1'b0) & ld_we[i];
            blk_mem_gen_1 u_bram (
                .clka (clk), .ena(1'b1),
                .wea  (wr0),
                .addra(wr0 ? ld_addr : cp_addr),
                .dina (ld_din),
                .douta(dout0[i*32 +: 32])
            );
        end
    endgenerate
    generate
        for (i = 0; i < NUM_BANKS; i = i+1) begin : buf1_bank
            wire wr1 = (ld_sel == 1'b1) & ld_we[i];
            blk_mem_gen_1 u_bram (
                .clka (clk), .ena(1'b1),
                .wea  (wr1),
                .addra(wr1 ? ld_addr : cp_addr),
                .dina (ld_din),
                .douta(dout1[i*32 +: 32])
            );
        end
    endgenerate
    assign cp_dout = (cp_sel == 1'b0) ? dout0 : dout1;
endmodule