# Phase 4 — Implementation & PPA Plan

**Goal:** take `gemm_top` through OpenLane/OpenROAD synthesis and P&R on
Sky130, sweep clock target and array size, and produce a short PPA writeup:
fmax, area breakdown (MACs vs buffers), GOPS/mm², where the critical path
lives, and **one RTL change made because of what implementation showed** —
the "RTL designer who understands physical design" proof.

**Status of this document:** prep. Everything in §1 was *measured* on this
repo (yosys 0.33, Verilator 5.020); §2–§6 are the plan.

---

## 1. Synthesizability audit — findings (verified)

Run `make -C flow audit` to reproduce.

1. **Mainline yosys could not parse the original RTL — fixed at the
   source.** The yosys frontend rejects multidimensional packed array ports
   (`logic [N-1:0][DW_IN-1:0]`) and wildcard package imports
   (`import gemm_pkg::*`), both used throughout. Rather than carrying an
   sv2v conversion step (tried first, worked, then retired), the RTL was
   refactored to yosys-parseable SystemVerilog: lane buses are flat vectors
   indexed with `[i*W +: W]` part-selects, and package references are fully
   qualified (`gemm_pkg::DIM_W` — the one form yosys accepts). Unpacked
   arrays (`mem[2][N]`) and the elaborated structure are unchanged; yosys
   produces the identical 1,832-cell design either way. The full regression
   (lint, 15 SV testbenches, complete cocotb session with coverage closure)
   passes on the refactored RTL, and `make -C flow audit` gates the
   parseability from here on.

2. **The accumulation RAM is the area problem, exactly as PHASE2_RTL §8
   predicted.** It infers correctly as a single synchronous memory
   (`$mem_v2`), but OpenLane has no free Sky130 SRAM to map it to, so it
   becomes flip-flops:
   - `M_MAX=256`, N=8: 256×256 b = **65,536 flops** — untenable (~1.3 mm²
     of DFF area alone at ~20 µm²/flop in sky130hd).
   - `M_MAX=32`, N=8: 8,192 flops — fine. **Decision: implement at
     `M_MAX=32`.** It's a synthesis parameter; verification at other values
     is unaffected. Note the RAM's `$mem_v2` audit in `flow/Makefile`
     guards the inference pattern, not the mapping.

3. **Measured pre-mapping size at the tape-out config** (N=8, `M_MAX=32`,
   generic gates before ABC): ~15.6k flops, ~147k generic gate instances.
   Storage splits exactly as designed: 8,192 (accum RAM) + 1,024 (weight
   banks) = 9,216 enable-flops; the rest is PE pipeline registers, skew
   triangles, and control. Expect roughly 40–70k mapped sky130hd cells.

