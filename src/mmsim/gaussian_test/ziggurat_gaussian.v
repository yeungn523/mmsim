// ziggurat_gaussian.v
// Ziggurat method Gaussian generator
// Output format: Q4.12 signed fixed-point (16-bit)

`timescale 1ns/1ps

module ziggurat_gaussian (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [31:0] seed0, seed1, seed2, seed3,
    input  wire        seed_valid,
    output reg  [15:0] gauss_out,   // Q4.12 signed natively
    output reg         valid_out
);

    // -----------------------------------------------------------------------
    // LFSR (Galois, 32-bit)
    // Using Koopman sparse primitive polynomials to match CLT-12
    // -----------------------------------------------------------------------
    reg [31:0] s0, s1, s2, s3;

    localparam [31:0] P0 = 32'h80000057;
    localparam [31:0] P1 = 32'h80000062;
    localparam [31:0] P2 = 32'h8000007A;
    localparam [31:0] P3 = 32'h80000092;

    function [31:0] lfsr_tick;
        input [31:0] st;
        input [31:0] poly;
        begin
            lfsr_tick = {1'b0, st[31:1]} ^ (st[0] ? poly : 32'b0);
        end
    endfunction

    // -----------------------------------------------------------------------
    // M10K ROM model
    // -----------------------------------------------------------------------
    reg [8:0] rom_addr;

`ifdef SYNTHESIS
    // --- Synthesis: M10K altsyncram instance ---
    // altsyncram #( ... ) rom_inst ( ... );
