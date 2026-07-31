#!/usr/bin/env bash
# Phase 4 PPA sweep: synthesis (yosys) + P&R study (OpenROAD) on sky130hd.
#
#   flow/openroad/run.sh                      full sweep (see PERIODS below)
#   flow/openroad/run.sh -p 10 -n 8           one point
#   flow/openroad/run.sh -p 10 -n 8 -m 32     explicit M_MAX
#
# Requires yosys + openroad on PATH and PDK_ROOT pointing at a sky130A
# open_pdks install (conda: micromamba create -c litex-hub -c conda-forge \
#   openroad open_pdks.sky130a yosys). Results land in flow/results/.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PDK=${PDK_ROOT:?set PDK_ROOT to the open_pdks share/pdk directory}/sky130A
HD=$PDK/libs.ref/sky130_fd_sc_hd

export LIB=$HD/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
export TLEF=$HD/techlef/sky130_fd_sc_hd__nom.tlef
export LEF=$HD/lef/sky130_fd_sc_hd.lef
export SITE_TRACKS=$ROOT/flow/openroad/sky130hd.tracks
export RTL_DIR=$ROOT/rtl

PERIODS="25 15 10 8 6"; SIZES="8"; MMAX=32; UTIL=40
while getopts "p:n:m:u:h" o; do
  case $o in
    p) PERIODS=$OPTARG ;;
    n) SIZES=$OPTARG ;;
    m) MMAX=$OPTARG ;;
    u) UTIL=$OPTARG ;;
    h) sed -n '2,10p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

CSV=$ROOT/flow/results/sweep.csv
mkdir -p "$ROOT/flow/results"
[ -f "$CSV" ] || echo "n,m_max,period_ns,cells,area_um2,util_pct,wns_ns,tns_ns,hold_wns_ns,power_mw" > "$CSV"

for n in $SIZES; do
  for p in $PERIODS; do
    tag="n${n}_m${MMAX}_p${p}"
    out=$ROOT/flow/results/$tag
    mkdir -p "$out"
    echo "=== $tag: synthesis ==="
    GEMM_N=$n M_MAX=$MMAX OUT=$out PERIOD_PS=$(awk "BEGIN{print $p*1000}") \
      yosys -q -c "$ROOT/flow/openroad/synth.tcl" > "$out/synth.log" 2>&1 \
      || { tail -20 "$out/synth.log"; exit 1; }
    echo "=== $tag: P&R study ==="
    NETLIST=$out/gemm_top.synth.v PERIOD_NS=$p UTIL=$UTIL OUT=$out \
      openroad -no_init -exit "$ROOT/flow/openroad/pnr.tcl" > "$out/pnr.log" 2>&1 \
      || { tail -20 "$out/pnr.log"; exit 1; }
    python3 "$ROOT/flow/openroad/summarize.py" "$out" "$n" "$MMAX" "$p" >> "$CSV"
    tail -1 "$CSV"
  done
done
echo "sweep complete: $CSV"
