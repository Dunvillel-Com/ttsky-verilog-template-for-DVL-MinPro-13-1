/*
 * Tiny Tapeout wrapper for the DVL MinPro 13-1 CPU.
 *
 * Pin map
 *   ui_in[7:0]   I0..I7   (I0..I4 are the interrupt inputs; I8, I9 read as 0)
 *   uo_out[7:0]  O0..O7
 *   uio[3:0]     bus data nibble D[3:0]   (bidirectional)
 *   uio[4]       REQ  (out)
 *   uio[5]       ACK  (in)
 *   uio[6]       O8   (out)
 *   uio[7]       O9   (out)
 *
 * Per instruction the sequencer does:
 *   DECIDE -> FETCH (bus) -> [MEM op (bus)] -> EXEC (core.step) -> DECIDE ...
 * See docs/info.md for the bus protocol.
 */
`default_nettype none

module tt_um_dvl_minpro_cpu (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    wire rst = ~rst_n;

    // ------------------------------------------------------------------
    // Core + bus
    // ------------------------------------------------------------------
    wire [12:0] PC, A, B;
    wire [9:0]  O;
    wire        irq_ready;
    wire [25:0] fetch_word;
    wire [12:0] rd_word;
    wire [12:0] instr = fetch_word[25:13];
    wire [12:0] inp2  = fetch_word[12:0];

    localparam [2:0] S_DECIDE = 3'd0, S_FGO = 3'd1, S_FWAIT = 3'd2,
                     S_MGO    = 3'd3, S_MWAIT = 3'd4, S_EXEC = 3'd5;
    localparam [1:0] K_FETCH = 2'd0, K_LOAD = 2'd1, K_STORE = 2'd2, K_CHAR = 2'd3;

    reg  [2:0] st;
    reg        halted;
    wire       x_done;

    wire boundary = (st == S_DECIDE);
    wire step     = (st == S_EXEC);

    dvl_minpro_core core (
        .clk(clk), .rst(rst),
        .boundary(boundary), .step(step),
        .instr(instr), .inp2(inp2), .rdata(rd_word),
        .I({2'b00, ui_in}),
        .PC(PC), .A(A), .B(B), .O(O),
        .irq_ready(irq_ready)
    );

    // ------------------------------------------------------------------
    // Decode of the memory-type instructions
    // ------------------------------------------------------------------
    wire is_load  = (instr == 13'd57) | (instr == 13'd58) | (instr == 13'd61);
    wire is_store = (instr == 13'd59) | (instr == 13'd60) | (instr == 13'd62);
    wire is_char  = (instr == 13'd81) | (instr == 13'd82);
    wire is_mem   = is_load | is_store | is_char;

    wire fetch_phase = (st == S_FGO) | (st == S_FWAIT);
    wire b_addr      = (instr == 13'd61) | (instr == 13'd62);        // RAM[B]

    wire [1:0]  x_kind  = fetch_phase ? K_FETCH :
                          is_load     ? K_LOAD  :
                          is_store    ? K_STORE : K_CHAR;
    wire [12:0] x_addr  = fetch_phase ? PC : (b_addr ? B : inp2);
    wire [12:0] mem_wd  = (instr == 13'd60) ? B : A;
    wire [12:0] chr_wd  = {4'b0000, ((instr == 13'd81) ? A[8:0] : B[8:0])};
    wire [12:0] x_wdata = is_char ? chr_wd : mem_wd;
    wire        x_start = (st == S_FGO) | ((st == S_MGO) & is_mem);

    wire [3:0] bus_dout;
    wire       bus_doe, bus_req;

    dvl_bus bus (
        .clk(clk), .rst(rst),
        .start(x_start), .kind(x_kind), .addr(x_addr), .wdata(x_wdata),
        .done(x_done), .fetch_word(fetch_word), .rd_word(rd_word),
        .din(uio_in[3:0]), .ack_raw(uio_in[5]),
        .dout(bus_dout), .doe(bus_doe), .req(bus_req)
    );

    // ------------------------------------------------------------------
    // Sequencer
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            st     <= S_DECIDE;
            halted <= 1'b0;
        end else begin
            case (st)
                S_DECIDE: begin
                    // `boundary` is high here: the core takes a pending
                    // interrupt this cycle if irq_ready.
                    if (irq_ready)        halted <= 1'b0;
                    else if (!halted)     st <= S_FGO;
                end
                S_FGO:   st <= S_FWAIT;
                S_FWAIT: if (x_done) st <= S_MGO;
                S_MGO:   st <= is_mem ? S_MWAIT : S_EXEC;
                S_MWAIT: if (x_done) st <= S_EXEC;
                S_EXEC: begin
                    if (instr == 13'd84) halted <= 1'b1;   // STOP: wait for an interrupt
                    st <= S_DECIDE;
                end
                default: st <= S_DECIDE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Pins
    // ------------------------------------------------------------------
    assign uo_out  = O[7:0];
    assign uio_out = {O[9], O[8], 1'b0, bus_req, bus_dout};
    assign uio_oe  = {2'b11, 1'b0, 1'b1, {4{bus_doe}}};

    wire _unused = &{ena, uio_in[7:6], uio_in[4], 1'b0};

endmodule
