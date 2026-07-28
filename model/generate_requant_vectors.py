"""Generate test vectors for tb/requant_unit_tb.sv from the golden model.

Emits vectors/requant/cases.txt, one case per line:

    <acc:8 hex> <mult:6 hex> <shift:dec> <relu:0|1> <expected:dec>

Every expected value comes from model.golden_model.requantize(), so the RTL is
checked against the same function the spec points at rather than against a
re-derivation of it.

Coverage is directed at the places this arithmetic actually goes wrong:
  - shift == 0, which must add NO rounding constant (SPEC section 7)
  - the round-half-up boundary, where the true product is exactly x.5
  - saturation in both directions
  - relu on and off, including negative accumulators
  - the INT32 extremes, where a 64-bit intermediate is mandatory

Usage:  python -m model.generate_requant_vectors [--out vectors]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from model.golden_model import requantize

INT32_MIN, INT32_MAX = -(2**31), 2**31 - 1


def _wrap_int32(v: int) -> int:
    """Two's-complement wrap into INT32.

    Some directed cases (q * 2^shift + 2^(shift-1) for large shift) are
    deliberately built beyond INT32; the accumulator is 32 bits, so both the
    model and the RTL must see the same wrapped value. Doing it explicitly
    keeps the vector honest instead of relying on a silent NumPy cast.
    """
    return ((v + 2**31) % 2**32) - 2**31


def _cases() -> list[tuple[int, int, int, bool]]:
    """(acc, mult, shift, relu) tuples."""
    out: list[tuple[int, int, int, bool]] = []

    # shift == 0: no rounding term at all.
    for acc in (0, 1, -1, 126, 127, 128, -128, -129, 1000, INT32_MAX, INT32_MIN):
        out.append((acc, 1, 0, True))
        out.append((acc, 1, 0, False))

    # Exact .5 boundaries: with mult=1, acc = q*2^shift + 2^(shift-1) is
    # exactly halfway, which round-half-up must push up.
    for shift in (1, 2, 8, 16, 31):
        half = 1 << (shift - 1)
        for q in (0, 1, 2, -1, -2, 63, 64):
            out.append((q * (1 << shift) + half, 1, shift, True))
            out.append((q * (1 << shift) + half, 1, shift, False))
            out.append((q * (1 << shift) + half - 1, 1, shift, True))
            out.append((q * (1 << shift) + half + 1, 1, shift, True))

    # Saturation from both sides, and a realistic scale factor.
    for mult in (1, 2, 0xFFFFFF, 0x800000, 12345):
        for shift in (0, 1, 15, 23, 31):
            for acc in (0, 1, -1, 255, -255, 1 << 20, -(1 << 20),
                        INT32_MAX, INT32_MIN):
                out.append((acc, mult, shift, True))
                out.append((acc, mult, shift, False))

    # Randomised sweep over the full legal parameter space.
    rng = np.random.default_rng(20240727)
    for _ in range(3000):
        acc = int(rng.integers(INT32_MIN, INT32_MAX + 1, dtype=np.int64))
        mult = int(rng.integers(0, 1 << 24))
        shift = int(rng.integers(0, 32))
        relu = bool(rng.integers(0, 2))
        out.append((acc, mult, shift, relu))

    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="vectors", type=Path)
    args = parser.parse_args()

    case_dir = args.out / "requant"
    case_dir.mkdir(parents=True, exist_ok=True)

    lines = []
    for raw_acc, mult, shift, relu in _cases():
        acc = _wrap_int32(raw_acc)
        exp = int(requantize(np.array([acc], dtype=np.int32), mult, shift, relu)[0])
        lines.append(f"{acc & 0xFFFFFFFF:08x} {mult:06x} {shift} {int(relu)} {exp}")

    (case_dir / "cases.txt").write_text("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} requant cases to {case_dir}/cases.txt")


if __name__ == "__main__":
    main()
