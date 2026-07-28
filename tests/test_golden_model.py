"""Golden-model self-checks.

The functional model (gemm_int8) is checked against NumPy int64 math; the
cycle-level simulator and tile schedule are checked against the functional
model. This chain is what makes the golden model trustworthy as the RTL
reference.
"""

import numpy as np
import pytest

from model.golden_model import (
    INT8_MAX,
    INT8_MIN,
    SystolicArraySim,
    gemm_int8,
    gemm_int8_tiled,
    random_matrices,
    requantize,
)


@pytest.mark.parametrize("m,k,n,seed", [
    (4, 4, 4, 0),
    (8, 8, 8, 1),
    (16, 32, 8, 2),
    (64, 128, 64, 3),
    (4, 512, 4, 4),
])
def test_gemm_matches_int64_reference(m, k, n, seed):
    a, b = random_matrices(m, k, n, seed)
    c = gemm_int8(a, b)
    ref = a.astype(np.int64) @ b.astype(np.int64)
    assert c.dtype == np.int32
    assert np.array_equal(c.astype(np.int64), ref)


def test_gemm_worst_case_no_overflow():
    # All-(-128) operands maximize every product; K chosen large.
    k = 1024
    a = np.full((2, k), INT8_MIN, dtype=np.int8)
    b = np.full((k, 2), INT8_MIN, dtype=np.int8)
    c = gemm_int8(a, b)
    assert (c == 16384 * k).all()


def test_gemm_rejects_bad_inputs():
    a, b = random_matrices(4, 4, 4, 0)
    with pytest.raises(TypeError):
        gemm_int8(a.astype(np.int16), b)
    with pytest.raises(ValueError):
        gemm_int8(a, b[:3, :])


@pytest.mark.parametrize("n", [2, 4, 8])
@pytest.mark.parametrize("m", [1, 4, 33])
def test_systolic_sim_matches_functional(n, m):
    a, b = random_matrices(m, n, n, seed=100 * n + m)
    sim = SystolicArraySim(n)
    sim.load_weights(b)
    result, log = sim.run(a)
    assert np.array_equal(result, gemm_int8(a, b))
    # Each of the M*n results emerges exactly once.
    assert sum(len(cols) for cols in log) == m * n


@pytest.mark.parametrize("n", [4, 8])
def test_systolic_sim_emergence_schedule(n):
    """Column j's first result appears exactly j cycles after column 0's
    (the output skew of SPEC §4.2), and results per column are in row order."""
    m = 5
    a, b = random_matrices(m, n, n, seed=42)
    sim = SystolicArraySim(n)
    sim.load_weights(b)
    _, log = sim.run(a)
    first = {}
    for t, cols in enumerate(log):
        for j in cols:
            first.setdefault(j, t)
    for j in range(n):
        assert first[j] == first[0] + j


@pytest.mark.parametrize("m,k,n,arr,seed", [
    (4, 4, 4, 4, 10),
    (8, 12, 8, 4, 11),
    (16, 16, 16, 8, 12),
    (8, 24, 8, 8, 13),
])
def test_tiled_schedule_matches_functional(m, k, n, arr, seed):
    a, b = random_matrices(m, k, n, seed)
    assert np.array_equal(gemm_int8_tiled(a, b, arr), gemm_int8(a, b))


def test_tiled_rejects_non_multiple_dims():
    a, b = random_matrices(6, 8, 8, 0)
    with pytest.raises(ValueError):
        gemm_int8_tiled(a, b, 4)


class TestRequantize:
    def test_relu_zeroes_negatives(self):
        acc = np.array([-1000, -1, 0, 1, 1000], dtype=np.int32)
        out = requantize(acc, mult=1 << 8, shift=8, relu=True)
        assert out[0] == 0 and out[1] == 0
        assert out[3] == 1

    def test_identity_scale(self):
        acc = np.arange(0, 128, dtype=np.int32)
        out = requantize(acc, mult=1, shift=0, relu=True)
        assert np.array_equal(out, acc.astype(np.int8))

    def test_saturation(self):
        acc = np.array([10_000_000], dtype=np.int32)
        assert requantize(acc, mult=1, shift=0)[0] == INT8_MAX

    def test_round_half_up(self):
        # 3 * 1 >> 1 with rounding: (3 + 1) >> 1 = 2 (2.5 gets... 1.5 -> 2)
        acc = np.array([1, 2, 3], dtype=np.int32)
        out = requantize(acc, mult=1, shift=1)
        assert out.tolist() == [1, 1, 2]  # 0.5->1, 1.0->1, 1.5->2

    def test_bounds_checked(self):
        acc = np.zeros(1, dtype=np.int32)
        with pytest.raises(ValueError):
            requantize(acc, mult=1 << 24, shift=0)
        with pytest.raises(ValueError):
            requantize(acc, mult=1, shift=32)


def test_vector_generation(tmp_path):
    """generate_vectors output must round-trip back to the golden result."""
    from model.generate_vectors import emit_case

    m, k, n, arr, seed = 8, 12, 8, 4, 3
    emit_case(tmp_path, "case", m, k, n, arr, seed)
    a, b = random_matrices(m, k, n, seed)
    c = gemm_int8(a, b)

    c_lines = (tmp_path / "case" / "c.memh").read_text().split()
    # Unpack beat order: for nt, rows 0..M-1 of that output column-block.
    idx = 0
    for nt in range(n // arr):
        for r in range(m):
            word = int(c_lines[idx], 16)
            for lane in range(arr):
                v = (word >> (32 * lane)) & 0xFFFFFFFF
                v = v - (1 << 32) if v >= (1 << 31) else v
                assert v == c[r, nt * arr + lane]
            idx += 1
