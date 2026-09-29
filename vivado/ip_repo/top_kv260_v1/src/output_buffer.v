`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: output_buffer   (ping-pong, 8 banks x 32-bit, depth 64)
//
//   Drain writes requant/logit rows into the COMPUTE-side set; the LOAD side is
//   drained out by s2mm to DRAM. Roles swap on `sel`, same convention as the
//   input/weight buffers but with the data directions reversed:
//     - fill side  (from requant) uses fl_* (write)
//     - drain side (to s2mm)       uses dr_* (read)
//   sel=0 -> buf0 fill / buf1 drain ; sel=1 -> swap.
//   depth 64 covers the wide_out (L5 logit) worst case of 2 entries/img * B32.
//   Each bank : blk_mem_gen_2 (SP, width 32, depth 64, output reg OFF).
//////////////////////////////////////////////////////////////////////////////////
module output_buffer #(
    parameter NUM_BANKS = 8,
    parameter A_BIT     = 6
)(
    input                         clk,
    input                         fl_sel,       // which buffer fill writes to
    input                         dr_sel,       // which buffer drain reads from
    input                         fl_we,
    input      [A_BIT-1:0]        fl_addr,
    input      [NUM_BANKS*32-1:0] fl_din,
    input      [A_BIT-1:0]        dr_addr,
    output     [NUM_BANKS*32-1:0] dr_dout
);
    wire [NUM_BANKS*32-1:0] dout0, dout1;
    genvar i;
    generate
        for (i = 0; i < NUM_BANKS; i = i+1) begin : buf0_bank
            blk_mem_gen_2 u_bram (
                .clka (clk), .ena(1'b1),
                .wea  ((fl_sel==1'b0) ? fl_we   : 1'b0),
                .addra(((fl_sel==1'b0) && fl_we) ? fl_addr : dr_addr),
                .dina (fl_din[i*32 +: 32]),
                .douta(dout0[i*32 +: 32])
            );
        end
    endgenerate
    generate
        for (i = 0; i < NUM_BANKS; i = i+1) begin : buf1_bank
            blk_mem_gen_2 u_bram (
                .clka (clk), .ena(1'b1),
                .wea  ((fl_sel==1'b1) ? fl_we   : 1'b0),
                .addra(((fl_sel==1'b1) && fl_we) ? fl_addr : dr_addr),
                .dina (fl_din[i*32 +: 32]),
                .douta(dout1[i*32 +: 32])
            );
        end
    endgenerate
    assign dr_dout = (dr_sel==1'b0) ? dout0 : dout1;
endmodule