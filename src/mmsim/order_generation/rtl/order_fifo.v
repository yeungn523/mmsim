// Buffers order packets between the arbiter and matching engine in a single-clock SCFIFO.

module order_fifo #(
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 256,
    parameter ALMOST_FULL_THRESH = 16
)(
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    output wire                  full,

    input  wire                  rd_en,
    // Holds the head-of-FIFO packet; valid combinationally while !empty.
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  almost_full,
    output wire                  empty
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
