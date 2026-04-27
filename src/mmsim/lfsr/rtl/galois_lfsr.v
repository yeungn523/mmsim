///
/// @file galois_lfsr.v
/// @brief 32-bit Galois LFSR that produces one new pseudo-random sample per clock cycle.
///

module galois_lfsr #(
    parameter [31:0] POLY = 32'h80200003,   ///< Galois feedback polynomial.
    parameter [31:0] SEED = 32'hDEADBEEF    ///< Initial state loaded on reset.
)(
    input  wire        clk,                 ///< System clock.
    input  wire        rst_n,               ///< Active-low asynchronous reset.
    input  wire        en,                  ///< Advances the LFSR state when high.
    input  wire [31:0] seed_load,           ///< External seed value applied when seed_valid is high.
    input  wire        seed_valid,          ///< Loads seed_load into the state on the next edge.
    output reg  [31:0] out                  ///< Current LFSR state, updated on each enabled cycle.
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out <= SEED;
        else if (seed_valid)
            out <= seed_load;
        else if (en) begin
            // Galois feedback: shift right, XOR polynomial if LSB=1
            out <= {1'b0, out[31:1]} ^ (out[0] ? POLY : 32'b0);
        end
    end
endmodule
