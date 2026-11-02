/*
 * DVL MinPro 13-1 CPU core (Tiny Tapeout port)
 *
 * Same ISA and register set as the original cpu.sv (ops 1..84, same numbers),
 * but restructured so it can live in a Tiny Tapeout tile:
 *
 *  - Plain Verilog-2001 (no logic / always_comb / int).
 *  - No ROM/RAM inside. The core executes exactly ONE instruction per `step`
 *    pulse, using the instruction the sequencer fetched over the external bus.
 *    Memory ops (57-62) and char out (81, 82) are performed by the sequencer
 *    BEFORE `step` is pulsed; the core only consumes `rdata` for loads.
 *  - Interrupts: edges on I0..I4 are synchronised and LATCHED into `pending`
 *    (because an instruction now takes many clocks). At every instruction
 *    boundary (`boundary` pulse) the core takes the lowest pending interrupt
 *    if IF_global is set, and clears all pending flags either way - so an edge
 *    that cannot be serviced is dropped, like the original.
 */
`default_nettype none

module dvl_minpro_core (
    input  wire        clk,
    input  wire        rst,        // active high, synchronous
    input  wire        boundary,   // instruction boundary: service interrupt if allowed
    input  wire        step,       // execute the instruction on instr/inp2
    input  wire [12:0] instr,
    input  wire [12:0] inp2,
    input  wire [12:0] rdata,      // RAM read result (ops 57, 58, 61)
    input  wire [9:0]  I,          // input wires I0..I9
    output reg  [12:0] PC,
    output reg  [12:0] A,
    output reg  [12:0] B,
    output reg  [9:0]  O,          // output wires O0..O9
    output wire        irq_ready   // IF_global && something pending
);

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    reg [12:0] C, D;
    reg        F;

    reg [12:0] stack [0:19];
    reg [4:0]  SC;                 // stack count 0..20
    reg        call;               // "make next call" one-shot flag

    reg [12:0] IJ0, IJ1, IJ2, IJ3, IJ4;   // interrupt jump targets
    reg [4:0]  int_en;                     // I0f..I4f
    reg [4:0]  pending;
    reg        IF_global;

    reg [12:0] TA, TB, TC, TD, TPC;        // saved on interrupt
    reg        TF;

    // ------------------------------------------------------------------
    // Interrupt inputs: 3-stage chain, rising edge = syncBuffer & ~synced
    // (same structure as the original)
    // ------------------------------------------------------------------
    reg [4:0] sync1, sync2, sync3;
    always @(posedge clk) begin
        sync1 <= I[4:0];
        sync2 <= sync1;
        sync3 <= sync2;
    end
    wire [4:0] irq_edge = sync2 & ~sync3;

    assign irq_ready = IF_global & (|pending);

    reg [2:0] irq_id;
    always @* begin
        if      (pending[0]) irq_id = 3'd0;
        else if (pending[1]) irq_id = 3'd1;
        else if (pending[2]) irq_id = 3'd2;
        else if (pending[3]) irq_id = 3'd3;
        else                 irq_id = 3'd4;
    end

    reg [12:0] irq_vec;
    always @* begin
        case (irq_id)
            3'd0:    irq_vec = IJ0;
            3'd1:    irq_vec = IJ1;
            3'd2:    irq_vec = IJ2;
            3'd3:    irq_vec = IJ3;
            default: irq_vec = IJ4;
        endcase
    end

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------
    wire [12:0] pc_inc     = PC + 13'd1;
    wire [4:0]  top_idx    = SC - 5'd1;
    wire [12:0] stack_top  = stack[top_idx];
    wire        can_pop    = (SC != 5'd0);
    wire        can_push   = (SC < 5'd20);
    wire        push_call  = call & can_push;
    wire [15:0] i16        = {6'b000000, I};   // lets I[idx] read 0 for idx > 9

    // ------------------------------------------------------------------
    // Next PC
    // ------------------------------------------------------------------
    reg [12:0] nextPC;
    always @* begin
        nextPC = pc_inc;
        case (instr)
            13'd21: nextPC = inp2;
            13'd22: if (F)              nextPC = inp2;
            13'd23: if (!F)             nextPC = inp2;
            13'd26: if (can_pop)        nextPC = stack_top;
            13'd27: if (F && can_pop)   nextPC = stack_top;
            13'd28: if (!F && can_pop)  nextPC = stack_top;
            13'd73: nextPC = TPC;
            13'd84: nextPC = PC;
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential logic
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            PC <= 13'd0;  SC <= 5'd0;  call <= 1'b0;
            IF_global <= 1'b0;  F <= 1'b0;
            A <= 13'd0;  B <= 13'd0;  C <= 13'd0;  D <= 13'd0;
            O <= 10'd0;
            int_en <= 5'd0;  pending <= 5'd0;
            IJ0 <= 13'd0;  IJ1 <= 13'd0;  IJ2 <= 13'd0;  IJ3 <= 13'd0;  IJ4 <= 13'd0;
        end else begin
            // latch edges (an edge in the same cycle as a clear is kept)
            pending <= (boundary ? 5'd0 : pending) | (irq_edge & int_en);

            if (boundary) begin
                if (irq_ready) begin
                    IF_global <= 1'b0;
                    TA <= A;  TB <= B;  TC <= C;  TD <= D;  TF <= F;
                    TPC <= PC;
                    PC <= irq_vec;
                end
            end else if (step) begin
                PC <= nextPC;

                case (instr)
                    // ---- register moves / literals ----
                    13'd1:  A <= inp2;
                    13'd2:  B <= inp2;
                    13'd3:  C <= inp2;
                    13'd4:  D <= inp2;
                    13'd5:  F <= 1'b0;
                    13'd6:  F <= 1'b1;
                    13'd7:  B <= A;
                    13'd8:  A <= B;
                    13'd9:  A <= C;
                    13'd10: B <= C;
                    13'd11: C <= A;
                    13'd12: C <= B;
                    13'd13: A <= D;
                    13'd14: B <= D;
                    13'd15: D <= A;
                    13'd16: D <= B;
                    13'd17: F <= (A != 13'd0);
                    13'd18: F <= (B != 13'd0);
                    13'd19: A <= {12'd0, F};
                    13'd20: B <= {12'd0, F};

                    // ---- jumps and stack ----
                    13'd21: begin
                        if (push_call) begin SC <= SC + 5'd1; stack[SC] <= pc_inc; end
                        call <= 1'b0;
                    end
                    13'd22: begin
                        if (F && push_call) begin SC <= SC + 5'd1; stack[SC] <= pc_inc; end
                        call <= 1'b0;
                    end
                    13'd23: begin
                        if (!F && push_call) begin SC <= SC + 5'd1; stack[SC] <= pc_inc; end
                        call <= 1'b0;
                    end
                    13'd24: call <= 1'b1;
                    13'd25: if (can_push) begin SC <= SC + 5'd1; stack[SC] <= inp2; end
                    13'd26: if (can_pop)       SC <= SC - 5'd1;
                    13'd27: if (F && can_pop)  SC <= SC - 5'd1;
                    13'd28: if (!F && can_pop) SC <= SC - 5'd1;

                    // ---- math and logic ----
                    13'd29: A <= A + B;
                    13'd30: B <= B + A;
                    13'd31: A <= A - B;
                    13'd32: A <= B - A;
                    13'd33: A <= A * B;
                    13'd34: A <= A + inp2;
                    13'd35: A <= A - inp2;
                    13'd36: A <= inp2 - A;
                    13'd37: A <= A * inp2;
                    13'd38: A <= A | B;
                    13'd39: A <= A & B;
                    13'd40: A <= ~A;
                    13'd41: A <= A << B;
                    13'd42: A <= A >> B;
                    13'd43: A <= A << inp2;
                    13'd44: A <= A >> inp2;
                    13'd45: F <= (A == B);
                    13'd46: F <= (A >  B);
                    13'd47: F <= (A <  B);
                    13'd48: F <= (A >= B);
                    13'd49: F <= (A <= B);
                    13'd50: F <= (A != B);
                    13'd51: F <= (A == inp2);
                    13'd52: F <= (A >  inp2);
                    13'd53: F <= (A <  inp2);
                    13'd54: F <= (A >= inp2);
                    13'd55: F <= (A <= inp2);
                    13'd56: F <= (A != inp2);

                    // ---- RAM loads (the sequencer already fetched rdata) ----
                    13'd57: A <= rdata;
                    13'd58: B <= rdata;
                    13'd61: A <= rdata;
                    // 59, 60, 62 (stores) and 81, 82 (char out) are bus-only

                    // ---- interrupt setup ----
                    13'd63: IJ0 <= inp2;
                    13'd64: IJ1 <= inp2;
                    13'd65: IJ2 <= inp2;
                    13'd66: IJ3 <= inp2;
                    13'd67: IJ4 <= inp2;
                    13'd68: int_en[0] <= (inp2 != 13'd0);
                    13'd69: int_en[1] <= (inp2 != 13'd0);
                    13'd70: int_en[2] <= (inp2 != 13'd0);
                    13'd71: int_en[3] <= (inp2 != 13'd0);
                    13'd72: int_en[4] <= (inp2 != 13'd0);
                    13'd73: begin A <= TA; B <= TB; C <= TC; D <= TD; F <= TF; end
                    13'd74: IF_global <= (inp2 != 13'd0);

                    // ---- I/O (index > 9 is ignored on write, reads 0) ----
                    13'd75: if (inp2[3:0] < 4'd10) O[inp2[3:0]] <= (A[9:0] != 10'd0);
                    13'd76: if (inp2[3:0] < 4'd10) O[inp2[3:0]] <= (B[9:0] != 10'd0);
                    13'd77: if (B[3:0]    < 4'd10) O[B[3:0]]    <= (A[9:0] != 10'd0);
                    13'd78: A <= {12'd0, i16[inp2[3:0]]};
                    13'd79: B <= {12'd0, i16[inp2[3:0]]};
                    13'd80: A <= {12'd0, i16[B[3:0]]};

                    // 83 NOP, 84 STOP (nextPC = PC), anything else: nothing
                    default: ;
                endcase
            end
        end
    end

endmodule
