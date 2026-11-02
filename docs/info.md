<!---
This file is used to generate your project datasheet.
-->

## How it works

The DVL MinPro 13-1 is a 13-bit, MISC-style CPU: registers A, B (math), C, D (work), F (condition flag),
a 20-slot hardware stack, five software-configurable interrupts and the 84-op ISA from the original design
(opcode numbers are unchanged).

A Tiny Tapeout tile has no room for the 8192 x 26-bit program ROM or the 8192 x 13-bit RAM, and only 24 pins,
so program memory, RAM and the character output live **off-chip** and are reached through one 4-bit,
fully handshaked bus. The host is typically the RP2040 on the Tiny Tapeout demo board.

Each instruction is: fetch over the bus -> (optional RAM / char transaction) -> execute on-chip.

### Pin map

| Pin | Function |
|---|---|
| `ui_in[7:0]` | I0..I7 (I0..I4 are the interrupt inputs; I8, I9 always read 0) |
| `uo_out[7:0]` | O0..O7 |
| `uio[3:0]` | Bus data nibble D[3:0], bidirectional |
| `uio[4]` | REQ, output |
| `uio[5]` | ACK, input (host must keep it low while REQ is low) |
| `uio[6]`, `uio[7]` | O8, O9, outputs |

### Bus handshake (one nibble = one "beat")

* CPU -> host: CPU drives D, raises REQ. Host samples D, raises ACK. CPU drops REQ. Host drops ACK.
* Host -> CPU: CPU releases D, raises REQ. Host drives D, then raises ACK. CPU samples D, drops REQ.
  Host drops ACK and stops driving D.

The CPU waits for every edge, so the host can be as slow as it likes. ACK is synchronised inside the chip.

### Transactions

All numbers are sent most-significant nibble first. The first beat of every transaction is a command nibble.

| Command | CPU sends | Host replies |
|---|---|---|
| `1` FETCH | cmd, address (4 nibbles) | 7 nibbles = one `prog.hex` word `{2'b0, inst[12:0], data[12:0]}` |
| `2` LOAD | cmd, address (4 nibbles) | 4 nibbles = 13-bit RAM word |
| `3` STORE | cmd, address (4 nibbles), data (4 nibbles) | nothing |
| `4` CHAR | cmd, 3 nibbles = 9-bit character | nothing; delay the last ACK to act as "busy" |

Addresses are 13 bits sent as 4 nibbles (`{3'b0, a[12]}`, `a[11:8]`, `a[7:4]`, `a[3:0]`).
A 26-bit program word is exactly the 7-hex-digit entry the original `prog.hex` used, so the host can stream those
lines unchanged.

### Differences from the original `cpu.sv`

* **Interrupts** are latched. An edge on I0..I4 sets a pending flag (if that interrupt's flag is enabled); at the next
  instruction boundary the lowest pending interrupt is taken if the global flag is set, and all pending flags are cleared.
  Latency is therefore up to one instruction (tens of clocks), not one clock.
* **STOP (op 84)** halts without touching the bus; an interrupt can still wake it.
* **`I[x]` / `O[x]` with x > 9** read 0 / are ignored (the original read an undefined value for reads).
* **I8, I9 are not wired** to pins (read 0); O8 and O9 are on `uio[6]`, `uio[7]`.
* Execution is multi-clock (roughly 12 bus beats per instruction plus 9 more for RAM ops).
* CHAR output uses the bus instead of the separate `char_data`/`char_strobe`/`char_busy` wires.

## How to test

1. Reset with `rst_n` low for several clocks, keep ACK low, release reset.
2. Run a host that serves the bus, e.g. on the RP2040: wait for REQ, read/write nibbles per the table above, handshake with ACK.
3. Load a program (the opcode/operand words from your assembler) into the host's "ROM" array and watch O0..O9.

A cocotb test in `test/` contains a Python host model and two small programs (arithmetic + call/return + RAM + char out,
and an interrupt test).

## External hardware

A host that implements the bus (the RP2040 on the Tiny Tapeout demo board works; so does any microcontroller or FPGA
with 6 free GPIOs), plus whatever you want on the I and O wires (LEDs, buttons).
