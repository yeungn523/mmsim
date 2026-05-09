// Generates a periodic step_en strobe and a latched token_valid credit that holds across blocked cycles.

module pacer (
    input  wire        clk,
    input  wire        rst_n,

    // Sets the strobe interval; 0 holds both outputs low.
    input  wire [31:0] period,

    // Clears token_valid on accept; ties to 1'b0 when only step_en is needed.
    input  wire        consume,

    output wire        step_en,
    output wire        token_valid
);

    reg [31:0] counter;
    assign step_en = (period > 32'd0) && (counter >= period);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            counter <= 32'd0;
        else if (step_en)
            counter <= 32'd0;
        else
            counter <= counter + 32'd1;
    end

    reg allow;
    assign token_valid = allow;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            allow <= 1'b0;
        else if (step_en)
            allow <= 1'b1;
        else if (consume)
            allow <= 1'b0;
    end

endmodule
