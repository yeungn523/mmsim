// galois_lfsr.v
// 32-bit Galois LFSR with a configurable feedback polynomial. Produces one new 32-bit sample
// per clock cycle when enabled.

module galois_lfsr #(
    parameter [31:0] POLY = 32'hB4BCD35C,
    parameter [31:0] SEED = 32'hDEADBEEF
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire [31:0] seed_load,
    input  wire        seed_valid,
    output reg  [31:0] out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            out <= SEED;
        else if (seed_valid)
            out <= seed_load;
        else if (en)
            // Galois feedback: shift right, then XOR with POLY whenever the LSB was set.
            out <= {1'b0, out[31:1]} ^ (out[0] ? POLY : 32'b0);
    end
endmodule
