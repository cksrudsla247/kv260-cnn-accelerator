`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: input_buffer   (ping-pong, 8 banks x 32-bit, depth 32)
//
//   Two physical bank-sets (buf0, buf1). One side is being loaded by the DMA
//   while the other is read by the compute path. `sel` picks which set is the
//   COMPUTE side (read) : sel=0 -> buf0 compute / buf1 load
//                          sel=1 -> buf1 compute / buf0 load
//   All ports on the load side use ld_* ; compute side uses cp_* .
//
//   Each bank : blk_mem_gen_0  (SP, width 32, depth 32, output reg OFF -> lat 1)
//   NUM_BANKS banks share one address (a 256-bit row = one img tile slice).
//////////////////////////////////////////////////////////////////////////////////
module input_buffer #(
    parameter NUM_BANKS = 8,
    parameter A_BIT     = 5
)(
    input                        clk,
    input                        ld_sel,        // buffer that load writes to
    input                        cp_sel,        // buffer that compute reads from
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
            blk_mem_gen_0 u_bram (
                .clka (clk), .ena(1'b1),
                .wea  (wr0),
                .addra(wr0 ? ld_addr : cp_addr),   // write->ld_addr, else read cp_addr
                .dina (ld_din),
                .douta(dout0[i*32 +: 32])
            );
        end
    endgenerate
    generate
        for (i = 0; i < NUM_BANKS; i = i+1) begin : buf1_bank
            wire wr1 = (ld_sel == 1'b1) & ld_we[i];
            blk_mem_gen_0 u_bram (
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