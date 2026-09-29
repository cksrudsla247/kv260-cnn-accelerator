`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module : tester     (synthesizable model of the PS : DRAM + CSR sequencer)
//
//   Owns the DRAM (blk_mem_gen `dram`, 32b x 50176, single port, latency 1) and
//   runs a sequencer that replays a CSR program stored IN THAT SAME DRAM.
//
//   DRAM port A is shared three ways, priority host > csr-fetch > dma :
//     dma       : owns the port while a layer is running
//     csr fetch : only between layers, when the dma is idle
//     host      : the tb (or the PS) loading the image and reading results back
//
//   CSR program layout at PROG_BASE, two words per entry :
//     word 2i   = csr_addr (4 bits, in [3:0])
//     word 2i+1 = csr_data (32 bits)
//   addr 4'hF = "pulse start, then wait for core_done"
//   addr 4'hE = end of program
//////////////////////////////////////////////////////////////////////////////////
module tester (
    input               clk,
    input               rst,           // async, active HIGH

    //---- host port : takes the DRAM port whenever it is asserted ------------
    input               h_en,          // host access this cycle
    input               h_we,          // 1 = write, 0 = read
    input      [15:0]   h_addr,
    input      [31:0]   h_wdata,
    output     [31:0]   h_rdata,       // valid one cycle after h_en
    input               go,            // 1-cycle : start the CSR program

    //---- DRAM interface from the dma ---------------------------------------
    input               dram_en,
    input               dram_we,
    input      [15:0]   dram_addr,
    input      [31:0]   dram_wdata,
    output     [31:0]   dram_rdata,

    //---- CSR out to core.controller ----------------------------------------
    output reg          csr_we,
    output reg [3:0]    csr_addr,
    output reg [31:0]   csr_data,
    input               core_done,     // 1-cycle pulse from the core
    output reg          all_done       // level : whole program finished
);

//---------------------------------------------------------------- DRAM port mux
    reg        cs_en;      // csr sequencer wants the port this cycle
    reg [15:0] cs_addr;    // its fetch address

    wire        pa_en   = dram_en | h_en | cs_en;
    wire        pa_we   = h_en ? h_we    : (cs_en ? 1'b0    : dram_we);
    wire [15:0] pa_addr = h_en ? h_addr  : (cs_en ? cs_addr : dram_addr);
    wire [31:0] pa_din  = h_en ? h_wdata : dram_wdata;
    wire [31:0] pa_dout;

    dram u_dram (
        .clka (clk),
        .ena  (pa_en),
        .wea  (pa_we),
        .addra(pa_addr),
        .dina (pa_din),
        .douta(pa_dout)
    );
    assign dram_rdata = pa_dout;   // all three readers see the same port output
    assign h_rdata    = pa_dout;

//---------------------------------------------------------------- CSR sequencer
    // Task 1's 0xC300 is inside the CNN activation buffers. See docs/DESIGN_NOTES.md
    // section 7 for the full map.
    localparam [15:0] PROG_BASE = 16'hEA80;   // CSR program lives here in DRAM
    localparam [2:0]
        T_IDLE  = 3'd0,
        T_F0    = 3'd1,   // issue the addr-word address
        T_F1    = 3'd2,   // addr-word valid ; issue the data-word address
        T_F2    = 3'd3,   // data-word valid ; act on the entry
        T_START = 3'd4,   // start pulse issued
        T_WAIT  = 3'd5,   // wait for core_done
        T_DONE  = 3'd6;

    reg [2:0]  tstate;
    reg [15:0] ptr;        // DRAM address of the current program entry
    reg [3:0]  e_addr_r;   // the CSR index fetched in T_F1

    // The fetch address is combinational from the state : the BRAM samples it
    // on the edge, so the word is valid in the NEXT state.
    always @(*) begin
        cs_en   = 1'b0;
        cs_addr = 16'd0;
        case (tstate)
        T_F0: begin cs_en = 1'b1; cs_addr = ptr;         end
        T_F1: begin cs_en = 1'b1; cs_addr = ptr + 16'd1; end
        default: ;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tstate<=T_IDLE; ptr<=PROG_BASE; e_addr_r<=4'd0;
            csr_we<=0; csr_addr<=0; csr_data<=0; all_done<=0;
        end else begin
            csr_we <= 1'b0;                    // 1-cycle strobe
            case (tstate)
            T_IDLE: begin
                all_done <= 1'b0;
                ptr      <= PROG_BASE;
                if (go) tstate <= T_F0;
            end
            T_F0: tstate <= T_F1;
            T_F1: begin
                e_addr_r <= pa_dout[3:0];      // addr word is valid this cycle
                tstate   <= T_F2;
            end
            T_F2: begin                        // data word is valid this cycle
                if (e_addr_r == 4'hE) begin
                    tstate <= T_DONE;
                end else if (e_addr_r == 4'hF) begin
                    csr_we   <= 1'b1;
                    csr_addr <= 4'd7;
                    csr_data <= 32'd1;         // start pulse
                    tstate   <= T_START;
                end else begin
                    csr_we   <= 1'b1;
                    csr_addr <= e_addr_r;
                    csr_data <= pa_dout;
                    ptr      <= ptr + 16'd2;
                    tstate   <= T_F0;
                end
            end
            T_START: begin
                ptr    <= ptr + 16'd2;
                tstate <= T_WAIT;
            end
            T_WAIT: if (core_done) tstate <= T_F0;
            T_DONE: begin
                all_done <= 1'b1;
                tstate   <= T_IDLE;
            end
            default: tstate <= T_IDLE;
            endcase
        end
    end
endmodule   