4. **72 multipliers, two very different kinds.** 64 are the 8×8 PE
   multiplies. The other 8 are the requant units: 24-bit × 32-bit products
   feeding a shift and clamp, **fully combinational between the
   accumulation RAM read and the output register** (`gemm_top.sv` §"output
   stream"). Prediction to test on day one: at any aggressive clock the
   critical path is requant, not the PE MAC. §5 has the fix ready.

5. The weight buffer's demotion to registers (yosys warning) is correct
   and expected — it's 1 Kb, written column-wise and read row-wise
   (inherently multiport), and was always going to be flops.

## 2. Toolchain (week 1)

Your home turf — pin versions and go:

- **OpenLane 2** (nix install) + **sky130A** via `ciel`/`volare`. Record
  the OpenLane version and PDK hash in the writeup; PPA numbers without
  pinned tools aren't reproducible claims.
- Starting files are in `flow/openlane/`: `config.json` (documented
  choices: `SYNTH_NO_FLAT` for the hierarchical area breakdown,
  clock-gating on — see §5, util/density starting points) and
  `constraints.sdc` (30% I/O budgets; note the comment about tready
  feedthrough paths — they are real combinational input→output paths and
  must not be false-pathed).
- First milestone: one clean full flow at a lazy clock (50 ns) with zero
  DRC/LVS errors. Get green before getting fast.

## 3. The sweep (weeks 1–2)

Grid, in order of information value:

| Axis | Points | Why |
|---|---|---|
| Clock period | 25 → 20 → 15 → 12 → 10 ns (stop at first hard fail) | fmax curve + where WNS breaks |
| Array size | N=8 (primary), N=4 (one point at two clocks) | area/perf scaling, and the N=4 config doubles as the Tiny Tapeout candidate |
| Requant | before/after the §5 pipeline change, same clocks | the PPA-driven-RTL-change evidence |

Mechanics: one run per point via `openlane --override-env CLOCK_PERIOD=<ns>`
(or per-point config copies — cheap and more reproducible). Collect with
`python flow/scripts/collect.py flow/openlane/runs/*` — it tabulates
period, WNS/TNS, cell count, area, utilization, power, DRC/LVS, and derives
achieved fmax, GOPS (2·N²·f), and GOPS/mm². Keep every run's
`final/metrics.json` in the repo (small) so the table regenerates.

## 4. What the writeup must contain (week 3)

1. **fmax** at the chosen config, from the sweep knee, with WNS at the
   target and the failing path at one notch past it.
2. **Area breakdown** by hierarchy (`SYNTH_NO_FLAT` gives per-module
   numbers): PE array vs accum RAM vs weight buffer vs skew vs requant vs
   control. The interesting ratio is MAC area : storage area.
3. **GOPS and GOPS/mm²** at fmax (count mul+add = 2 ops; 128 GOPS at 8×8 /
   1 GHz scales linearly down to achieved f).
4. **Critical path narrative**: name the startpoint/endpoint cells, walk
   the stages (e.g. RAM-read → requant mult → shift → clamp → mux →
   output reg), and say *why* it's the path — then what you changed (§5)
   and the measured delta. One before/after table row is worth a page of
   prose.
5. **Power** at fmax (OpenSTA estimate is fine; say it's an estimate and
   under what switching assumption).

## 5. Candidate RTL changes, ranked (do #1, keep #2 cheap, know why not #3)

1. **Pipeline the requant unit** (predicted critical path). One register
   stage after the multiply, before shift/clamp. The output side already
   decouples through the one-deep `oq` register; a second stage extends
   that to a standard two-deep skid, so AXI-Stream stability (the SVA from
   Phase 2's duplicate-beat fix) is preserved. Cost: one cycle of drain
   latency, invisible in steady state. The cocotb bench re-verifies the
   change for free — no vectors to regenerate.
2. **Clock gating for `core_en`** (already enabled in `config.json`). The
   global enable fans out to every PE flop; letting synthesis map
   enable-muxes to ICG cells cuts both the mux area and the clock-tree
   power. Report the with/without delta if time allows — it's one config
   flip.
3. **Do NOT pipeline the PE MAC.** If the PE mul+add turns out critical
   instead, the tempting fix — a register between multiply and add —
   changes the systolic schedule (the emergence algebra in
   PHASE2_RTL §"timing contract" assumes the multiply consumes the
   activation arriving *this* cycle). That's a dataflow redesign, not a
   PPA tweak. The legal lever is letting the tools retime within the PE
   cone (`SYNTH_STRATEGY` delay variants) and, if that's not enough,
   accepting the lower fmax and saying so — a defended limit beats a
   broken schedule.

## 6. Guards and stretch

- **Scope guards:** no SRAM macro integration in v1 (`M_MAX=32` instead —
  revisit with DFFRAM/OpenRAM only if everything else lands early); no
  new features in `rtl/` during Phase 4 except the §5 change; every RTL
  edit goes back through `make -C sim` + `tb/cocotb/run.py` before the
  next hardening run.
- **Tiny Tapeout (stretch):** a TT tile is ~0.016 mm²; even the 4×4 array
  with `M_MAX=8` is likely several tiles (16 MACs + ~4k storage bits).
  Check the N=4 sweep point's area against the current TT multi-tile
  allowance before promising anything on a shuttle.
- **Schedule** (~4 weeks at 8–10 h/wk): wk 1 toolchain + first clean run;
  wk 2 sweep; wk 3 the §5 change + re-sweep + writeup draft; wk 4 buffer
  for the thing that will inevitably eat a weekend (it's usually LVS).
