"""Extract one CSV row from a flow/results/<tag>/ report directory.

Usage: summarize.py <out_dir> <n> <m_max> <period_ns>
"""

import re
import sys
from pathlib import Path


def grep1(path, pattern, group=1, default=""):
    try:
        text = Path(path).read_text()
    except OSError:
        return default
    m = re.search(pattern, text)
    return m.group(group) if m else default


def main():
    out, n, mmax, period = sys.argv[1:5]
    cells = grep1(f"{out}/synth_stat.rpt",
                  r"Number of cells:\s+(\d+)")
    area = grep1(f"{out}/area.rpt",
                 r"Design area (\d+) u\^2")
    util = grep1(f"{out}/area.rpt",
                 r"(\d+)% utilization")
    wns = grep1(f"{out}/wns.rpt", r"worst slack (-?[\d.]+)")
    tns = grep1(f"{out}/tns.rpt", r"tns (-?[\d.]+)")
    hold = grep1(f"{out}/hold.rpt", r"worst slack (-?[\d.]+)")
    power = grep1(f"{out}/power.rpt",
                  r"Total\s+\S+\s+\S+\s+\S+\s+([\d.e+-]+)")
    power_mw = f"{float(power) * 1000:.2f}" if power else ""
    print(",".join([n, mmax, period, cells, area, util, wns, tns, hold,
                    power_mw]))


if __name__ == "__main__":
    main()
