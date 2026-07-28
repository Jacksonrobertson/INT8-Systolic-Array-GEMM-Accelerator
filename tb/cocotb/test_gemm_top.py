"""cocotb constrained-random verification of gemm_top (Phase 3).

Every run drives a complete GEMM through the three AXI-Stream interfaces in
the beat order model/generate_vectors.py defines, and checks every result
beat, every tlast, and the beat count against the Phase 1 golden model
computed on the fly — no pre-generated vector files, so dimensions, data,
stall patterns and quantization constants are all free to randomize.

The DUT is built with +define+SIM_ASSERT, so the SVA set from Phase 2
(AXI-Stream stability, FSM legality, accumulator overflow, output-register
acceptance) is armed under every stimulus this bench generates.

Directed tests pin down the corners this design has already been wrong in
(see docs/PHASE2_RTL.md); test_constrained_random then explores around them.
Reproduce any session with:  python tb/cocotb/run.py --seed <seed>
"""

import os
import sys
from pathlib import Path

import numpy as np

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from axis import AxisMaster, AxisSlave              # noqa: E402
from coverage import Coverage                       # noqa: E402
from model.golden_model import gemm_int8, requantize  # noqa: E402

CLK_NS = 10


# ---- helpers ---------------------------------------------------------------

def _seed():
    return int(os.environ.get("RANDOM_SEED", "0"))


def pack(vec, width):
    mask = (1 << width) - 1
    word = 0
    for lane, v in enumerate(vec.tolist()):
        word |= (int(v) & mask) << (lane * width)
    return word


