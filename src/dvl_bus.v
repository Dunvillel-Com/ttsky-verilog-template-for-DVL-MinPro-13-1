/*
 * Nibble-serial, fully handshaked bus master.
 *
 * Tiny Tapeout only gives 24 pins, so program memory, RAM and the character
 * output all go through one 4-bit data bus (uio[3:0]) with a REQ/ACK pair.
 * Every nibble ("beat") uses a 4-phase handshake, so the host may take as long
 * as it likes - the CPU simply waits.
 *
 *   write beat (CPU -> host):  CPU drives D and raises REQ; host samples D and
 *                              raises ACK; CPU drops REQ; host drops ACK.
 *   read beat  (host -> CPU):  CPU releases D and raises REQ; host drives D and
 *                              raises ACK; CPU samples D and drops REQ; host
 *                              drops ACK and releases D.
 *
 * Transactions (all values MSB nibble first):
 *   FETCH  W: 1, A[12:0] as 4 nibbles            R: 7 nibbles = 26-bit {inst,data}
 *   LOAD   W: 2, A[12:0] as 4 nibbles            R: 4 nibbles = 13-bit word
 *   STORE  W: 3, A[12:0] as 4 nibbles, data as 4 nibbles
 *   CHAR   W: 4, 3 nibbles = 9-bit char (last ACK may be delayed = "busy")
 *
 * The `addr`, `wdata` and `kind` inputs must be held stable while a
 * transaction is running (the sequencer does this).
 */
`default_nettype none

module dvl_bus (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,        // 1-cycle pulse, only when idle
    input  wire [1:0]  kind,
    input  wire [12:0] addr,
    input  wire [12:0] wdata,
    output reg         done,         // 1-cycle pulse when transaction completed
    output reg  [25:0] fetch_word,   // {instruction[12:0], data[12:0]}
    output reg  [12:0] rd_word,      // RAM read result

    input  wire [3:0]  din,          // raw pad inputs
    input  wire        ack_raw,
    output reg  [3:0]  dout,
    output reg         doe,
    output reg         req
);

    localparam [1:0] K_FETCH = 2'd0, K_LOAD = 2'd1, K_STORE = 2'd2, K_CHAR = 2'd3;
    localparam [2:0] H_IDLE = 3'd0, H_SETUP = 3'd1, H_ARM = 3'd2,
                     H_WAIT = 3'd3, H_REL = 3'd4;

    // ACK is asynchronous to our clock
    reg [1:0] ack_s;
    reg [3:0] din_q;
    always @(posedge clk) begin
        ack_s <= {ack_s[0], ack_raw};
        din_q <= din;
    end
    wire ack = ack_s[1];

    reg [2:0] hs;
    reg [3:0] beat;

    reg [3:0] last;
    always @* begin
        case (kind)
            K_FETCH: last = 4'd11;
            K_LOAD:  last = 4'd8;
            K_STORE: last = 4'd8;
            default: last = 4'd3;
        endcase
    end

    wire rd_beat = ((kind == K_FETCH) || (kind == K_LOAD)) && (beat >= 4'd5);

    // nibble to put on the bus for the current write beat
    reg [3:0] wnib;
    always @* begin
        wnib = 4'd0;
        if (beat == 4'd0) begin
            wnib = {2'b00, kind} + 4'd1;             // command 1..4
        end else if (kind == K_CHAR) begin
            case (beat[1:0])
                2'd1:    wnib = wdata[11:8];
                2'd2:    wnib = wdata[7:4];
                default: wnib = wdata[3:0];
            endcase
        end else if (beat <= 4'd4) begin
            case (beat[1:0])
                2'd1:    wnib = {3'b000, addr[12]};
                2'd2:    wnib = addr[11:8];
                2'd3:    wnib = addr[7:4];
                default: wnib = addr[3:0];           // beat 4
            endcase
        end else begin
            case (beat[2:0])
                3'd5:    wnib = {3'b000, wdata[12]};
                3'd6:    wnib = wdata[11:8];
                3'd7:    wnib = wdata[7:4];
                default: wnib = wdata[3:0];          // beat 8
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            hs   <= H_IDLE;
            beat <= 4'd0;
            done <= 1'b0;
            req  <= 1'b0;
            doe  <= 1'b0;
            dout <= 4'd0;
        end else begin
            done <= 1'b0;
            case (hs)
                H_IDLE: begin
                    if (start) begin
                        beat <= 4'd0;
                        hs   <= H_SETUP;
                    end
                end

                // present data / bus direction while REQ is still low
                H_SETUP: begin
                    dout <= wnib;
                    doe  <= ~rd_beat;
                    hs   <= H_ARM;
                end

                // then raise REQ one cycle later
                H_ARM: begin
                    req <= 1'b1;
                    hs  <= H_WAIT;
                end

                H_WAIT: begin
                    if (ack) begin
                        if (rd_beat) begin
                            if (kind == K_FETCH) fetch_word <= {fetch_word[21:0], din_q};
                            else                 rd_word    <= {rd_word[8:0],    din_q};
                        end
                        req <= 1'b0;
                        hs  <= H_REL;
                    end
                end

                H_REL: begin
                    if (!ack) begin
                        if (beat == last) begin
                            done <= 1'b1;
                            doe  <= 1'b0;
                            hs   <= H_IDLE;
                        end else begin
                            beat <= beat + 4'd1;
                            hs   <= H_SETUP;
                        end
                    end
                end

                default: hs <= H_IDLE;
            endcase
        end
    end

endmodule
