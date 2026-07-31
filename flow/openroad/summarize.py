"""Extract one CSV row from a flow/results/<tag>/ directory.

Usage: summarize.py <out_dir> <n> <m_max> <period_ns>

Parses synth_stat.rpt (yosys) and pnr.log (OpenROAD; the ==REPORT== marked
sections emitted by pnr.tcl).
"""

import re
import sys
from pathlib import Path


def grep1(text, pattern, default=""):
    m = re.search(pattern, text)
    return m.group(1) if m else default


def main():
    out, n, mmax, period = sys.argv[1:5]
    variant = sys.argv[5] if len(sys.argv) > 5 else "base"
    synth = Path(f"{out}/synth_stat.rpt").read_text()
    log = Path(f"{out}/pnr.log").read_text()
    # Only the report tail: earlier stages print their own slack lines.
    rpt = log[log.rfind("==REPORT timing=="):]

    cells = grep1(synth, r"Number of cells:\s+(\d+)")
    area = grep1(rpt, r"Design area (\d+) u\^2")
    util = grep1(rpt, r"(\d+)% utilization")
    wns = grep1(rpt.split("==REPORT wns==")[-1], r"worst slack (-?[\d.]+)")
    tns = grep1(rpt, r"tns (-?[\d.]+)")
    hold = grep1(rpt.split("==REPORT hold==")[-1], r"worst slack (-?[\d.]+)")
    power = grep1(rpt, r"Total\s+[\d.e+-]+\s+[\d.e+-]+\s+[\d.e+-]+\s+([\d.e+-]+)\s+100")
    power_mw = f"{float(power) * 1000:.2f}" if power else ""
    print(",".join([variant, n, mmax, period, cells, area, util, wns, tns,
                    hold, power_mw]))


if __name__ == "__main__":
    main()
