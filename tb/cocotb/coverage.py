"""Functional coverage for the gemm_top cocotb bench.

Coverage here is a claim about what the test session exercised, derived from
each run's configuration and its expected results — not from probing DUT
internals. Bins were chosen from where this design has actually broken
(docs/PHASE2_RTL.md): the M < 2n bubble path, combined input-starvation +
output-backpressure, tile-count corners, quantization saturation, and restart
without reset.

Each simulator process appends its samples to COVERAGE_FILE (JSON lines);
run.py merges the files from every build and enforces MANDATORY closure, so a
green session is green *and* demonstrably covered.
"""

import json
import os

GROUPS = {
    "m_dim": ["m_eq_n", "m_eq_2n", "m_mid", "m_max"],
    "k_tiles": ["k1", "k2", "k3plus"],
    "n_tiles": ["n1", "n2", "n3plus"],
    "stall": ["none", "in_only", "out_only", "both"],
    "quant": ["off", "identity", "scaled"],
    "quant_events": ["sat_high", "relu_zero", "rounding"],
    "sequencing": ["cold_start", "immediate_restart", "delayed_restart"],
    "cross": [
        "bubble_multi_tile",      # M == n (withhold path) x more than one K tile
        "both_stall_multi_tile",  # the Phase 2 duplicate-beat corner, multi-tile
        "quant_under_stall",
        "restart_new_dims",       # back-to-back run with different M/K/N
    ],
}

# Every bin is mandatory: the bins exist because each one maps to a known
# failure mode, so an unhit bin means the session did not test something that
# has already gone wrong once.
MANDATORY = [(g, b) for g, bins in GROUPS.items() for b in bins]


class Coverage:
    def __init__(self):
        self.hits = {}

    def hit(self, group, bin_name):
        assert bin_name in GROUPS[group], f"unknown bin {group}.{bin_name}"
        key = f"{group}.{bin_name}"
        self.hits[key] = self.hits.get(key, 0) + 1

    def sample_run(self, *, n, m, k, nn, stall_in, stall_out, quant, mult,
                   shift, sequencing, dims_changed, expected_c, expected_q):
        """Record one completed GEMM. expected_c/expected_q are the golden
        model's int32/int8 results (expected_q is None when quant is off)."""
        if m == n:
            self.hit("m_dim", "m_eq_n")
        elif m == 2 * n:
            self.hit("m_dim", "m_eq_2n")
        elif m >= 256:
            self.hit("m_dim", "m_max")
        else:
            self.hit("m_dim", "m_mid")

        kt, nt = k // n, nn // n
        self.hit("k_tiles", "k1" if kt == 1 else ("k2" if kt == 2 else "k3plus"))
        self.hit("n_tiles", "n1" if nt == 1 else ("n2" if nt == 2 else "n3plus"))

        stalled_in, stalled_out = stall_in > 0, stall_out > 0
        if stalled_in and stalled_out:
            self.hit("stall", "both")
        elif stalled_in:
            self.hit("stall", "in_only")
        elif stalled_out:
            self.hit("stall", "out_only")
        else:
            self.hit("stall", "none")

        if not quant:
            self.hit("quant", "off")
        else:
            self.hit("quant", "identity" if (mult, shift) == (1, 0) else "scaled")
            if expected_q is not None:
                if (expected_q == 127).any():
                    self.hit("quant_events", "sat_high")
                if (expected_c < 0).any() and (expected_q == 0).any():
                    self.hit("quant_events", "relu_zero")
                if shift > 0:
                    self.hit("quant_events", "rounding")

        self.hit("sequencing", sequencing)

        if m == n and kt > 1:
            self.hit("cross", "bubble_multi_tile")
        if stalled_in and stalled_out and (kt > 1 or nt > 1):
            self.hit("cross", "both_stall_multi_tile")
        if quant and (stalled_in or stalled_out):
            self.hit("cross", "quant_under_stall")
        if sequencing != "cold_start" and dims_changed:
            self.hit("cross", "restart_new_dims")

    # ---- persistence ------------------------------------------------------

    def flush(self):
        """Append this collector's hits to COVERAGE_FILE (JSON lines)."""
        path = os.environ.get("COVERAGE_FILE")
        if path:
            with open(path, "a") as f:
                f.write(json.dumps(self.hits) + "\n")

    @staticmethod
    def merge(paths):
        merged = {}
        for p in paths:
            if not os.path.exists(p):
                continue
            with open(p) as f:
                for line in f:
                    for key, count in json.loads(line).items():
                        merged[key] = merged.get(key, 0) + count
        return merged

    @staticmethod
    def report(merged):
        lines, unhit = [], []
        for group, bins in GROUPS.items():
            for b in bins:
                count = merged.get(f"{group}.{b}", 0)
                mark = " " if count else "!"
                lines.append(f"  {mark} {group + '.' + b:32s} {count:6d}")
                if count == 0 and (group, b) in MANDATORY:
                    unhit.append(f"{group}.{b}")
        return "\n".join(lines), unhit
