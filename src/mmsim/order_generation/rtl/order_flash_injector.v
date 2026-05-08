// Emits a configurable burst of stress packets onto the order bus, paced by the INJECT_STEP_PERIOD parameter.

module order_flash_injector #(
    parameter [31:0] INJECT_STEP_PERIOD = 32'd500
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        inject_trigger,
    input  wire [31:0] inject_packet,
    input  wire [31:0] inject_count,

    output wire        inject_fire,
    output wire [31:0] inject_packet_out,
    output wire        inject_active,

    input  wire        order_ready
);

    reg [31:0] inject_remaining;
    reg        inject_busy;
    reg [31:0] inject_packet_reg;
    reg        inject_trigger_prev;
    wire       inject_trigger_rise = inject_trigger && !inject_trigger_prev;

    // Paces injection at one packet per INJECT_STEP_PERIOD cycles.
    wire token_valid;
    pacer u_pacer (
        .clk         (clk),
        .rst_n       (rst_n),
        .period      (INJECT_STEP_PERIOD),
        .consume     (inject_fire && order_ready),
        .step_en     (),
        .token_valid (token_valid)
    );

    assign inject_fire = inject_busy && token_valid;

    // Latches a fresh burst on the rising edge of inject_trigger and decrements inject_remaining every accepted token 
    // until the burst is fully drained.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inject_remaining    <= 32'd0;
            inject_busy         <= 1'b0;
            inject_packet_reg   <= 32'd0;
            inject_trigger_prev <= 1'b0;
        end else begin
            inject_trigger_prev <= inject_trigger;
            if (inject_trigger_rise && !inject_busy) begin
                inject_busy       <= 1'b1;
                inject_remaining  <= inject_count;
                inject_packet_reg <= inject_packet;
            end else if (inject_fire && order_ready) begin
                if (inject_remaining <= 32'd1) begin
                    inject_busy      <= 1'b0;
                    inject_remaining <= 32'd0;
                end else begin
                    inject_remaining <= inject_remaining - 32'd1;
                end
            end
        end
    end

    assign inject_active     = inject_busy;
    assign inject_packet_out = inject_packet_reg;

endmodule
