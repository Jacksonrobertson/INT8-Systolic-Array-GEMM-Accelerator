# Phase 3 — Constrained-Random Verification Report

**Scope:** the cocotb layer planned for Phase 3, on top of the SVA set and
vector regression that shipped with Phase 2. Constrained-random stimulus,
golden-model checking computed on the fly, functional coverage with enforced
closure, and mutation checks on the bench itself.

**Status:** complete. 16/16 cocotb tests pass (8 at N=4, 8 at N=8), 57
randomized GEMMs per default session, all mandatory coverage bins hit, and
both injected RTL mutations are caught.

---

## 1. Architecture

```
tb/cocotb/
  axis.py            AXI-Stream master/slave BFMs with bursty stall injection
  coverage.py        functional coverage model + closure enforcement
  test_gemm_top.py   directed corners + constrained-random tests
  run.py             builds N=4 and N=8, runs both, merges coverage
```

The decisive difference from the Phase 2 SystemVerilog bench: **there are no
pre-generated vector files.** Each run draws dimensions, matrices, stall
profile and quantization constants, computes the expected output by calling
`gemm_int8()` / `requantize()` directly, and checks every result beat, every
`tlast`, and the final beat count. Since the golden model and the checker now
share one process, the whole stimulus space is open to randomization — the
`.memh` flow could only test the seven cases somebody had generated.

The DUT is always built with `+define+SIM_ASSERT`, so the Phase 2 assertions
(AXI-Stream stability on all three streams, FSM one-hot and legal
transitions, accumulator overflow, output-register acceptance) are armed
under every random stimulus. The BFMs obey the same AXI-Stream contract they
check: once `tvalid` rises, data holds until `tready` completes the
handshake — and the DUT-side SVAs would catch the bench itself violating
that.

## 2. Tests

| Test | Targets |
|---|---|
| `test_smoke_full_rate` | cold start, single tile, full rate |
| `test_m_max_boundary` | `M = M_MAX = 256`: accumulation RAM top row |
| `test_worst_case_accumulator` | all-(−128) operands, 4 K-tiles: every product at +2¹⁴ (SPEC §3 bound) |
| `test_quant_corners` | identity / saturating / auto-scaled requantization, chained without reset |
| `test_bubble_path` | `M = n` with 3 K-tiles: the M &lt; 2n withhold path (PHASE2_RTL §5), under stalls |
| `test_backpressure_torture` | 50–60% starvation **and** backpressure together — the Phase 2 duplicate-beat corner — with quantization on top |
| `test_back_to_back` | immediate restart on new dimensions, then input-only and output-only stall runs |
| `test_constrained_random` | 25 (N=4) + 10 (N=8) runs: random dims, data, stall class, quant constants, restart gaps |

## 3. Functional coverage

Bins were chosen from where this design has actually been wrong, not from a
generic checklist — each bin maps to a known failure mode from
`docs/PHASE2_RTL.md`, so an unhit bin means the session skipped something
with a track record:

- **`m_dim`**: `m_eq_n` (the bubble path), `m_eq_2n` (the zero-bubble
  boundary), mid, and `m_max`
- **`k_tiles` / `n_tiles`**: 1 / 2 / 3+ — tile-handover count corners
- **`stall`**: none / input-only / output-only / **both** (the
  duplicate-beat combination)
- **`quant` + `quant_events`**: off / identity / scaled; saturation, ReLU
  zeroing, and rounding actually observed in the expected data
- **`sequencing`**: cold start, immediate restart, delayed restart
- **cross bins**: bubble×multi-tile, both-stall×multi-tile,
  quant-under-stall, restart-with-new-dims

Coverage is sampled from each run's configuration and golden-model results,
merged across the N=4 and N=8 builds, and **closure is enforced**: the
default session fails if any mandatory bin is unhit. The merged table lands
in `sim/build/coverage_report.txt`.

## 4. Bench qualification (mutation checks)

A green bench proves nothing until it has been seen red. Two RTL mutations
were injected and reverted; both were caught:

| Mutation | Caught by |
|---|---|
| Drop the rounding add in `requant_unit.sv` (`(prod + rnd) >>> shift` → `prod >>> shift`) | `test_quant_corners`, `test_backpressure_torture`, random quant runs — off-by-one in exactly the rounded lanes |
| Drop the `out_nt` term from `out_done` in `gemm_top.sv` | `tlast` mismatch flagged on the last row of every non-final column-block, across four tests |

No new RTL bugs were found by the random sessions run so far — consistent
with Phase 2's directed tests and SVAs already covering these paths — but
that claim is now backed by enforced coverage rather than by the absence of
red.

## 5. Toolchain note

cocotb 2.x requires Verilator ≥ 5.036 (`VerilatedVpi::evalNeeded` et al.);
distro packages currently ship 5.020, which fails to compile cocotb 2.0's
VPI shim. The bench therefore pins **cocotb 1.9.2**, which pairs cleanly
with Verilator 5.020 — the same version the Phase 2 bench used. When distro
Verilator crosses 5.036, migrating is a mechanical API rename
(`cocotb.runner` → `cocotb_tools.runner`, `units=` → `unit=`).

## 6. Running it

```bash
pip install numpy "cocotb==1.9.2"    # plus Verilator 5.x on PATH
python tb/cocotb/run.py              # full session: N=4 + N=8, random seed
python tb/cocotb/run.py --seed 42    # reproduce a session exactly
python tb/cocotb/run.py -n 4 --random-count 50 --waves
```

Every failure message carries the run's full configuration
(`M/K/N/n/stalls/quant/seed`), so any red run is reproducible from its log
line alone.
