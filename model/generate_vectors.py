"""Generate stimulus/expected test-vector files for the RTL testbench.

Emits, per test case, into vectors/<name>/:
  a.memh        activation matrix, one row-slice (n int8, hex, MSB-first
                lane n-1..0) per line, in s_axis_a beat order (SPEC §6.1)
  w.memh        weight tiles, one tile column (n int8) per line, in
                s_axis_w beat order
  c.memh        expected results, one row-slice (n int32) per line, in
                m_axis_c beat order
  params.txt    M K N n seed

Usage:  python -m model.generate_vectors [--out vectors]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from model.golden_model import gemm_int8, random_matrices

# (name, M, K, N, n, seed) — dims must be non-zero multiples of n.
DEFAULT_CASES = [
    ("smoke_4x4", 4, 4, 4, 4, 1),
    ("tall_4x4", 16, 4, 4, 4, 2),
    ("multi_tile_4x4", 8, 12, 8, 4, 3),
    ("smoke_8x8", 8, 8, 8, 8, 4),
    ("large_8x8", 64, 32, 16, 8, 5),
]


def _pack_hex(row: np.ndarray, width_bits: int) -> str:
    """Pack a lane vector into one hex word, lane 0 in the LSBs."""
    mask = (1 << width_bits) - 1
    word = 0
    for lane, v in enumerate(row.tolist()):
        word |= (int(v) & mask) << (lane * width_bits)
    return f"{word:0{len(row) * width_bits // 4}x}"


def emit_case(out_dir: Path, name: str, m: int, k: int, nn: int, n: int, seed: int) -> None:
    a, b = random_matrices(m, k, nn, seed)
    c = gemm_int8(a, b)

    case_dir = out_dir / name
    case_dir.mkdir(parents=True, exist_ok=True)

    # Weight beats: for nt, for kt, tile columns j=0..n-1, each beat is
    # the column vector B[kt*n:(kt+1)*n, nt*n + j].
    w_lines = []
    for nt in range(nn // n):
        for kt in range(k // n):
            tile = b[kt * n:(kt + 1) * n, nt * n:(nt + 1) * n]
            for j in range(n):
                w_lines.append(_pack_hex(tile[:, j], 8))

    # Activation beats: for nt, for kt, rows r=0..M-1 of column-block kt.
    a_lines = []
    for _nt in range(nn // n):
        for kt in range(k // n):
            block = a[:, kt * n:(kt + 1) * n]
            for r in range(m):
                a_lines.append(_pack_hex(block[r, :], 8))

    # Result beats: for nt, rows r=0..M-1 of output column-block nt.
    c_lines = []
    for nt in range(nn // n):
        block = c[:, nt * n:(nt + 1) * n]
        for r in range(m):
            c_lines.append(_pack_hex(block[r, :], 32))

    (case_dir / "w.memh").write_text("\n".join(w_lines) + "\n")
    (case_dir / "a.memh").write_text("\n".join(a_lines) + "\n")
    (case_dir / "c.memh").write_text("\n".join(c_lines) + "\n")
    (case_dir / "params.txt").write_text(f"M={m} K={k} N={nn} n={n} seed={seed}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="vectors", type=Path)
    args = parser.parse_args()
    for case in DEFAULT_CASES:
        emit_case(args.out, *case)
    print(f"wrote {len(DEFAULT_CASES)} cases to {args.out}/")


if __name__ == "__main__":
    main()
