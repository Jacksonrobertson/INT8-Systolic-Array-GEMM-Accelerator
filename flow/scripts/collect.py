"""Collect PPA metrics from OpenLane 2 runs into one table.

  python flow/scripts/collect.py flow/openlane/runs/*  > docs/ppa_table.md

Reads each run's final/metrics.json (OpenLane 2 layout) and tabulates the
numbers the Phase 4 writeup needs. Metric keys drift between OpenLane
versions, so every lookup has fallbacks and missing values print as '-';
extend KEYS rather than editing rows by hand.
"""

import json
import sys
from pathlib import Path

# (column, [candidate metric keys], scale)
KEYS = [
    ("clk_ns", ["clock__period"], 1),
    ("wns_ns", ["timing__setup__ws", "timing__setup_ws"], 1),
    ("tns_ns", ["timing__setup__tns"], 1),
    ("hold_wns_ns", ["timing__hold__ws", "timing__hold_ws"], 1),
    ("cells", ["design__instance__count", "synthesis__design__instance__count"], 1),
    ("area_um2", ["design__instance__area", "design__die__area"], 1),
    ("util_pct", ["design__instance__utilization"], 100),
    ("power_mw", ["power__total", "power__total__watts"], 1000),
    ("drc", ["route__drc_errors", "magic__drc_error__count"], 1),
    ("lvs", ["design__lvs_error__count", "netgen__lvs_error__count"], 1),
]


def load_metrics(run_dir):
    for candidate in ["final/metrics.json", "metrics.json"]:
        p = Path(run_dir) / candidate
        if p.exists():
            return json.loads(p.read_text())
    found = sorted(Path(run_dir).rglob("metrics.json"))
    return json.loads(found[-1].read_text()) if found else None


def main():
    runs = sys.argv[1:]
    if not runs:
        sys.exit(__doc__)
    header = ["run"] + [k for k, _, _ in KEYS] + ["fmax_mhz", "gops", "gops_per_mm2"]
    rows = []
    for run in runs:
        m = load_metrics(run)
        if m is None:
            rows.append([Path(run).name] + ["-"] * (len(header) - 1))
            continue
        vals = {}
        for col, cands, scale in KEYS:
            v = next((m[c] for c in cands if c in m and m[c] is not None), None)
            vals[col] = v * scale if isinstance(v, (int, float)) else "-"
        # Achieved fmax from the swept period and its worst negative slack.
        fmax = gops = gpmm = "-"
        if isinstance(vals["clk_ns"], (int, float)) and isinstance(vals["wns_ns"], (int, float)):
            t_eff = vals["clk_ns"] - min(vals["wns_ns"], 0)
            fmax = round(1000 / t_eff, 1)
            # GOPS = 2 * N^2 * fmax; N=8 build assumed — adjust for 4x4 runs.
            gops = round(2 * 64 * fmax / 1000, 1)
            if isinstance(vals["area_um2"], (int, float)) and vals["area_um2"] > 0:
                gpmm = round(gops / (vals["area_um2"] / 1e6), 1)
        rows.append([Path(run).name] +
                    [vals[k] for k, _, _ in KEYS] + [fmax, gops, gpmm])

    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for r in rows:
        print("| " + " | ".join(str(x) for x in r) + " |")


if __name__ == "__main__":
    main()
