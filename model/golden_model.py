"""Bit-exact golden model for the INT8 weight-stationary systolic GEMM accelerator.

This module is the single source of truth for the accelerator's numerical
behavior (docs/SPEC.md). It provides:

  - gemm_int8():        functional reference, C = A @ B with INT32 accumulation
  - requantize():       INT32 -> INT8 output stage (ReLU + fixed-point scale)
  - SystolicArraySim:   cycle-level weight-stationary array simulator that
                        reproduces the skewed-wavefront schedule of SPEC §4.2

All arithmetic is two's-complement with explicitly controlled widths so the
results are bit-exact against RTL, not merely "close".
"""

from __future__ import annotations

import numpy as np

INT8_MIN, INT8_MAX = -128, 127
INT32_MIN, INT32_MAX = -(2**31), 2**31 - 1

# Worst-case single product is (-128)*(-128) = 2^14; INT32 holds K such
# products without overflow for any K up to 2^(31-14). See SPEC §3.
K_MAX_NO_OVERFLOW = 2 ** (31 - 14)


def _check_operands(a: np.ndarray, b: np.ndarray) -> None:
    if a.ndim != 2 or b.ndim != 2:
        raise ValueError(f"expected 2-D matrices, got {a.shape} and {b.shape}")
    if a.shape[1] != b.shape[0]:
        raise ValueError(f"inner dimensions differ: {a.shape} @ {b.shape}")
    for name, m in (("A", a), ("B", b)):
        if m.dtype != np.int8:
            raise TypeError(f"{name} must be int8, got {m.dtype}")
    if a.shape[1] > K_MAX_NO_OVERFLOW:
        raise ValueError(
            f"K={a.shape[1]} exceeds the no-overflow bound {K_MAX_NO_OVERFLOW}"
        )


