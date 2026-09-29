`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/02 14:07:29
// Design Name: 
// Module Name: tb_compute_test
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


module tb_compute_test();
    reg clk = 0;
    always #5 clk = ~clk;

    reg         in_we;
    reg  [4:0]  in_addr;
    reg  [7:0] in_din  [0:31];
    wire [7:0] in_dout [0:31];

    multi_bank_input u_input_mem (
        .clk(clk), .we(in_we),
        .input_addr(in_addr),
        .input_din(in_din),
        .input_dout(in_dout)
    );

    reg         w_we;
    reg  [4:0]  w_addr;
    reg  [7:0]  w_din  [0:31];
    wire [7:0]  w_dout [0:31];

    multi_bank_weight u_weight_mem (
        .clk(clk), .we(w_we),
        .weight_addr(w_addr),
        .weight_din(w_din),
        .weight_dout(w_dout)
    );

    reg  pe_rst, pe_we_w;
    reg  [4:0] pe_row_addr;
    wire signed [7:0] pe_i_data [0:31];
    wire signed [20:0] pe_o_result [0:31];

    genvar gi;
    generate
      for (gi = 0; gi < 32; gi = gi+1) begin : cast_data
        assign pe_i_data[gi] = $signed(in_dout[gi]);
      end
    endgenerate

    pe_array_hier u_pe_array (
        .clk(clk), .rst(pe_rst), .we_w(pe_we_w),
        .row_addr(pe_row_addr),
        .i_data(pe_i_data),
        .i_weight(w_dout),
        .o_result(pe_o_result)
    );

    reg         out_we;
    reg  [1:0]  out_addr;
    reg  signed [20:0] out_din [0:31];
    wire signed [20:0] out_dout [0:31];

    multi_bank_output u_output_mem (
        .clk(clk), .we(out_we),
        .output_addr(out_addr),
        .output_din(out_din),
        .output_dout(out_dout)
    );

    integer i, r, w_row;

    initial begin
        pe_rst = 1; pe_we_w = 0; pe_row_addr = 0;
        in_we = 0; in_addr = 0;
        w_we = 0; w_addr = 0;
        out_we = 0; out_addr = 0;
        @(posedge clk); @(posedge clk);
        pe_rst = 0;

        for (i = 0; i < 32; i = i+1)
            in_din[i] = i;
        in_addr = 0;
        in_we = 1;
        @(posedge clk);
        in_we = 0;

        for (w_row = 0; w_row < 32; w_row = w_row + 1) begin
            w_addr = w_row[4:0];
            for (i = 0; i < 32; i = i+1)
                w_din[i] = 1;
            w_we = 1;
            @(posedge clk);
        end
        w_we = 0;

        pe_we_w = 1;
        w_addr = 0;
        @(posedge clk);
        for (r = 0; r < 32; r = r+1) begin
            pe_row_addr = r;
            if (r < 31) w_addr = r+1;
            @(posedge clk);
        end
        pe_we_w = 0;

        in_addr = 0;
        @(posedge clk);
        #1;

        for (i = 0; i < 32; i = i+1)
            out_din[i] = pe_o_result[i];
        out_addr = 0;
        out_we = 1;
        @(posedge clk);
        out_we = 0;

        out_addr = 0;
        @(posedge clk);
        #1;
        for (i = 0; i < 32; i = i+1) begin
            if (out_dout[i] !== 496)
                $display("COMPUTE FAIL col%0d: expected 496 got %0d", i, out_dout[i]);
        end
        $display("Compute test done");
        $finish;
    end
endmodule
