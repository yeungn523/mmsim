///
/// @file order_fifo.v
/// @brief Single-clock FIFO wrapper around the Altera SCFIFO macro for the order arbiter to matching engine handoff.
///

module order_fifo #(
    parameter DATA_WIDTH         = 32,                   ///< Width of the FIFO data path.
    parameter DEPTH              = 256,                  ///< Number of entries in the FIFO.
    parameter ALMOST_FULL_THRESH = 16                    ///< Free-slot threshold below which almost_full asserts.
)(
    input  wire                  clk,                    ///< System clock.
    input  wire                  rst_n,                  ///< Active-low asynchronous reset.

    input  wire                  wr_en,                  ///< Write enable from the order arbiter.
    input  wire [DATA_WIDTH-1:0] din,                    ///< Order packet payload to enqueue.
    output wire                  full,                   ///< Asserts when the FIFO has no free entries.
    output wire                  almost_full,            ///< Asserts when free entries fall below ALMOST_FULL_THRESH.

    input  wire                  rd_en,                  ///< Read enable from the matching engine front end.
    output wire [DATA_WIDTH-1:0] dout,                   ///< Order packet payload at the FIFO head.
    output wire                  empty                   ///< Asserts when no entries are available to read.
);
    wire [$clog2(DEPTH)-1:0] usedw;

    scfifo #(
        .add_ram_output_register ("OFF"),
        .intended_device_family  ("Cyclone V"),
        .lpm_numwords            (DEPTH),
        .lpm_showahead           ("OFF"),
        .lpm_type                ("scfifo"),
        .lpm_width               (DATA_WIDTH),
        .lpm_widthu              ($clog2(DEPTH)),
        .overflow_checking       ("ON"),
        .underflow_checking      ("ON"),
        .use_eab                 ("ON")
    ) u_scfifo (
        .clock        (clk),
        .aclr         (~rst_n),
        .wrreq        (wr_en),
        .data         (din),
        .rdreq        (rd_en),
        .q            (dout),
        .full         (full),
        .empty        (empty),
        .usedw        (usedw),
        .almost_full  (),
        .almost_empty (),
        .sclr         ()
    );

    assign almost_full = (usedw >= (DEPTH - ALMOST_FULL_THRESH));

endmodule
