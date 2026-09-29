`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench : tb_maxpool
//
//   Streams a whole OH x OW map through in raster order, the way the drain
//   does, and compares every emitted pixel against a behavioural 2x2 max taken
//   from the same source array.
//
//     1  a 4x4 map pools to 2x2, every value correct, on every lane
//     2  emission happens only where both oh and ow are odd
//     3  the lanes stay independent (each lane gets its own value)
//     4  negative values pool correctly (signed compare, relu_en off)
//     5  a wider map exercises more than one line-buffer slot
//     6  pool_en = 0 passes everything through untouched
//////////////////////////////////////////////////////////////////////////////////
module tb_maxpool;

    localparam COL_SIZE   = 32;
    localparam DATA_WIDTH = 8;
    localparam LB_A_BIT   = 4;

    reg clk = 0, rst;
    always #5 clk = ~clk;

    reg                             en, pool_en, ow_odd, oh_odd;
    reg  [LB_A_BIT-1:0]             col;
    reg  [COL_SIZE*DATA_WIDTH-1:0]  din;
    wire [COL_SIZE*DATA_WIDTH-1:0]  dout;
    wire                            dvalid;

    maxpool #(.COL_SIZE(COL_SIZE), .DATA_WIDTH(DATA_WIDTH), .LB_A_BIT(LB_A_BIT))
    dut (.clk(clk), .rst(rst), .en(en), .pool_en(pool_en),
         .ow_odd(ow_odd), .oh_odd(oh_odd), .col(col),
         .i_data(din), .o_data(dout), .o_valid(dvalid));

    integer errors = 0, checks = 0;

    // source map and the expected pooled result
    reg signed [DATA_WIDTH-1:0] src [0:31][0:31][0:COL_SIZE-1];
    integer got_n;                       // emitted pixels seen so far

    integer oh, ow, g, k;
    integer OHN, OWN;

    //------------------------------------------------------------------
    // push one pixel and, if the module emits, check it against a 2x2 max
    //------------------------------------------------------------------
    task push(input integer y, input integer x);
        integer gg;
        reg signed [DATA_WIDTH-1:0] exp, v;
        integer py, px, dy, dx;
        begin
            @(negedge clk);
            for (gg = 0; gg < COL_SIZE; gg = gg+1)
                din[gg*DATA_WIDTH +: DATA_WIDTH] = src[y][x][gg];
            ow_odd = x[0];
            oh_odd = y[0];
            col    = x[LB_A_BIT:1];
            en     = 1'b1;
            #1;                                    // let o_valid settle
            if (dvalid) begin
                py = y >> 1;  px = x >> 1;
                if (!pool_en) begin py = y; px = x; end
                for (gg = 0; gg < COL_SIZE; gg = gg+1) begin
                    if (pool_en) begin
                        exp = src[py*2][px*2][gg];
                        for (dy = 0; dy < 2; dy = dy+1)
                          for (dx = 0; dx < 2; dx = dx+1) begin
                            v = src[py*2+dy][px*2+dx][gg];
                            if (v > exp) exp = v;
                          end
                    end else exp = src[y][x][gg];
                    checks = checks + 1;
                    if ($signed(dout[gg*DATA_WIDTH +: DATA_WIDTH]) !== exp) begin
                        errors = errors + 1;
                        if (errors < 8)
                            $display("  FAIL (%0d,%0d) lane %0d : exp %0d got %0d",
                                     py, px, gg, exp,
                                     $signed(dout[gg*DATA_WIDTH +: DATA_WIDTH]));
                    end
                end
                got_n = got_n + 1;
            end
            @(posedge clk);
            #1;
            en = 1'b0;
        end
    endtask

    //------------------------------------------------------------------
    task run_map(input integer h, input integer w, input integer seed,
                 input [127:0] tag);
        integer exp_n;
        begin
            OHN = h; OWN = w; got_n = 0;
            for (oh = 0; oh < h; oh = oh+1)
              for (ow = 0; ow < w; ow = ow+1)
                for (g = 0; g < COL_SIZE; g = g+1)
                    src[oh][ow][g] = $signed((seed + oh*37 + ow*11 + g*5) % 200) - 100;

            for (oh = 0; oh < h; oh = oh+1)
              for (ow = 0; ow < w; ow = ow+1)
                push(oh, ow);

            exp_n = pool_en ? (h/2)*(w/2) : h*w;
            if (got_n !== exp_n) begin
                errors = errors + 1;
                $display("  FAIL %0s : emitted %0d pixels, expected %0d",
                         tag, got_n, exp_n);
            end else
                $display("  ok   %0s : %0d in -> %0d out", tag, h*w, got_n);
        end
    endtask

    initial begin
        rst = 1'b1; en = 0; pool_en = 1; ow_odd = 0; oh_odd = 0; col = 0; din = 0;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        $display("================================================");
        $display("  maxpool 2x2 on the drain path");
        $display("================================================");

        pool_en = 1'b1;
        run_map(4,  4,   0, "4x4   -> 2x2");
        run_map(4,  4, 150, "4x4   negative-heavy");
        run_map(8,  8,  40, "8x8   -> 4x4");
        run_map(5,  5,  60, "5x5   -> 2x2 (odd, Conv3)");
        run_map(7,  7,  75, "7x7   -> 3x3 (odd)");
        run_map(14, 28, 90, "14x28 -> 7x14 (line buffer)");
        run_map(28, 28,  7, "28x28 -> 14x14 (widest)");

        $display("------------------------------------------------");
        pool_en = 1'b0;
        run_map(4, 4, 33, "bypass 4x4 unchanged");

        $display("================================================");
        if (errors == 0)
            $display("  PASS   %0d comparisons, 0 mismatches", checks);
        else
            $display("  FAIL   %0d comparisons, %0d mismatches", checks, errors);
        $display("================================================");
        $finish;
    end

endmodule
