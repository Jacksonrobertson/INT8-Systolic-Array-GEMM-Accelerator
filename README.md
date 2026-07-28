# INT8 Systolic Array GEMM Accelerator

A parameterizable **weight-stationary systolic array** GEMM accelerator for
INT8 inference: `N×N` array of INT8 MACs with INT32 accumulators, AXI-Stream
I/O, double-buffered weight memory, and a small control FSM. Verified at 4×4,
synthesized at 8×8 (OpenLane/Sky130).

**Status: Phase 1 complete** — microarchitecture spec + bit-exact golden
model. RTL in progress.

| Phase | Deliverable | Status |
|---|---|---|
| 1 | [Microarchitecture spec](docs/SPEC.md) + Python golden model | ✅ done |
| 2 | Parameterized SystemVerilog RTL (PE → array → buffers/FSM → AXI-Stream) | 🔨 in progress |
| 3 | cocotb constrained-random verification + SVA + functional coverage | ⬜ |
| 4 | OpenLane/Sky130 synthesis + P&R, PPA sweep and writeup | ⬜ |
| 5 | Packaging, reproducible builds, (optional) FPGA demo | ⬜ |

## Architecture at a glance

- **Dataflow:** weight-stationary — weights pinned in PEs, activations stream
  east, partial sums flow south. One result row per cycle in steady state
  (`N²` MACs/cycle; 128 GOPS at 8×8 / 1 GHz).
- **Numerics:** signed INT8 × INT8 → INT32 accumulation. INT32 is provably
  overflow-free for `K ≤ 131072` (worst-case product is 2¹⁴; see
  [SPEC §3](docs/SPEC.md#3-processing-element-pe)).
- **Interfaces:** AXI-Stream for weights, activations, and results;
  config registers for matrix dimensions and start/done.
- **Weight double-buffering:** the next weight tile loads in shadow during
  compute, so back-to-back tiles lose zero cycles.
- **Stretch:** ReLU + fixed-point requantization on the output path
  (specified in [SPEC §7](docs/SPEC.md#7-output-stage-stretch-relu--requantization),
  already implemented in the golden model).

Full details: **[docs/SPEC.md](docs/SPEC.md)**.

## Golden model

`model/golden_model.py` is the single source of truth for numerical behavior:

- `gemm_int8(a, b)` — functional reference with exact INT32 accumulation
- `requantize(acc, mult, shift)` — the INT8 output stage, bit-exact
- `SystolicArraySim` — a **cycle-level simulator** of the skewed-wavefront
  schedule, used to cross-check RTL result ordering and latency, not just values
- `gemm_int8_tiled(a, b, n)` — the full multi-tile schedule the FSM implements

## Running the model

```bash
pip install numpy pytest
pytest -v                          # golden-model self-checks
python -m model.generate_vectors   # emit .memh stimulus/expected files to vectors/
```

Test vectors land in `vectors/<case>/{a,w,c}.memh` in exact AXI-Stream beat
order (documented in `model/generate_vectors.py`) and are consumed by the
Phase 3 cocotb testbench.

## Repository layout

```
docs/SPEC.md          microarchitecture specification
model/                NumPy golden model + test-vector generation
tests/                pytest self-checks for the golden model
vectors/              generated .memh test vectors (checked in for CI diffing)
rtl/                  SystemVerilog (Phase 2)
tb/                   cocotb testbench (Phase 3)
```
