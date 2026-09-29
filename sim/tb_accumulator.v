`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench : tb_accumulator
//
//   Drives the accumulator directly, with no controller, so a mismatch can only
//   come from the accumulator itself. The DUT has no FSM, so this testbench now
//   plays the part the controller will play: it drives acc_ph by hand and holds
//   acc_addr / pe across both cycles of a read-modify-write.
//
//     1  acc_first writes a slot outright and touches nothing else
//     2  acc_first = 0 accumulates, nine times, like a 3x3 tile sweep
//     3  slots stay independent when several are interleaved
//     4  earlier slots survive later traffic
//     5  back-to-back RMW with no idle cycle between them
//     6  a high slot near the top of the depth
//
//   A behavioural reference array mirrors every write, and read_check compares
//   all COL_SIZE lanes of a slot against it.
//
//   Timing note: the BRAM has read latency 1 and no output register, so the
//   value read during the acc_ph=0 cycle is on douta during the acc_ph=1 cycle,
//   and o_accum_result is valid in the cycle AFTER dr_en was sampled. Stimulus
//   is driven on negedge to keep away from that edge.
//////////////////////////////////////////////////////////////////////////////////
module tb_accumulator;

    localparam COL_SIZE     = 32;
    localparam PE_OUT_WIDTH = 19;
    localparam ACCUM_WIDTH  = 24;
    localparam ACC_A_BIT    = 10;

    reg                              clk = 1'b0;
    reg                              rst;
    reg                              acc_en, acc_ph, acc_first;
    reg  [ACC_A_BIT-1:0]             acc_addr;
    reg  [COL_SIZE*PE_OUT_WIDTH-1:0] pe;
    reg                              dr_en;
    reg  [ACC_A_BIT-1:0]             dr_addr;
    wire [COL_SIZE*ACCUM_WIDTH-1:0]  acc_out;

    integer errors = 0;
    integer checks = 0;
    integer k;

    // behavioural mirror of what the memory should hold
    reg signed [ACCUM_WIDTH-1:0] ref_mem [0:COL_SIZE-1][0:(1<<ACC_A_BIT)-1];

    always #5 clk = ~clk;

    accumulator #(
        .COL_SIZE(COL_SIZE), .PE_OUT_WIDTH(PE_OUT_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH), .ACC_A_BIT(ACC_A_BIT)
    ) dut (
        .clk(clk), .rst(rst),
        .acc_en(acc_en), .acc_ph(acc_ph), .acc_first(acc_first),
        .acc_addr(acc_addr), .i_pe_result(pe),
        .dr_en(dr_en), .dr_addr(dr_addr),
        .o_accum_result(acc_out)
    );

    //------------------------------------------------------------------
    // build one i_pe_result word : lane g gets (base + g), sign kept
    //------------------------------------------------------------------
    task make_pe(input integer base);
        integer g;
        reg signed [PE_OUT_WIDTH-1:0] v;
        begin
            for (g = 0; g < COL_SIZE; g = g+1) begin
                v = base + g;
                pe[g*PE_OUT_WIDTH +: PE_OUT_WIDTH] = v;
            end
        end
    endtask

    //------------------------------------------------------------------
    // update the reference the same way the hardware should
    //------------------------------------------------------------------
    task ref_update(input [ACC_A_BIT-1:0] a, input first, input integer base);
        integer g;
        reg signed [PE_OUT_WIDTH-1:0] v;
        begin
            for (g = 0; g < COL_SIZE; g = g+1) begin
                v = base + g;
                if (first) ref_mem[g][a] = v;
                else       ref_mem[g][a] = ref_mem[g][a] + v;
            end
        end
    endtask

    //------------------------------------------------------------------
    // acc_first = 1 : one cycle, slot written outright
    //------------------------------------------------------------------
    task load(input [ACC_A_BIT-1:0] a, input integer base);
        begin
            @(negedge clk);
            make_pe(base);
            acc_addr  = a;
            acc_first = 1'b1;
            acc_ph    = 1'b0;
            acc_en    = 1'b1;
            @(negedge clk);                  // the write took the posedge above
            acc_en    = 1'b0;
            acc_first = 1'b0;
            ref_update(a, 1'b1, base);
        end
    endtask

    //------------------------------------------------------------------
    // acc_first = 0 : two cycles, read then write back.
    // acc_addr and pe are set once and simply not touched, which is what the
    // controller does by holding ibuf_raddr.
    //------------------------------------------------------------------
    task accum(input [ACC_A_BIT-1:0] a, input integer base);
        begin
            @(negedge clk);
            make_pe(base);
            acc_addr  = a;
            acc_first = 1'b0;
            acc_ph    = 1'b0;                // phase 0 : read the slot
            acc_en    = 1'b1;
            @(negedge clk);
            acc_ph    = 1'b1;                // phase 1 : write back old + pe
            @(negedge clk);
            acc_en    = 1'b0;
            acc_ph    = 1'b0;
            ref_update(a, 1'b0, base);
        end
    endtask

    //------------------------------------------------------------------
    // read a slot back and compare all COL_SIZE lanes
    //------------------------------------------------------------------
    task read_check(input [ACC_A_BIT-1:0] a, input [127:0] tag);
        integer g;
        reg signed [ACCUM_WIDTH-1:0] got, exp;
        begin
            @(negedge clk);
            dr_addr = a;
            dr_en   = 1'b1;
            @(posedge clk);          // BRAM samples the address here
            @(negedge clk);
            dr_en   = 1'b0;          // douta is valid from now on

            for (g = 0; g < COL_SIZE; g = g+1) begin
                got = $signed(acc_out[g*ACCUM_WIDTH +: ACCUM_WIDTH]);
                exp = ref_mem[g][a];
                checks = checks + 1;
                if (got !== exp) begin
                    errors = errors + 1;
                    $display("  FAIL %0s slot=%0d lane=%0d  exp=%0d got=%0d",
                             tag, a, g, exp, got);
                end
            end
        end
    endtask

    //------------------------------------------------------------------
    initial begin
        rst = 1'b1;
        acc_en = 0; acc_ph = 0; acc_first = 0; acc_addr = 0; pe = 0;
        dr_en = 0; dr_addr = 0;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        $display("================================================");
        $display("  1. acc_first : plain write");
        $display("================================================");
        load(10'd0, 100);
        load(10'd1, 200);
        load(10'd2, -50);
        read_check(10'd0, "write0");
        read_check(10'd1, "write1");
        read_check(10'd2, "write2neg");

        $display("================================================");
        $display("  2. nine-tile accumulate on one slot");
        $display("================================================");
        load(10'd5, 1);                 // ig = 0
        for (k = 1; k < 9; k = k+1)     // ig = 1..8
            accum(10'd5, k*10);
        read_check(10'd5, "acc9");

        $display("================================================");
        $display("  3. interleaved slots, four pixels x nine tiles");
        $display("================================================");
        for (k = 0; k < 4; k = k+1) load(10'd20 + k[ACC_A_BIT-1:0], k*7);
        for (k = 0; k < 4*8; k = k+1)
            accum(10'd20 + (k % 4), (k % 4) + 3);
        for (k = 0; k < 4; k = k+1)
            read_check(10'd20 + k[ACC_A_BIT-1:0], "interleave");

        $display("================================================");
        $display("  4. earlier slots must be untouched");
        $display("================================================");
        read_check(10'd0, "retain0");
        read_check(10'd5, "retain5");

        $display("================================================");
        $display("  5. back-to-back RMW, no idle cycle between them");
        $display("================================================");
        load(10'd40, 5);
        // acc_en stays high across four phases : ph 0,1 twice over on slot 40
        @(negedge clk);
        make_pe(11); acc_addr = 10'd40; acc_first = 1'b0;
        acc_ph = 1'b0; acc_en = 1'b1;
        @(negedge clk); acc_ph = 1'b1;
        @(negedge clk); acc_ph = 1'b0; make_pe(22);   // straight into the next RMW
        @(negedge clk); acc_ph = 1'b1;
        @(negedge clk); acc_en = 1'b0; acc_ph = 1'b0;
        ref_update(10'd40, 1'b0, 11);
        ref_update(10'd40, 1'b0, 22);
        read_check(10'd40, "b2b");

        $display("================================================");
        $display("  6. high address, near the top of the depth");
        $display("================================================");
        load(10'd783, 1000);
        accum(10'd783, -400);
        read_check(10'd783, "top");

        $display("================================================");
        if (errors == 0)
            $display("  PASS   %0d comparisons, 0 mismatches", checks);
        else
            $display("  FAIL   %0d comparisons, %0d mismatches", checks, errors);
        $display("================================================");
        $finish;
    end

    //------------------------------------------------------------------
    // safety net : the single port cannot serve both sides at once
    //------------------------------------------------------------------
    always @(posedge clk)
        if (!rst && acc_en && dr_en)
            $display("  PROTOCOL VIOLATION at %0t : dr_en while acc_en high",
                     $time);

endmodule
