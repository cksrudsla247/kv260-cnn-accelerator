`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/07/09 17:01:19
// Design Name: 
// Module Name: tb_tester
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


module tb_tester();
    //OPCODE
    //GOAL0 = 809400
    //100000 001 001 01000 0000000
    //32 1 1 8
    //000001 001 100 01001 0000000
    // 1 1 4 9
    //000001 100 001 01000 0000000
    // 1 4 1 8
    //000001 010 010 01000 0000000
    // 1 2 2 8
    //000100 010 010 01000 0000000
    // 4 2 2 8
    //GAOL1 = 04C480
    //GOAL2 = 061400
    //GOAL3 = 052400
    //GAOL4 = 112400 
    
    localparam [23:0] OPCODE  = 24'h112400;    
    localparam BATCH_F = OPCODE[23:18];      // batch
    localparam ING_F   = OPCODE[17:15];      // in_group
    localparam OUTG_F  = OPCODE[14:12];      // out_group

    localparam W_ADDRS = ING_F * OUTG_F * 32;
    localparam I_ADDRS = BATCH_F * ING_F;
    localparam O_ADDRS = BATCH_F * OUTG_F;   
    
    localparam W_WORDS = W_ADDRS * 8;
    localparam I_WORDS = I_ADDRS * 8;
    localparam O_WORDS = O_ADDRS * 8;
 
    localparam REQUANT_WIDTH = 8;
    
    reg         clk, rst;
    reg         load_op;
    reg  [23:0] i_opcode;
    reg         in_valid;
    reg  [31:0] in_data;
    wire        out_valid;
    wire [31:0] out_data;
 
    reg [31:0] weight_hex [0:1023];
    reg [31:0] input_hex  [0:255];
    reg [7:0]  golden_hex [0:1023]; 
 
    reg [31:0] got [0:255];           
 
    integer i, a, w, c, n;
    integer pass, fail;
    reg [31:0] exp;
    
    integer i,j,a;
    
    integer pass, fail;
    
    top uut_top (
        .clk       (clk),
        .rst       (rst),
        .load_op   (load_op),
        .i_opcode  (i_opcode),
        .in_valid  (in_valid),
        .in_data   (in_data),
        .out_valid (out_valid),
        .out_data  (out_data)
    );
    
    initial clk = 0;
    always #5 clk = ~clk;
    
    initial begin
        for (i = 0; i < 256;  i = i+1) input_hex[i]  = 0;  
        for (i = 0; i < 1024; i = i+1) golden_hex[i] = 0;
        for (i = 0; i < 1024; i = i+1) weight_hex[i] = 0;
        $readmemh("weight_4.txt", weight_hex);
        $readmemh("input_4.txt",  input_hex);
        $readmemh("golden_4.txt", golden_hex);
    end
    
    initial $monitor("t=%0t state=%0d out_valid=%b",$time, uut_top.u_ctrl.state, out_valid);
    
    initial begin
    
        rst = 0; load_op = 0; i_opcode = 0;
        in_valid = 0; in_data = 0;
        n = 0; pass = 0; fail = 0;
 
        #10; rst = 1;
        #10; rst = 0;
        #3;
        
        i_opcode = OPCODE;
        @(posedge clk); load_op = 1;
        @(posedge clk); load_op = 0;
 
        for (i = 0; i < W_WORDS; i = i+1) begin
            @(posedge clk);
            in_valid <= 1'b1;
            in_data  <= weight_hex[i];
        end
 
        for (i = 0; i < I_WORDS; i = i+1) begin
            @(posedge clk);
            in_valid <= 1'b1;
            in_data  <= input_hex[i];
        end
 
        @(posedge clk);
        in_valid <= 1'b0;
 
        n = 0;
        while (n < O_WORDS) begin
            @(posedge clk);
            #1;                       
            if (out_valid) begin
                got[n] = out_data;
                n = n + 1;
            end
        end
 
        for (a = 0; a < O_ADDRS; a = a+1) begin
            for (w = 0; w < 8; w = w+1) begin
                exp = { golden_hex[a*32 + 4*w + 3],
                        golden_hex[a*32 + 4*w + 2],
                        golden_hex[a*32 + 4*w + 1],
                        golden_hex[a*32 + 4*w + 0] };
                if (got[a*8 + w] !== exp) begin
                    fail = fail + 1;
                    $display("FAIL addr%0d word%0d: got %h exp %h",
                             a, w, got[a*8 + w], exp);
                end else begin
                    pass = pass + 1;
                end
            end
        end
 
        $display("=== PASS=%0d  FAIL=%0d  (total=%0d) ===",
                 pass, fail, O_WORDS);
        $finish;
    end
 
endmodule
