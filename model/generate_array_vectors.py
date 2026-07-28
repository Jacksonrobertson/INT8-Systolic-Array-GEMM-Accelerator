"""Generate array-level test vectors for tb/systolic_array_tb.sv.

These exercise one weight tile and one activation block through the compute
datapath (input skew + PE grid + output deskew), below the level of the tile
schedule and the AXI-Stream interfaces.

Emits, per case, into vectors/array_<name>/:
  w_rows.memh   the weight tile, one ROW per line (n int8, lane j = column j),
                row 0 first. The RTL shifts weights in from the top of each
                column, so it must push these in DESCENDING order.
  a.memh        activation block, one row-slice per line (n int8, lane i = K)
  c.memh        expected results, one row-slice per line (n int32)
  params.txt    n M latency seed

`latency` is not hand-derived: it is read out of SystolicArraySim's emergence
log as the cycle on which the last column first produces a result, which is
when a fully deskewed row 0 is available. That makes the RTL timing check a
genuine cross-check against the golden model's schedule (SPEC section 8).

Usage:  python -m model.generate_array_vectors [--out vectors]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from model.generate_vectors import _pack_hex
from model.golden_model import SystolicArraySim, random_matrices

# (name, M, n, seed)
DEFAULT_CASES = [
    ("4x4_m4", 4, 4, 11),    # M == n: the tightest schedule
    ("4x4_m8", 8, 4, 12),
    ("8x8_m16", 16, 8, 13),
]


def _deskewed_latency(emergence_log: list[list[int]], n: int) -> int:
    """Cycle on which a complete, deskewed result row 0 is first available.

    Column j emerges on its own schedule; the deskew triangle realigns them,
    so a whole row is ready once the slowest column has produced its first
    result.
    """
    first = {}
    for t, cols in enumerate(emergence_log):
        for j in cols:
            first.setdefault(j, t)
    if len(first) != n:
        raise RuntimeError(f"only {len(first)} of {n} columns ever emerged")
    return max(first.values())


def emit_case(out_dir: Path, name: str, m: int, n: int, seed: int) -> None:
    # random_matrices gives (M,K) and (K,N); take a square tile of the second.
    a_block, w_tile = random_matrices(m, n, n, seed)

    sim = SystolicArraySim(n)
    sim.load_weights(w_tile)
    results, log = sim.run(a_block)

    expected = a_block.astype(np.int32) @ w_tile.astype(np.int32)
    if not np.array_equal(results, expected):
        raise RuntimeError(f"{name}: cycle-level sim disagrees with matmul")

    latency = _deskewed_latency(log, n)

    case_dir = out_dir / f"array_{name}"
    case_dir.mkdir(parents=True, exist_ok=True)

    (case_dir / "w_rows.memh").write_text(
        "\n".join(_pack_hex(w_tile[i, :], 8) for i in range(n)) + "\n")
    (case_dir / "a.memh").write_text(
        "\n".join(_pack_hex(a_block[r, :], 8) for r in range(m)) + "\n")
    (case_dir / "c.memh").write_text(
        "\n".join(_pack_hex(results[r, :], 32) for r in range(m)) + "\n")
    (case_dir / "params.txt").write_text(
        f"n={n} M={m} latency={latency} seed={seed}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="vectors", type=Path)
    args = parser.parse_args()
    for case in DEFAULT_CASES:
        emit_case(args.out, *case)
    print(f"wrote {len(DEFAULT_CASES)} array cases to {args.out}/")


if __name__ == "__main__":
    main()
