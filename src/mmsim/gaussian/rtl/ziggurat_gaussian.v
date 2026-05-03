// Generates Q4.12 signed Gaussian samples using the ziggurat method backed by an M10K ROM.

`timescale 1ns/1ps

module ziggurat_gaussian (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [31:0] seed0,
    input  wire [31:0] seed1,
    input  wire [31:0] seed2,
    input  wire [31:0] seed3,
    input  wire        seed_valid,
    // Q4.12 signed.
    output reg  [15:0] gauss_out,
    output reg         valid_out
);

    reg [31:0] next_s0;
    reg [38:0] product;
    reg [15:0] y_delta;
    reg [27:0] y_product;
    reg [15:0] y_candidate;
    reg [15:0] pdf_value;
    reg [31:0] current_tail_u;
    reg [15:0] neg_log_u;
    reg [31:0] inv_r_product;
    reg [15:0] x_q412;

    // LFSR (Galois, 32-bit)
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

    reg  [8:0]  rom_addr;
    wire [15:0] rom_data_out;

`ifdef SYNTHESIS
    altsyncram #(
        .operation_mode         ("ROM"),
        .width_a                (16),
        .widthad_a              (9),
        .numwords_a             (512),
        .init_file              ("lut/ziggurat_tables.mif"),
        .outdata_reg_a          ("UNREGISTERED"),
        .address_aclr_a         ("NONE"),
        .outdata_aclr_a         ("NONE"),
        .lpm_hint               ("ENABLE_RUNTIME_MOD=NO"),
        .lpm_type               ("altsyncram"),
        .ram_block_type         ("M10K"),
        .intended_device_family ("Cyclone V")
    ) rom_inst (
        .clock0         (clk),
        .address_a      (rom_addr),
        .q_a            (rom_data_out),
        .aclr0          (1'b0),
        .aclr1          (1'b0),
        .address_b      (1'b1),
        .addressstall_a (1'b0),
        .addressstall_b (1'b0),
        .byteena_a      (1'b1),
        .byteena_b      (1'b1),
        .clock1         (1'b1),
        .clocken0       (1'b1),
        .clocken1       (1'b1),
        .clocken2       (1'b1),
        .clocken3       (1'b1),
        .data_a         ({16{1'b1}}),
        .data_b         (1'b1),
        .eccstatus      (),
        .q_b            (),
        .rden_a         (1'b1),
        .rden_b         (1'b1),
        .wren_a         (1'b0),
        .wren_b         (1'b0)
    );
`else
    // Models the ROM with a behavioral shim in simulation.
`include "lut/ziggurat_tables.vh"
    reg [15:0] rom_data_reg;
    assign rom_data_out = rom_data_reg;
    always @(posedge clk) begin
        rom_data_reg <= rom_addr[8] ? zig_y_rom(rom_addr[7:0])
                                    : zig_x_rom(rom_addr[7:0]);
    end
`endif

    // FSM States
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
    reg [31:0] u1;
    reg [15:0] x_candidate;

    // Returns the natural-log values used for tail sampling (32-entry, 5-bit index).
    function [15:0] log_lut;
        input [4:0] index;
        case (index)
            5'd0:  log_lut = 16'h3664;
            5'd1:  log_lut = 16'h2C91;
            5'd2:  log_lut = 16'h259D;
            5'd3:  log_lut = 16'h2171;
            5'd4:  log_lut = 16'h1DF4;
            5'd5:  log_lut = 16'h1B86;
            5'd6:  log_lut = 16'h198A;
            5'd7:  log_lut = 16'h1671;
            5'd8:  log_lut = 16'h1454;
            5'd9:  log_lut = 16'h1278;
            5'd10: log_lut = 16'h10CA;
            5'd11: log_lut = 16'h0F22;
            5'd12: log_lut = 16'h0D9D;
            5'd13: log_lut = 16'h0C46;
            5'd14: log_lut = 16'h0B0E;
            5'd15: log_lut = 16'h09F9;
            5'd16: log_lut = 16'h08F4;
            5'd17: log_lut = 16'h0803;
            5'd18: log_lut = 16'h0726;
            5'd19: log_lut = 16'h0639;
            5'd20: log_lut = 16'h055F;
            5'd21: log_lut = 16'h0557;
            5'd22: log_lut = 16'h0474;
            5'd23: log_lut = 16'h039C;
            5'd24: log_lut = 16'h02CE;
            5'd25: log_lut = 16'h020A;
            5'd26: log_lut = 16'h014D;
            5'd27: log_lut = 16'h0099;
            5'd28: log_lut = 16'h0066;
            5'd29: log_lut = 16'h003A;
            5'd30: log_lut = 16'h0014;
            5'd31: log_lut = 16'h0003;
            default: log_lut = 16'h0000;
        endcase
    endfunction

    // Returns exp(-0.5 * x^2) in Q4.12 for the wedge test, indexed by x_candidate[13:9]
    // (32-entry, steps of 0.125 from 0 to 3.875).
    function [15:0] pdf_lut;
        input [4:0] index;
        case (index)
            5'd0:  pdf_lut = 16'h1000;
            5'd1:  pdf_lut = 16'h0FE0;
            5'd2:  pdf_lut = 16'h0F82;
            5'd3:  pdf_lut = 16'h0EEB;
            5'd4:  pdf_lut = 16'h0E1F;
            5'd5:  pdf_lut = 16'h0D29;
            5'd6:  pdf_lut = 16'h0C14;
            5'd7:  pdf_lut = 16'h0AEA;
            5'd8:  pdf_lut = 16'h09B4;
            5'd9:  pdf_lut = 16'h087E;
            5'd10: pdf_lut = 16'h0753;
            5'd11: pdf_lut = 16'h0638;
            5'd12: pdf_lut = 16'h0532;
            5'd13: pdf_lut = 16'h0445;
            5'd14: pdf_lut = 16'h0376;
            5'd15: pdf_lut = 16'h02C2;
            5'd16: pdf_lut = 16'h022A;
            5'd17: pdf_lut = 16'h01AC;
            5'd18: pdf_lut = 16'h0145;
            5'd19: pdf_lut = 16'h00F4;
            5'd20: pdf_lut = 16'h00B4;
            5'd21: pdf_lut = 16'h0082;
            5'd22: pdf_lut = 16'h005D;
            5'd23: pdf_lut = 16'h0042;
            5'd24: pdf_lut = 16'h002D;
            5'd25: pdf_lut = 16'h001F;
            5'd26: pdf_lut = 16'h0015;
            5'd27: pdf_lut = 16'h000E;
            5'd28: pdf_lut = 16'h0009;
            5'd29: pdf_lut = 16'h0006;
            5'd30: pdf_lut = 16'h0004;
            5'd31: pdf_lut = 16'h0002;
            default: pdf_lut = 16'h0000;
        endcase
    endfunction

    // FSM
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
                    next_s0  = lfsr_tick(s0, P0);
                    s0       <= next_s0;
                    s1       <= lfsr_tick(s1, P1);
                    layer    <= next_s0[7:0];
                    sign_bit <= next_s0[8];
                    xi_bits  <= next_s0[31:9];
                    rom_addr <= {1'b0, next_s0[7:0]};
                    state    <= S_ROM_X;
                end

                S_ROM_X: begin
                    if (layer == 8'd0)
                        rom_addr <= 9'h000;
                    else
                        rom_addr <= {1'b0, (layer - 8'd1)};
                    state <= S_FAST_CMP;
                end

                S_FAST_CMP: begin
                    x_layer     <= rom_data_out;
                    product      = {23'd0, rom_data_out} * {16'd0, xi_bits};
                    x_candidate <= product[38:23];
                    state       <= S_WEDGE_RD;
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
                            state    <= S_WEDGE_W1;
                        end
                        s2 <= lfsr_tick(s2, P2);
                        u1 <= lfsr_tick(s2, P2);
                    end
                end

                S_WEDGE_W1: begin
                    if (layer == 8'd0) begin
                        state <= S_OUTPUT;
                    end else begin
                        rom_addr <= {1'b1, (layer - 8'd1)};
                        state    <= S_WEDGE_W2;
                    end
                end

                S_WEDGE_W2: begin
                    y_layer <= rom_data_out;
                    state   <= S_WEDGE_CMP;
                end

                S_WEDGE_CMP: begin
                    y_delta     = rom_data_out - y_layer;
                    y_product   = u1[31:20] * y_delta;
                    y_candidate = y_layer + y_product[27:12];
                    pdf_value   = pdf_lut(x_candidate[13:9]);
                    if (y_candidate < pdf_value)
                        state <= S_OUTPUT;
                    else
                        state <= S_DRAW;
                end

                S_TAIL: begin
                    s2             <= lfsr_tick(s2, P2);
                    current_tail_u  = lfsr_tick(s2, P2);
                    neg_log_u       = log_lut(current_tail_u[31:27]);
                    inv_r_product   = neg_log_u * 16'h0461;
                    x_candidate    <= 16'h3A77 + inv_r_product[27:12];
                    state          <= S_OUTPUT;
                end

                S_OUTPUT: begin
                    x_q412    = x_candidate;
                    gauss_out <= sign_bit ? ((~x_q412) + 1'b1) : x_q412;
                    valid_out <= 1'b1;
                    state     <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
