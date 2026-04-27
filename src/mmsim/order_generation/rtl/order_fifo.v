///
/// @file order_fifo.v
/// @brief Single-clock SCFIFO wrapper that buffers order packets between the arbiter and the matching engine.
///

module order_fifo #(
    parameter DATA_WIDTH = 32,                           ///< Width of the FIFO data path.
    parameter DEPTH      = 256,                          ///< Number of entries in the FIFO.
    parameter ALMOST_FULL_THRESH = 16
)(
    input  wire                  clk,                    ///< System clock.
    input  wire                  rst_n,                  ///< Active-low asynchronous reset.

    input  wire                  wr_en,                  ///< Write enable from the order arbiter.
    input  wire [DATA_WIDTH-1:0] din,                    ///< Order packet payload to enqueue.
    output wire                  full,                   ///< Asserts when the FIFO has no free entries.

    input  wire                  rd_en,                  ///< Read enable from the downstream consumer.
    output wire [DATA_WIDTH-1:0] dout,                   ///< Head-of-FIFO packet, valid combinationally while !empty.
    output wire                  almost_full,
    output wire                  empty                   ///< Asserts when no entries are available to read.
);

    wire [$clog2(DEPTH)-1:0] fifo_usedw;
    assign almost_full = (fifo_usedw >= (DEPTH - ALMOST_FULL_THRESH));

    scfifo #(
        .add_ram_output_register ("OFF"),
        .intended_device_family  ("Cyclone V"),
        .lpm_numwords            (DEPTH),
        .lpm_showahead           ("ON"),
        .lpm_type                ("scfifo"),
        .lpm_width               (DATA_WIDTH),
        .lpm_widthu              ($clog2(DEPTH)),
        .overflow_checking       ("ON"),
        .underflow_checking      ("ON"),
        .use_eab                 ("ON")
    ) u_scfifo (
        .clock        (clk),
        .aclr         (~rst_n),
        .sclr         (1'b0),
        .wrreq        (wr_en),
        .data         (din),
        .rdreq        (rd_en),
        .q            (dout),
        .full         (full),
        .empty        (empty),
        .eccstatus    (),
        .usedw        (fifo_usedw),
        .almost_full  (),
        .almost_empty ()
    );

endmodule
