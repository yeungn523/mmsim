// Approximates a Gaussian by summing 12 parallel 32-bit Galois LFSRs into a Q4.12 signed output.

`timescale 1ns/1ns

module clt12_gaussian (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [31:0] seed0, seed1, seed2, seed3,
    input  wire        seed_valid,
    output reg  [15:0] gauss_out,   // Q4.12 signed
    output reg         valid_out
);

    wire [31:0] lfsr_out [0:11];

    // Uses sparse Koopman polynomials with bitwise-scrambled seeds to keep streams independent.
    galois_lfsr #(.POLY(32'h80000057)) lfsr0  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(seed0),       .seed_valid(seed_valid), .out(lfsr_out[0]));
    galois_lfsr #(.POLY(32'h80000062)) lfsr1  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(seed1),       .seed_valid(seed_valid), .out(lfsr_out[1]));
    galois_lfsr #(.POLY(32'h8000007A)) lfsr2  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(seed2),       .seed_valid(seed_valid), .out(lfsr_out[2]));
    galois_lfsr #(.POLY(32'h80000092)) lfsr3  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(seed3),       .seed_valid(seed_valid), .out(lfsr_out[3]));

    galois_lfsr #(.POLY(32'h800000B9)) lfsr4  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(~seed0),      .seed_valid(seed_valid), .out(lfsr_out[4]));
    galois_lfsr #(.POLY(32'h800000BA)) lfsr5  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(~seed1),      .seed_valid(seed_valid), .out(lfsr_out[5]));
    galois_lfsr #(.POLY(32'h80000106)) lfsr6  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(~seed2),      .seed_valid(seed_valid), .out(lfsr_out[6]));
    galois_lfsr #(.POLY(32'h80000114)) lfsr7  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(~seed3),      .seed_valid(seed_valid), .out(lfsr_out[7]));

    galois_lfsr #(.POLY(32'h8000012D)) lfsr8  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(seed0^seed1), .seed_valid(seed_valid), .out(lfsr_out[8]));
    galois_lfsr #(.POLY(32'h8000014E)) lfsr9  (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(seed2^seed3), .seed_valid(seed_valid), .out(lfsr_out[9]));
    galois_lfsr #(.POLY(32'h8000016C)) lfsr10 (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(seed0^seed3), .seed_valid(seed_valid), .out(lfsr_out[10]));
    galois_lfsr #(.POLY(32'h8000019F)) lfsr11 (.clk(clk), .rst_n(rst_n), .en(en), .seed_load(seed1^seed2), .seed_valid(seed_valid), .out(lfsr_out[11]));

    // Sums top 16 bits, recenters to zero mean, and scales to Q4.12.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gauss_out <= 16'h0;
            valid_out <= 1'b0;
        end else if (seed_valid) begin
            valid_out <= 1'b0;
        end else if (en) begin
            begin
                reg [20:0] comb_sum;
                reg signed [21:0] centered;
                reg signed [21:0] shifted;

                comb_sum = lfsr_out[0][31:16] + lfsr_out[1][31:16] + lfsr_out[2][31:16] + lfsr_out[3][31:16] +
                           lfsr_out[4][31:16] + lfsr_out[5][31:16] + lfsr_out[6][31:16] + lfsr_out[7][31:16] +
                           lfsr_out[8][31:16] + lfsr_out[9][31:16] + lfsr_out[10][31:16] + lfsr_out[11][31:16];

                // Subtracts half of 12 * 65535 to recenter.
                centered = $signed({1'b0, comb_sum}) - 22'sd393216;

                shifted = centered >>> 4;

                gauss_out <= shifted[15:0];
            end
            valid_out <= 1'b1;
        end else begin
            valid_out <= 1'b0;
        end
    end

endmodule