def gemm_int8(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """C = A @ B for int8 operands with int32 accumulation.

    A is (M, K) int8, B is (K, N) int8; returns (M, N) int32. The accumulator
    provably cannot overflow for K <= 2^17 (SPEC §3), which _check_operands
    enforces, so widening to int32 before the matmul is exact.
    """
    _check_operands(a, b)
    c = a.astype(np.int32) @ b.astype(np.int32)
    assert c.min() >= INT32_MIN and c.max() <= INT32_MAX
    return c


def requantize(
    acc: np.ndarray, mult: int, shift: int, relu: bool = True
) -> np.ndarray:
    """INT32 accumulator -> INT8 output stage (SPEC §7).

    y = clamp(round_half_up((max(acc,0) * mult) >> shift), -128, 127)

    mult is a 24-bit unsigned fixed-point multiplier, shift in [0, 31].
    Rounding is round-half-up (add 1 << (shift-1) before the shift), applied
    to the non-negative post-ReLU value; with relu=False, negative inputs use
    the same add-then-arithmetic-shift, which the RTL mirrors exactly.
    """
    if not (0 <= mult < 2**24):
        raise ValueError(f"mult must fit in 24 unsigned bits, got {mult}")
    if not (0 <= shift <= 31):
        raise ValueError(f"shift must be in [0, 31], got {shift}")
    if acc.dtype != np.int32:
        raise TypeError(f"acc must be int32, got {acc.dtype}")

    x = acc.astype(np.int64)
    if relu:
        x = np.maximum(x, 0)
    scaled = x * mult
    if shift > 0:
        scaled = scaled + (1 << (shift - 1))
    y = scaled >> shift  # arithmetic shift on int64
    return np.clip(y, INT8_MIN, INT8_MAX).astype(np.int8)


class SystolicArraySim:
    """Cycle-level simulator of one n x n weight-stationary tile pass.

    Models the SPEC §4.2 schedule explicitly: stationary weights, activations
    entering row i with i cycles of skew and marching east, partial sums
    accumulating southward, results emerging from the bottom edge with column
    j delayed by j cycles. Used to cross-check RTL result *ordering and
    latency*, while gemm_int8() checks values at the functional level.
    """

    def __init__(self, n: int):
        if n < 2:
            raise ValueError("array dimension must be >= 2")
        self.n = n
        self.w = np.zeros((n, n), dtype=np.int8)

    def load_weights(self, w_tile: np.ndarray) -> None:
        if w_tile.shape != (self.n, self.n) or w_tile.dtype != np.int8:
            raise ValueError(f"expected ({self.n},{self.n}) int8 tile")
        self.w = w_tile.copy()

    def run(self, a_block: np.ndarray) -> tuple[np.ndarray, list[list[int]]]:
        """Stream an (M, n) int8 activation block through the loaded tile.

        Returns (results, emergence_log):
          results:        (M, n) int32, equal to a_block @ w_tile
          emergence_log:  per cycle, the list of columns that produced a
                          result that cycle (validates the skewed drain order)
        """
        if a_block.ndim != 2 or a_block.shape[1] != self.n:
            raise ValueError(f"expected (M, {self.n}) block, got {a_block.shape}")
        if a_block.dtype != np.int8:
            raise TypeError(f"a_block must be int8, got {a_block.dtype}")

        n, m = self.n, a_block.shape[0]
        # Pipeline registers between PEs: a flows east, psum flows south.
        a_reg = np.zeros((n, n), dtype=np.int32)
        psum_reg = np.zeros((n, n), dtype=np.int64)
        w = self.w.astype(np.int64)

        results = np.zeros((m, n), dtype=np.int64)
        rows_out = np.zeros(n, dtype=np.int64)  # next result row index per column
        emergence_log: list[list[int]] = []

        # Row i's activations enter at cycle t = row_index + i (skew).
        # Total cycles: skew (n-1) + M rows + vertical depth n.
        total_cycles = (n - 1) + m + n
        for t in range(total_cycles):
            # Combinational view of this cycle's PE outputs, then commit.
            a_in = np.zeros((n, n), dtype=np.int32)
            psum_in = np.zeros((n, n), dtype=np.int64)
            for i in range(n):
                r = t - i  # which activation row is at this PE row's west edge
                a_in[i, 0] = int(a_block[r, i]) if 0 <= r < m else 0
                a_in[i, 1:] = a_reg[i, :-1]
                psum_in[i, :] = psum_reg[i - 1, :] if i > 0 else 0

            emerged: list[int] = []
            # Bottom-edge psum_reg[n-1, j] this cycle carries a finished result
            # for column j when the wavefront for some row has fully drained.
            for j in range(n):
                r = t - (n - 1) - 1 - j  # row index whose column-j sum is ready
                if 0 <= r < m:
                    results[rows_out[j], j] = psum_reg[n - 1, j]
                    rows_out[j] += 1
                    emerged.append(j)
            emergence_log.append(emerged)

            a_reg = a_in.copy()
            psum_reg = psum_in + a_in.astype(np.int64) * w  # PE[i][j] holds B[i, j]: row i = K index, col j = N index

            assert psum_reg.min() >= INT32_MIN and psum_reg.max() <= INT32_MAX, (
                "accumulator exceeded INT32 range (SPEC §3 bound violated)"
            )

        assert (rows_out == m).all(), "drain incomplete: schedule bug"
        return results.astype(np.int32), emergence_log


def gemm_int8_tiled(a: np.ndarray, b: np.ndarray, n: int) -> np.ndarray:
    """Reference for the full tile schedule of SPEC §4.1, built on the
    cycle-level simulator: outer loop over output column-blocks (nt), inner
    loop over K tiles (kt), accumulating into the output block exactly as the
    accumulation RAM does.

    Dimensions must be non-zero multiples of n (the v1 constraint).
    """
    _check_operands(a, b)
    m_dim, k_dim = a.shape
    _, n_dim = b.shape
    for name, d in (("M", m_dim), ("K", k_dim), ("N", n_dim)):
        if d == 0 or d % n != 0:
            raise ValueError(f"{name}={d} is not a non-zero multiple of n={n}")

    sim = SystolicArraySim(n)
    c = np.zeros((m_dim, n_dim), dtype=np.int64)
    for nt in range(n_dim // n):
        for kt in range(k_dim // n):
            sim.load_weights(b[kt * n:(kt + 1) * n, nt * n:(nt + 1) * n])
            partial, _ = sim.run(a[:, kt * n:(kt + 1) * n])
            c[:, nt * n:(nt + 1) * n] += partial
    assert c.min() >= INT32_MIN and c.max() <= INT32_MAX
    return c.astype(np.int32)


def random_matrices(
    m: int, k: int, n: int, seed: int
) -> tuple[np.ndarray, np.ndarray]:
    """Reproducible int8 stimulus over the full [-128, 127] range."""
    rng = np.random.default_rng(seed)
    a = rng.integers(INT8_MIN, INT8_MAX + 1, size=(m, k), dtype=np.int64)
    b = rng.integers(INT8_MIN, INT8_MAX + 1, size=(k, n), dtype=np.int64)
    return a.astype(np.int8), b.astype(np.int8)
