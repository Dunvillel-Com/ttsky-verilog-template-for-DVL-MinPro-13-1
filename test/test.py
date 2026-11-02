"""
cocotb tests for the DVL MinPro 13-1 Tiny Tapeout port.

A Python "host" plays the role of the RP2040: it serves program ROM and RAM and
swallows char output over the nibble-wide REQ/ACK bus (see docs/info.md).

Opcode numbers are the ones from the original cpu.sv header.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

# --- opcodes used below --------------------------------------------------
SET_A, SET_B = 1, 2
CALL = 24
JMP, RET = 21, 26
ADD_AB, MUL_AB, ADD_A_I = 29, 33, 34
LOAD_A, STORE_A = 57, 59
SET_IJ0, SET_I0F, SET_IFG, RETI = 63, 68, 74, 73
OUT_A, CHAR_A = 75, 81
NOP, STOP = 83, 84


class Host:
    """Serves the CPU's bus. rom: {addr: (inst, data)}, ram: {addr: value}."""

    def __init__(self, dut, rom, ram=None):
        self.dut = dut
        self.rom = rom
        self.ram = ram if ram is not None else {}
        self.chars = []
        self.fetches = []
        self.ack = 0
        self.data = 0

    def _drive(self):
        self.dut.uio_in.value = (self.ack << 5) | (self.data & 0xF)

    def _req(self):
        return (int(self.dut.uio_out.value) >> 4) & 1

    async def _wait_req(self, level):
        while self._req() != level:
            await RisingEdge(self.dut.clk)

    async def recv(self):
        """CPU -> host beat."""
        await self._wait_req(1)
        v = int(self.dut.uio_out.value) & 0xF
        self.ack = 1
        self._drive()
        await self._wait_req(0)
        self.ack = 0
        self._drive()
        return v

    async def send(self, v):
        """Host -> CPU beat: data first, ACK a clock later."""
        await self._wait_req(1)
        self.data = v
        self._drive()
        await RisingEdge(self.dut.clk)
        self.ack = 1
        self._drive()
        await self._wait_req(0)
        self.ack = 0
        self.data = 0
        self._drive()

    async def run(self):
        while True:
            cmd = await self.recv()
            addr = 0
            if cmd in (1, 2, 3):
                for _ in range(4):
                    addr = (addr << 4) | await self.recv()
                addr &= 0x1FFF

            if cmd == 1:  # FETCH
                self.fetches.append(addr)
                inst, data = self.rom.get(addr, (STOP, 0))
                word = (inst << 13) | data
                for i in range(6, -1, -1):
                    await self.send((word >> (4 * i)) & 0xF)
            elif cmd == 2:  # LOAD
                val = self.ram.get(addr, 0)
                for i in range(3, -1, -1):
                    await self.send((val >> (4 * i)) & 0xF)
            elif cmd == 3:  # STORE
                val = 0
                for _ in range(4):
                    val = (val << 4) | await self.recv()
                self.ram[addr] = val & 0x1FFF
            elif cmd == 4:  # CHAR
                val = 0
                for _ in range(3):
                    val = (val << 4) | await self.recv()
                self.chars.append(val & 0x1FF)
            else:
                raise AssertionError(f"unknown bus command {cmd}")


async def start(dut, program):
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    host = Host(dut, {i: p for i, p in enumerate(program)})
    cocotb.start_soon(host.run())
    dut.rst_n.value = 1
    return host


async def wait_fetch(dut, host, addr, limit=40000):
    for _ in range(limit):
        if addr in host.fetches:
            return
        await RisingEdge(dut.clk)
    raise AssertionError(f"never fetched address {addr}; fetches={host.fetches}")


@cocotb.test()
async def test_arith_ram_call_char(dut):
    program = [
        (SET_A, 5),        # 0: A = 5
        (SET_B, 7),        # 1: B = 7
        (ADD_AB, 0),       # 2: A = 12
        (STORE_A, 3),      # 3: RAM[3] = 12
        (SET_A, 0),        # 4: A = 0
        (LOAD_A, 3),       # 5: A = RAM[3] = 12
        (CHAR_A, 0),       # 6: char out 12
        (CALL, 0),         # 7: next jump pushes
        (JMP, 14),         # 8: call 14 (push 9)
        (MUL_AB, 0),       # 9: A = 13 * 7 = 91
        (STORE_A, 4),      # 10: RAM[4] = 91
        (OUT_A, 0),        # 11: O0 = 1
        (STOP, 0),         # 12
        (NOP, 0),          # 13
        (ADD_A_I, 1),      # 14: A = A + 1 = 13
        (RET, 0),          # 15: return to 9
    ]
    host = await start(dut, program)
    await wait_fetch(dut, host, 12)
    await ClockCycles(dut.clk, 300)
    n = len(host.fetches)
    await ClockCycles(dut.clk, 500)

    assert host.fetches == [0, 1, 2, 3, 4, 5, 6, 7, 8, 14, 15, 9, 10, 11, 12]
    assert len(host.fetches) == n, "CPU kept fetching after STOP"
    assert host.ram[3] == 12
    assert host.ram[4] == 91
    assert host.chars == [12]
    assert int(dut.uo_out.value) & 1 == 1


@cocotb.test()
async def test_interrupt(dut):
    program = [
        (SET_IJ0, 8),      # 0: IJ0 = 8
        (SET_I0F, 1),      # 1: enable interrupt 0
        (SET_IFG, 1),      # 2: global enable
        (SET_A, 0),        # 3: A = 0
        (JMP, 4),          # 4: spin
        (NOP, 0), (NOP, 0), (NOP, 0),
        (SET_A, 1),        # 8: handler: A = 1
        (OUT_A, 1),        # 9: O1 = 1
        (RETI, 0),         # 10: return (registers restored, IF_global stays 0)
    ]
    host = await start(dut, program)
    await wait_fetch(dut, host, 4)
    await ClockCycles(dut.clk, 1000)
    assert (int(dut.uo_out.value) >> 1) & 1 == 0

    dut.ui_in.value = 1                      # rising edge on I0
    await wait_fetch(dut, host, 10)
    await ClockCycles(dut.clk, 1500)

    assert (int(dut.uo_out.value) >> 1) & 1 == 1
    i = host.fetches.index(10)
    assert host.fetches[i + 1] == 4, "RETI should resume the interrupted spin loop"

    # IF_global was cleared by the interrupt, so a second edge must be ignored
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 500)
    dut.ui_in.value = 1
    await ClockCycles(dut.clk, 3000)
    assert host.fetches.count(8) == 1