`else
    // --- Simulation: behavioral synchronous ROM ---
    `include "ziggurat_tables.vh"

    reg [15:0] rom_data_out;
    reg [8:0]  rom_addr_r;  // registered address (models M10K pipeline)

    always @(posedge clk) begin
        rom_addr_r <= rom_addr;
        if (rom_addr[8] == 1'b0)
            rom_data_out <= zig_x_rom(rom_addr[7:0]);
        else
            rom_data_out <= zig_y_rom(rom_addr[7:0]);
    end
`endif

    // -----------------------------------------------------------------------
    // FSM States & Registers
    // -----------------------------------------------------------------------
    localparam S_IDLE      = 4'd0;
    localparam S_DRAW      = 4'd1;
    localparam S_ROM_X     = 4'd2;
    localparam S_FAST_CMP  = 4'd3;
    localparam S_WEDGE_RD  = 4'd4;
    localparam S_WEDGE_W1  = 4'd5;
    localparam S_WEDGE_W2  = 4'd6;
    localparam S_WEDGE_CMP = 4'd7;
    localparam S_TAIL      = 4'd8;
    localparam S_OUTPUT    = 4'd9;

    reg [3:0]  state;

    reg [7:0]  layer;           
    reg        sign_bit;        
    reg [22:0] xi_bits;         
    reg [15:0] x_layer;         
    reg [15:0] x_layer_m1;      
    reg [15:0] y_layer;         
    reg [15:0] y_layer_m1;      
    reg [31:0] u1;              
    reg [15:0] x_candidate;     

    // -----------------------------------------------------------------------
    // LUTs (Log approximation and PDF)
    // -----------------------------------------------------------------------
    function [15:0] log_lut;
        input [4:0] idx;
        case (idx)
            5'd0:  log_lut = 16'h3664; // |ln(1/32)|  = 3.466
            5'd1:  log_lut = 16'h2C91; // |ln(2/32)|  = 2.773
            5'd2:  log_lut = 16'h259D; // |ln(3/32)|  = 2.367
            5'd3:  log_lut = 16'h2171; // |ln(4/32)|  = 2.079
            5'd4:  log_lut = 16'h1DF4; // |ln(5/32)|  = 1.856
            5'd5:  log_lut = 16'h1B86; // |ln(6/32)|  = 1.674
            5'd6:  log_lut = 16'h198A; // |ln(7/32)|  = 1.520
            5'd7:  log_lut = 16'h1671; // |ln(8/32)|  = 1.386
            5'd8:  log_lut = 16'h1454; // |ln(9/32)|  = 1.269
            5'd9:  log_lut = 16'h1278; // |ln(10/32)| = 1.163
            5'd10: log_lut = 16'h10CA; // |ln(11/32)| = 1.066
            5'd11: log_lut = 16'h0F22; // |ln(12/32)| = 0.981
            5'd12: log_lut = 16'h0D9D; // |ln(13/32)| = 0.902
            5'd13: log_lut = 16'h0C46; // |ln(14/32)| = 0.827
            5'd14: log_lut = 16'h0B0E; // |ln(15/32)| = 0.755
            5'd15: log_lut = 16'h09F9; // |ln(16/32)| = 0.693
            5'd16: log_lut = 16'h08F4; // |ln(17/32)| = 0.631
            5'd17: log_lut = 16'h0803; // |ln(18/32)| = 0.575 
            5'd18: log_lut = 16'h0726; // |ln(19/32)| = 0.522
            5'd19: log_lut = 16'h0639; // |ln(20/32)| = 0.470 
            5'd20: log_lut = 16'h055F; // |ln(21/32)| = 0.421
            5'd21: log_lut = 16'h0557; // |ln(22/32)| = 0.375 
            5'd22: log_lut = 16'h0474; // |ln(23/32)| = 0.330
            5'd23: log_lut = 16'h039C; // |ln(24/32)| = 0.288
            5'd24: log_lut = 16'h02CE; // |ln(25/32)| = 0.247
            5'd25: log_lut = 16'h020A; // |ln(26/32)| = 0.208
            5'd26: log_lut = 16'h014D; // |ln(27/32)| = 0.170
            5'd27: log_lut = 16'h0099; // |ln(28/32)| = 0.134
            5'd28: log_lut = 16'h0066; // |ln(29/32)| = 0.099
            5'd29: log_lut = 16'h003A; // |ln(30/32)| = 0.065
            5'd30: log_lut = 16'h0014; // |ln(31/32)| = 0.032
            5'd31: log_lut = 16'h0003; // |ln(32/32)| ~ 0 clamp
            default: log_lut = 16'h0000;
        endcase
    endfunction

    function [15:0] pdf_lut;
        input [15:0] x_q412;  
        real xf, yf;
        begin
            xf = $itor(x_q412) / 4096.0;
            yf = $exp(-0.5 * xf * xf);
            pdf_lut = $rtoi(yf * 4096.0) & 16'hFFFF;
        end
    endfunction

    // -----------------------------------------------------------------------
    // Main FSM Logic
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0        <= 32'hDEADBEEF;
            s1        <= 32'hCAFEBABE;
            s2        <= 32'h12345678;
            s3        <= 32'hABCDEF01;
            state     <= S_IDLE;
            valid_out <= 1'b0;
            gauss_out <= 16'h0000;
            rom_addr  <= 9'h0;
        end else if (seed_valid) begin
            s0 <= seed0; s1 <= seed1; s2 <= seed2; s3 <= seed3;
            state     <= S_IDLE;
            valid_out <= 1'b0;
        end else begin
            valid_out <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (en) state <= S_DRAW;
                end

                S_DRAW: begin
                    s0 <= lfsr_tick(s0, P0);
                    s1 <= lfsr_tick(s1, P1);

                    layer    <= lfsr_tick(s0, P0)[7:0];
                    sign_bit <= lfsr_tick(s0, P0)[8];
                    xi_bits  <= lfsr_tick(s0, P0)[31:9];

                    rom_addr <= {1'b0, lfsr_tick(s0, P0)[7:0]};
                    state <= S_ROM_X;
                end

                S_ROM_X: begin
                    if (layer == 8'd0)
                        rom_addr <= 9'h000;
                    else
                        rom_addr <= {1'b0, (layer - 8'd1)};
                    state <= S_FAST_CMP;
                end

                S_FAST_CMP: begin
                    x_layer <= rom_data_out;
                    
                    begin
                        reg [38:0] prod;
                        prod = {23'd0, rom_data_out} * {16'd0, xi_bits}; 
                        x_candidate <= prod[38:23];  // Native Q4.12
                    end
                    state <= S_WEDGE_RD;
                end

                S_WEDGE_RD: begin
                    x_layer_m1 <= rom_data_out;

                    if (layer != 8'd0 && x_candidate < rom_data_out) begin
                        state <= S_OUTPUT;
                    end else begin
                        if (layer == 8'd255) begin
                            state <= S_TAIL;
                        end else begin
                            rom_addr <= {1'b1, layer}; 
                            state <= S_WEDGE_W1;
                        end
                        s2 <= lfsr_tick(s2, P2);
                        u1 <= lfsr_tick(s2, P2);
                    end
                end

                S_WEDGE_W1: begin
                    rom_addr <= {1'b1, (layer - 8'd1)};
                    state <= S_WEDGE_W2;
                end

                S_WEDGE_W2: begin
                    y_layer <= rom_data_out;
                    state <= S_WEDGE_CMP;
                end

                S_WEDGE_CMP: begin
                    y_layer_m1 <= rom_data_out;

                    begin
                        reg [15:0] y_delta;
                        reg [27:0] y_prod;
                        reg [15:0] y_candidate;
                        reg [15:0] pdf_val;

                        y_delta     = rom_data_out - y_layer;        
                        y_prod      = u1[31:20] * y_delta;          
                        y_candidate = y_layer + y_prod[27:12];      
                        pdf_val     = pdf_lut(x_candidate);         

                        if (y_candidate < pdf_val) begin
                            state <= S_OUTPUT;
                        end else begin
                            state <= S_DRAW; 
                        end
                    end
                end

                S_TAIL: begin
                    s2 <= lfsr_tick(s2, P2);
                    begin
                        reg [31:0] curr_tail_u;
                        real u_float, neg_ln_u;
                        reg [31:0] inv_r_prod;
                        reg [15:0] x_tail_q412;

                        curr_tail_u = lfsr_tick(s2, P2);

                        // Behavioral exact ln for simulation only
                        // In synthesis: replace with log_lut approximation (see quartus file)
                        u_float = $itor(curr_tail_u + 1) / 4294967296.0;  // +1 avoids ln(0)
                        neg_ln_u = -$ln(u_float);

                        // x_tail = r + neg_ln_u / r, in Q4.12
                        // r = 3.6561, 1/r = 0.2735, Q4.12 = 0x0462
                        inv_r_prod = $rtoi(neg_ln_u * 16'h0462);
                        x_tail_q412 = 16'h3A5C + inv_r_prod[15:0];  // r in Q4.12 = 0x3A5C

                        x_candidate <= x_tail_q412;
                    end
                    state <= S_OUTPUT;
                end

                S_OUTPUT: begin
                    begin
                        reg [15:0] x_q412;
                        x_q412 = x_candidate;
                        
                        if (sign_bit)
                            gauss_out <= (~x_q412) + 1'b1;
                        else
                            gauss_out <= x_q412;
                    end
                    valid_out <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule