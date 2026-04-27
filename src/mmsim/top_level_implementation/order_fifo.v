// order_fifo.v
// Single-clock FIFO wrapper around Altera SCFIFO macro
// Write port: order_arbiter
// Read port:  matching_engine_top
module order_fifo #(
    parameter DATA_WIDTH         = 32,
    parameter DEPTH              = 256,
    parameter ALMOST_FULL_THRESH = 16
)(
    input  wire                  clk,
    input  wire                  rst_n,
    // Write port
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] din,
    output wire                  full,
    output wire                  almost_full,
    // Read port
    input  wire                  rd_en,
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  empty
);
    wire [$clog2(DEPTH)-1:0] usedw;

    scfifo #(
        .add_ram_output_register ("ON"),
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
        .sclr         (),
        .eccstatus    ()
    );

    assign almost_full = (usedw >= (DEPTH - ALMOST_FULL_THRESH));

endmodule