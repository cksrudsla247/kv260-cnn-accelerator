`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : accumulator     (COL_SIZE lanes x ACC_DEPTH slots, BRAM backed)
//
//   The MLP version was COL_SIZE registers because only ONE partial-sum set was
//   alive at a time. In the CNN the pixel loop is innermost, so P partial-sum
//   sets are alive at once and the register file becomes a memory.
//
//   One slot = one output pixel. All COL_SIZE lanes share the address and the
//   write strobe: a slot holds every output channel of that pixel, and they are
//   always updated together. Only the data differs per lane, so this is
//   COL_SIZE independent single-port BRAMs driven in lockstep.
//
// NO FSM, NO FLIP-FLOPS
//   A single-port BRAM cannot read and write in the same cycle, so a
//   read-modify-write takes two. This module does NOT sequence that itself.
//   The controller owns the sequence and names the phase on acc_ph, which keeps
//   the whole loop visible in one state machine instead of two.
//
//   The only state here lives inside the blk_mem_acc instances. Everything
//   outside them is combinational, so rst is unused and carried only to keep
//   the port list uniform with the rest of the design.
//
// PROTOCOL
//
//   acc_first = 1                       1 cycle
//     acc_en=1, acc_ph=0, acc_first=1   -> slot written with pe
//
//   acc_first = 0                       2 cycles
//     acc_en=1, acc_ph=0, acc_first=0   -> read the slot
//     acc_en=1, acc_ph=1                -> write back old + pe
//
//   acc_addr and i_pe_result must HOLD across both cycles of a RMW; acc_first
//   is ignored while acc_ph is high. Holding costs nothing: the PE array is
//   combinational, so holding ibuf_raddr holds pe_result too.
//
//   The read issued at the end of the acc_ph=0 cycle lands on douta during the
//   acc_ph=1 cycle (read latency 1, output register OFF), which is exactly when
//   the adder needs it. The BRAM is WRITE_FIRST, but that only changes douta in
//   the cycle AFTER the write, which nothing reads.
//
//   Conv1_1 has a single weight tile, so acc_first is high for every pixel and
//   the accumulator runs at one pixel per cycle. From Conv1_2 on the (r,s)
//   tiles accumulate and it is one pixel per two cycles - still far inside the
//   weight DMA, so this costs nothing.
//
// DRAIN
//   dr_en / dr_addr read a slot without modifying it. o_accum_result is the
//   raw BRAM output, so it is valid ONE cycle after dr_en, exactly like every
//   other BRAM in this design. Never assert dr_en and acc_en together - they
//   share the single port, and acc_en wins the address mux.
//
// WIDTH
//   ACCUM_WIDTH = PE_OUT_WIDTH + 5 leaves headroom for up to 32 accumulated
//   tiles. Conv2_2 is the worst case at cg 2 x (r,s) 9 = 18.
//////////////////////////////////////////////////////////////////////////////////
module accumulator #(
    parameter COL_SIZE     = 32,   // lanes = PE columns = output channels
    parameter PE_OUT_WIDTH = 19,   // adder tree result width
    parameter ACCUM_WIDTH  = 24,   // partial sum width  (= BRAM data width)
    parameter ACC_A_BIT    = 10    // 1024 slots
)(
    input                                  clk,
    input                                  rst,          // unused : no flip-flops

    //---- accumulate side ---------------------------------------------------
    input                                  acc_en,       // this cycle is ours
    input                                  acc_ph,       // 0 = read/load, 1 = write back
    input                                  acc_first,    // ph0 only : 1 = load, 0 = read
    input      [ACC_A_BIT-1:0]             acc_addr,     // slot = output pixel
    input      [COL_SIZE*PE_OUT_WIDTH-1:0] i_pe_result,  // held across both phases

    //---- drain side --------------------------------------------------------
    input                                  dr_en,        // read a slot
    input      [ACC_A_BIT-1:0]             dr_addr,
    output     [COL_SIZE*ACCUM_WIDTH-1:0]  o_accum_result   // valid 1 cycle later
);
    //------------------------------------------------------------------
    // shared BRAM control. All lanes see the same address and strobe.
    //   acc_ph=0, acc_first=1 : write pe straight in
    //   acc_ph=0, acc_first=0 : read  (we = 0)
    //   acc_ph=1              : write back douta + pe
    //   otherwise             : serve the drain read
    //------------------------------------------------------------------
    wire                  mem_we   = acc_en && (acc_ph || acc_first);
    wire                  mem_en   = acc_en || dr_en;
    wire [ACC_A_BIT-1:0]  mem_addr = acc_en ? acc_addr : dr_addr;

    wire [COL_SIZE*ACCUM_WIDTH-1:0] mem_dout;

    genvar g;
    generate
        for (g = 0; g < COL_SIZE; g = g+1) begin : g_lane
            // sign-extend this lane's adder-tree result to the accumulator width
            wire signed [ACCUM_WIDTH-1:0] pe_ext =
                $signed(i_pe_result[g*PE_OUT_WIDTH +: PE_OUT_WIDTH]);
            // what the acc_ph=0 read brought back, valid during acc_ph=1
            wire signed [ACCUM_WIDTH-1:0] old =
                $signed(mem_dout[g*ACCUM_WIDTH +: ACCUM_WIDTH]);

            wire [ACCUM_WIDTH-1:0] din = acc_ph ? (old + pe_ext) : pe_ext;

            blk_mem_acc u_mem (
                .clka (clk),
                .ena  (mem_en),
                .wea  (mem_we),
                .addra(mem_addr),
                .dina (din),
                .douta(mem_dout[g*ACCUM_WIDTH +: ACCUM_WIDTH])
            );
        end
    endgenerate

    assign o_accum_result = mem_dout;

endmodule