def w_beat_list(b, n):
    """Weight beats: for nt, for kt, tile columns j=0..n-1 (SPEC 6.1)."""
    k, nn = b.shape
    beats = []
    for nt in range(nn // n):
        for kt in range(k // n):
            tile = b[kt * n:(kt + 1) * n, nt * n:(nt + 1) * n]
            for j in range(n):
                beats.append((pack(tile[:, j], 8), j == n - 1))
    return beats


def a_beat_list(a, nn, n):
    """Activation beats: for nt, for kt, rows r=0..M-1 of block kt."""
    m, k = a.shape
    beats = []
    for _nt in range(nn // n):
        for kt in range(k // n):
            block = a[:, kt * n:(kt + 1) * n]
            for r in range(m):
                beats.append((pack(block[r, :], 8), r == m - 1))
    return beats


def c_expected(c, cq, n, dw_acc=32):
    """Expected result beats: for nt, rows r=0..M-1 of output block nt.
    In quant mode the low n bytes carry data and the upper bits must be 0,
    which packing the int8 row into the full-width word checks implicitly."""
    m, nn = c.shape
    beats = []
    total = (nn // n) * m
    for nt in range(nn // n):
        for r in range(m):
            if cq is not None:
                word = pack(cq[r, nt * n:(nt + 1) * n], 8)
            else:
                word = pack(c[r, nt * n:(nt + 1) * n], dw_acc)
            beats.append((word, len(beats) == total - 1))
    return beats


async def wait_until(clk, cond, limit, what):
    for _ in range(limit):
        if cond():
            return
        await RisingEdge(clk)
    raise AssertionError(f"timeout after {limit} cycles waiting for {what}")


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, units="ns").start())
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.cfg_quant_en.value = 0
    dut.cfg_mult.value = 1
    dut.cfg_shift.value = 0
    dut.s_axis_w_tvalid.value = 0
    dut.s_axis_w_tlast.value = 0
    dut.s_axis_a_tvalid.value = 0
    dut.s_axis_a_tlast.value = 0
    dut.m_axis_c_tready.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def run_gemm(dut, rng, cov, *, m, k, nn, a=None, b=None,
                   stall_w=0.0, stall_a=0.0, stall_out=0.0,
                   quant=False, mult=1, shift=0,
                   sequencing="cold_start", dims_changed=False):
    """Drive one complete GEMM and check it against the golden model."""
    n = len(dut.s_axis_w_tdata) // 8
    assert m % n == 0 and k % n == 0 and nn % n == 0

    nprng = np.random.default_rng(rng.getrandbits(32))
    if a is None:
        a = nprng.integers(-128, 128, size=(m, k)).astype(np.int8)
    if b is None:
        b = nprng.integers(-128, 128, size=(k, nn)).astype(np.int8)

    c = gemm_int8(a, b)
    cq = requantize(c, mult, shift) if quant else None
    expected = c_expected(c, cq, n)

    dut.cfg_m.value = m
    dut.cfg_k.value = k
    dut.cfg_n.value = nn
    dut.cfg_quant_en.value = int(quant)
    dut.cfg_mult.value = mult
    dut.cfg_shift.value = shift

    slave = AxisSlave(dut.clk, dut.m_axis_c_tvalid, dut.m_axis_c_tready,
                      dut.m_axis_c_tdata, dut.m_axis_c_tlast, rng, stall_out)
    slave.start()

    await RisingEdge(dut.clk)
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    wm = AxisMaster(dut.clk, dut.s_axis_w_tvalid, dut.s_axis_w_tready,
                    dut.s_axis_w_tdata, dut.s_axis_w_tlast, rng, stall_w)
    am = AxisMaster(dut.clk, dut.s_axis_a_tvalid, dut.s_axis_a_tready,
                    dut.s_axis_a_tdata, dut.s_axis_a_tlast, rng, stall_a)
    w_beats = w_beat_list(b, n)
    a_beats = a_beat_list(a, nn, n)
    wt = cocotb.start_soon(wm.send(w_beats))
    at = cocotb.start_soon(am.send(a_beats))

    tag = f"M={m} K={k} N={nn} n={n} stall=({stall_w},{stall_a},{stall_out}) " \
          f"quant={quant} mult={mult} shift={shift} seed={_seed()}"
    beats_total = len(w_beats) + len(a_beats) + len(expected)
    budget = int(beats_total * (1 + 8 * max(stall_w, stall_a, stall_out)) * 6) + 2000

    await wait_until(dut.clk, lambda: int(dut.done.value) == 1, budget,
                     f"done ({tag})")
    await wait_until(dut.clk, lambda: len(slave.beats) >= len(expected),
                     budget, f"final result beats ({tag})")
    for _ in range(4):
        await RisingEdge(dut.clk)
    slave.stop()

    assert wt.done() and at.done(), f"input stream not fully consumed ({tag})"
    assert len(slave.beats) == len(expected), \
        f"got {len(slave.beats)} beats, expected {len(expected)} ({tag})"
    for i, ((got, got_last), (exp, exp_last)) in enumerate(zip(slave.beats, expected)):
        assert got == exp, \
            f"beat {i}: got {got:#x}, expected {exp:#x} ({tag})"
        assert got_last == int(exp_last), \
            f"beat {i}: tlast={got_last}, expected {int(exp_last)} ({tag})"

    cov.sample_run(n=n, m=m, k=k, nn=nn, stall_in=max(stall_w, stall_a),
                   stall_out=stall_out, quant=quant, mult=mult, shift=shift,
                   sequencing=sequencing, dims_changed=dims_changed,
                   expected_c=c, expected_q=cq)
    cocotb.log.info("PASS %s (%d result beats)", tag, len(expected))


def auto_qparams(a, b):
    """Scale/shift that land the largest |C| near the top of the INT8 range,
    mirroring model/generate_vectors.py."""
    c = gemm_int8(a, b)
    shift = 31
    cmax = int(np.abs(c).max())
    mult = min((1 << 24) - 1, max(1, (127 * (1 << shift)) // max(cmax, 1)))
    return mult, shift


# ---- directed tests --------------------------------------------------------

@cocotb.test()
async def test_smoke_full_rate(dut):
    """Cold-start sanity: one tile column-block, full rate, raw INT32 out."""
    import random
    rng = random.Random(_seed() ^ 0x5A11)
    cov = Coverage()
    await reset(dut)
    n = len(dut.s_axis_w_tdata) // 8
    await run_gemm(dut, rng, cov, m=2 * n, k=n, nn=n)
    cov.flush()


@cocotb.test()
async def test_m_max_boundary(dut):
    """M = M_MAX = 256: accumulation RAM addressing at its top row."""
    import random
    rng = random.Random(_seed() ^ 0x3FAA)
    cov = Coverage()
    await reset(dut)
    n = len(dut.s_axis_w_tdata) // 8
    await run_gemm(dut, rng, cov, m=256, k=n, nn=n)
    cov.flush()


@cocotb.test()
async def test_worst_case_accumulator(dut):
    """All operands -128: every product is +2^14, K tiles deep, so every
    accumulator sits at its documented worst case (SPEC section 3)."""
    import random
    rng = random.Random(_seed() ^ 0xACC0)
    cov = Coverage()
    await reset(dut)
    n = len(dut.s_axis_w_tdata) // 8
    m, k, nn = 2 * n, 4 * n, n
    a = np.full((m, k), -128, dtype=np.int8)
    b = np.full((k, nn), -128, dtype=np.int8)
    await run_gemm(dut, rng, cov, m=m, k=k, nn=nn, a=a, b=b)
    cov.flush()


@cocotb.test()
async def test_quant_corners(dut):
    """INT8 output stage: identity scale, saturating scale, and a realistic
    scale, chained back-to-back without reset (delayed restarts)."""
    import random
    rng = random.Random(_seed() ^ 0x0DD1)
    cov = Coverage()
    await reset(dut)
    n = len(dut.s_axis_w_tdata) // 8
    m, k, nn = 2 * n, n, n

    # Identity (mult=1, shift=0): output is clamp(relu(acc)); small operands
    # keep some accumulators inside INT8 range so non-trivial values survive.
    nprng = np.random.default_rng(rng.getrandbits(32))
    a = nprng.integers(-4, 5, size=(m, k)).astype(np.int8)
    b = nprng.integers(-4, 5, size=(k, nn)).astype(np.int8)
    await run_gemm(dut, rng, cov, m=m, k=k, nn=nn, a=a, b=b,
                   quant=True, mult=1, shift=0)

    # Saturating: full-range operands with an oversized multiplier.
    for _ in range(rng.randint(2, 10)):
        await RisingEdge(dut.clk)
    await run_gemm(dut, rng, cov, m=m, k=k, nn=nn,
                   quant=True, mult=(1 << 24) - 1, shift=8,
                   sequencing="delayed_restart")

    # Realistic: auto-scaled so the peak lands near 127 (exercises rounding
    # and, with signed products, both saturation and ReLU zeroing).
    nprng = np.random.default_rng(rng.getrandbits(32))
    a = nprng.integers(-128, 128, size=(m, k)).astype(np.int8)
    b = nprng.integers(-128, 128, size=(k, nn)).astype(np.int8)
    mult, shift = auto_qparams(a, b)
    for _ in range(rng.randint(2, 10)):
        await RisingEdge(dut.clk)
    await run_gemm(dut, rng, cov, m=m, k=k, nn=nn, a=a, b=b,
                   quant=True, mult=mult, shift=shift,
                   sequencing="delayed_restart")
    cov.flush()


@cocotb.test()
async def test_bubble_path(dut):
    """M = n with several K tiles: the M < 2n handover path where the
    controller must withhold the last activation row (PHASE2_RTL section 5),
    under moderate stalls on every interface."""
    import random
    rng = random.Random(_seed() ^ 0xB0BB)
    cov = Coverage()
    await reset(dut)
    n = len(dut.s_axis_w_tdata) // 8
    await run_gemm(dut, rng, cov, m=n, k=3 * n, nn=2 * n,
                   stall_w=0.3, stall_a=0.3, stall_out=0.3)
    cov.flush()


@cocotb.test()
async def test_backpressure_torture(dut):
    """Heavy input starvation and output backpressure together — the exact
    combination behind the Phase 2 duplicate-output-beat bug — with the
    quantized output stage enabled on top."""
    import random
    rng = random.Random(_seed() ^ 0x70C7)
    cov = Coverage()
    await reset(dut)
    n = len(dut.s_axis_w_tdata) // 8
    m, k, nn = 2 * n, 2 * n, 3 * n
    nprng = np.random.default_rng(rng.getrandbits(32))
    a = nprng.integers(-128, 128, size=(m, k)).astype(np.int8)
    b = nprng.integers(-128, 128, size=(k, nn)).astype(np.int8)
    mult, shift = auto_qparams(a, b)
    await run_gemm(dut, rng, cov, m=m, k=k, nn=nn, a=a, b=b,
                   stall_w=0.5, stall_a=0.6, stall_out=0.6,
                   quant=True, mult=mult, shift=shift)
    cov.flush()


@cocotb.test()
async def test_back_to_back(dut):
    """Three GEMMs without reset: an immediate restart on new dimensions,
    then single-sided stall runs (input-only, output-only)."""
    import random
    rng = random.Random(_seed() ^ 0xB2B0)
    cov = Coverage()
    await reset(dut)
    n = len(dut.s_axis_w_tdata) // 8
    await run_gemm(dut, rng, cov, m=2 * n, k=2 * n, nn=n)
    await run_gemm(dut, rng, cov, m=n, k=n, nn=2 * n,
                   stall_w=0.3, stall_a=0.3,
                   sequencing="immediate_restart", dims_changed=True)
    for _ in range(rng.randint(3, 12)):
        await RisingEdge(dut.clk)
    await run_gemm(dut, rng, cov, m=4 * n, k=n, nn=n, stall_out=0.4,
                   sequencing="delayed_restart", dims_changed=True)
    cov.flush()


# ---- constrained random ----------------------------------------------------

@cocotb.test()
async def test_constrained_random(dut):
    """Randomized dimensions, data, stall profiles, quantization and restart
    gaps, chained without reset. Count set by RANDOM_COUNT, seeded by
    RANDOM_SEED for exact reproduction."""
    import random
    rng = random.Random(_seed() ^ 0xC0C0)
    cov = Coverage()
    count = int(os.environ.get("RANDOM_COUNT", "20"))
    await reset(dut)
    n = len(dut.s_axis_w_tdata) // 8

    prev_dims, sequencing = None, "cold_start"
    for i in range(count):
        while True:
            m = rng.choice([n, n, 2 * n, 2 * n, 3 * n, 4 * n, 6 * n])
            kt = rng.choice([1, 1, 2, 2, 3, 4])
            nt = rng.choice([1, 1, 2, 2, 3])
            if nt * kt * m <= 1600:
                break
        k, nn = kt * n, nt * n

        stall_w, stall_a, stall_out = rng.choice([
            (0, 0, 0), (0.3, 0.3, 0), (0, 0, 0.3),
            (0.3, 0.3, 0.3), (0.6, 0.6, 0.6),
        ])

        quant = rng.random() < 0.35
        mult, shift = 1, 0
        if quant and rng.random() < 0.8:
            mult = rng.randrange(1, 1 << 24)
            shift = rng.randrange(0, 32)

        await run_gemm(dut, rng, cov, m=m, k=k, nn=nn,
                       stall_w=stall_w, stall_a=stall_a, stall_out=stall_out,
                       quant=quant, mult=mult, shift=shift,
                       sequencing=sequencing,
                       dims_changed=prev_dims not in (None, (m, k, nn)))
        prev_dims = (m, k, nn)
        if rng.random() < 0.5:
            sequencing = "immediate_restart"
        else:
            sequencing = "delayed_restart"
            for _ in range(rng.randint(1, 20)):
                await RisingEdge(dut.clk)
        cocotb.log.info("random run %d/%d complete", i + 1, count)
    cov.flush()
