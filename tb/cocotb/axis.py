"""AXI-Stream bus-functional models for the cocotb bench.

Both models obey SPEC section 6.1 from the testbench side: once tvalid is
raised, tdata/tlast are held and tvalid stays high until tready completes the
handshake, and tvalid never waits on tready. The DUT's compiled-in SVAs check
the same rules against us, so a buggy BFM fails the run rather than silently
producing an invalid stimulus.

Stall injection: each model takes a per-beat gap probability; a gap lasts a
random 1..MAX_GAP cycles so heavy settings produce bursty traffic, not just a
slower uniform rate.
"""

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

MAX_GAP = 8


class AxisMaster:
    """Drives one inbound AXI-Stream (weights or activations)."""

    def __init__(self, clk, tvalid, tready, tdata, tlast, rng, stall_prob=0.0):
        self.clk = clk
        self.tvalid = tvalid
        self.tready = tready
        self.tdata = tdata
        self.tlast = tlast
        self.rng = rng
        self.stall_prob = stall_prob
        self.sent = 0

    async def send(self, beats):
        """Send [(data, last), ...]; returns once every beat is accepted."""
        self.tvalid.value = 0
        for data, last in beats:
            if self.stall_prob > 0 and self.rng.random() < self.stall_prob:
                self.tvalid.value = 0
                for _ in range(self.rng.randint(1, MAX_GAP)):
                    await RisingEdge(self.clk)
            self.tvalid.value = 1
            self.tdata.value = data
            self.tlast.value = int(last)
            while True:
                await ReadOnly()
                ready = int(self.tready.value)
                await RisingEdge(self.clk)
                if ready:
                    break
            self.sent += 1
        self.tvalid.value = 0
        self.tlast.value = 0


class AxisSlave:
    """Drives tready with random backpressure and captures accepted beats."""

    def __init__(self, clk, tvalid, tready, tdata, tlast, rng, stall_prob=0.0):
        self.clk = clk
        self.tvalid = tvalid
        self.tready = tready
        self.tdata = tdata
        self.tlast = tlast
        self.rng = rng
        self.stall_prob = stall_prob
        self.beats = []
        self._task = None
        self._gap = 0

    def start(self):
        self._task = cocotb.start_soon(self._run())

    def stop(self):
        if self._task is not None:
            self._task.kill()
            self._task = None
        self.tready.value = 0

    async def _run(self):
        while True:
            if self._gap > 0:
                self._gap -= 1
                ready = 0
            elif self.stall_prob > 0 and self.rng.random() < self.stall_prob:
                self._gap = self.rng.randint(0, MAX_GAP - 1)
                ready = 0
            else:
                ready = 1
            self.tready.value = ready
            await ReadOnly()
            if ready and int(self.tvalid.value):
                self.beats.append((int(self.tdata.value), int(self.tlast.value)))
            await RisingEdge(self.clk)
