# Phase 4 — Implementation & PPA Report (Sky130)

**Scope:** `gemm_top` through synthesis (yosys → sky130_fd_sc_hd) and an
OpenROAD place-and-route study — floorplan, global/detailed placement, CTS,
setup/hold repair, global route — with STA on global-route parasitics.
A/B sweep of the baseline RTL against the requant-pipelined RTL, both at the
tape-out configuration **N=8, M_MAX=32** (see [PHASE4_PLAN.md](PHASE4_PLAN.md)
§1 for why M_MAX is cut from 256).

**What this is not:** a signoff. No PDN, no detailed routing, no DRC/LVS, tt
corner only (§6). Numbers are for architecture-level decisions — fmax trend,
area split, critical-path identity — which global-route estimates capture
well.

---

## 1. Headline results

| | baseline | requant-pipelined | delta |
|---|---|---|---|
| Achieved clock (met-timing point) | 19.3 ns / **51.8 MHz** | 18.2 ns / **55.0 MHz** | +6% |
| Best pushed convergence | 16.8 ns / 59.5 MHz | 15.4 ns / **65.0 MHz** | **+9%** |
| Mapped cells | 138,844 | 141,027 | +1.6% |
| Core area (densest clean run) | 1.46 mm² | 1.38 mm² | — |
| Throughput at pushed fmax (2·N²·f) | 7.6 GOPS | **8.3 GOPS** | +9% |
| GOPS/mm² | 5.2 | **6.0** | +15% |

Latency cost of the pipeline stage: one drain cycle per GEMM — measured
end-to-end overhead moved 27→28 cycles (4×4) and 47→48 (8×8), still constant
in tile count, so the zero-bubble handover property is intact.

## 2. The sweep

`flow/results/sweep.csv`; effective period = target − WNS.

| variant | target ns | WNS ns | effective ns | area µm² | power mW* |
|---|---:|---:|---:|---:|---:|
| base | 25 | +5.01 | 19.99 | 1,795,119 | 154 |
| base | 20 | +0.70 | 19.30 | 1,811,642 | 197 |
| base | 18 | −1.22 | 19.22 | 1,763,590 | 217 |
| base | 15 | −3.88 | 18.88 | 1,633,226 | 254 |
| base | 12 | −5.44 | 17.44 | 1,492,654 | 305 |
| base | 10 | −6.81 | 16.81 | 1,462,919 | 362 |
| rqpipe | 20 | +1.74 | 18.26 | 1,879,910 | 211 |
| rqpipe | 18 | −0.18 | 18.18 | 1,827,966 | 229 |
| rqpipe | 15 | −2.87 | 17.87 | 1,690,767 | 267 |
| rqpipe | 12 | −3.81 | 15.81 | 1,542,600 | 319 |
| rqpipe | 10 | −5.58 | 15.58 | 1,511,052 | 374 |
| rqpipe | 8 | −7.39 | 15.39 | 1,383,592 | 460 |

\* reported at the *target* clock, not the achieved one; treat as a trend.
Hold is repaired to ≈0 everywhere except the over-pushed rqpipe 8 ns point
(−0.48 ns), which is past convergence anyway.

Two shapes worth reading off the curve: pushing the target below the
achievable period keeps buying small real gains (the repair engine works
harder) at rapidly growing power, and the tools trade ~20% area between the
lazy and pushed ends of the same design.

**Array size does not set the clock.** The N=4 point converges to ~16.3 ns —
the same neighborhood as N=8 — because the critical path is per-lane in the
output stage, not in the array. Area scales as expected (0.63 mm² at N=4 vs
1.63 mm² at N=8, same 15 ns target).

## 3. Area breakdown (synthesis, N=8, baseline)

| Block | µm² | share |
|---|---:|---:|
| PE array — 64 MACs | 502,562 | 41.5% |
| Accumulation RAM (8,192 flops) | 333,291 | 27.5% |
| **Requant units ×8** | **261,310** | **21.6%** |
| Skew/deskew triangles | 50,798 | 4.2% |
| Weight buffer (double bank) | 36,714 | 3.0% |
| Control FSM + top glue | 22,937 | 1.9% |

The finding nobody would guess from the RTL: the "optional" INT8 output
stage costs **half the PE array** — eight 24×32 multipliers are not a
footnote. MAC : storage ≈ 1.35 : 1. If area mattered more than a cycle of
latency, one shared requant multiplier serving the 8 lanes round-robin
(they produce at most one row per cycle anyway... but that row is 8 lanes
wide, so it would need an 8-cycle drain or a 2×-clocked unit) — the honest
alternative is two multipliers at 4 lanes each and +3 drain cycles. Not
taken; noted.

## 4. Critical path: measured, changed, measured again

**Baseline:** accumulator output register → ReLU mux → 24×32 multiply →
64-bit rounding add → 64-bit arithmetic shift → clamp → output mux → stream
output register. ~19.3 ns achieved (16.8 pushed). This is the path
[PHASE4_PLAN.md](PHASE4_PLAN.md) §5 predicted from the yosys audit, and it
is why fmax is independent of N.

**The change** (`rtl/requant_unit.sv`, `gemm_top.sv` — the plan's option 1):
register the multiply inside each requant unit, with a matching `rq`
valid/raw-data stage in `gemm_top` so the raw-INT32 and quantized modes keep
one latency. The stage sits inside the `core_en` domain, so the stall model
and the AXI-Stream stability SVA are untouched. Full verification suite
re-run green (15/15 SV benches, cocotb session with coverage closed).

**After:** the critical path moved to **stage 2** — `prod_q` register →
64-bit rounding add → barrel shift → clamp → output register — converging at
~15.4 ns, with the multiply stage no longer reported. The split landed
unevenly: what remains after the register (a 64-bit adder chain feeding a
5-level 64-bit mux shifter and saturation compares) optimizes to nearly as
long as the whole original cone did. Hence +9%, not the naive 2×.

**Next levers, in order** (not taken in this phase):
1. Narrow the post-multiply arithmetic: the product provably fits 56 bits
   (|acc|·mult < 2⁵⁵), so the 64-bit adder/shifter carry ~8 dead bits.
2. Re-cut the pipeline: `rnd` is cfg-static, so `prod + rnd` could move into
   stage 1 — but only if stage 1 (multiply + add) stays under stage 2's new
   length; needs the same measure-first discipline.
3. Only then consider a 2-stage multiplier. And per the plan's standing
   guard: the PE MAC is **not** a pipelining candidate — that changes the
   systolic schedule, not a stage boundary.

## 5. What the constraints taught

Three findings that shaped the flow (`flow/openroad/pnr.tcl`), each of which
first showed up as a wrong number:

- **`rst_n` must be false-pathed** or the async-reset fanout reports as a
  ~20 ns "critical path" with the I/O budget on top.
- **Quasi-static config must be false-pathed, not just budget-relaxed.**
  Even at a 10% budget, `cfg_shift` → 64-bit shifter → clamp dominated both
  variants' reports and hid the real register-to-register paths. The
  interface contract (SPEC §6.2: sampled at start, stable during a run)
  bounds these pins, not the clock.
- **Placement padding + hold repair don't compose** at 45% density: the
  post-CTS hold buffers had nowhere to legalize (DPL-0036).

## 6. Methodology and reproduction

- Tools (conda, litex-hub channel): OpenROAD `f12e2f4`, yosys 0.38+92,
  open_pdks sky130A; liberty `sky130_fd_sc_hd__tt_025C_1v80`.
- Flow: `flow/openroad/{synth.tcl,pnr.tcl,run.sh}`. Study-level: floorplan
  (40% util) → global place → repair_design → detailed place → CTS →
  setup/hold repair → global route → STA on global-route parasitics. No PDN,
  detailed routing, or DRC/LVS; single corner. A signoff pass through full
  OpenLane/ORFS is the natural Phase 5+ follow-on.
- A/B honesty: the baseline synthesizes from a git worktree pinned at the
  pre-pipeline commit while the variant uses the working tree
  (`RTL_DIR` override in `run.sh`), into one CSV with a variant column.

```bash
micromamba create -n eda -c litex-hub -c conda-forge openroad open_pdks.sky130a yosys
export PDK_ROOT=$CONDA_PREFIX/share/pdk
flow/openroad/run.sh -v rqpipe -p "20 18 15 12 10 8" -n 8
```

Per-run reports are checked in under `flow/results/*/` (`reports.rpt`,
`synth_stat.rpt`, `pnr.log`); netlists and synthesis logs are regenerable
and ignored.
