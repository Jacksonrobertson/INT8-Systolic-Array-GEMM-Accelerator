# INT8 Weight-Stationary Systolic GEMM Accelerator — Microarchitecture Specification

**Version:** 1.0 (Phase 1)
**Status:** Approved for RTL implementation
**Golden model:** `model/golden_model.py` (bit-exact reference for all behavior in this spec)

---

## 1. Overview

This block computes `C = A × B` where **A** (activations) is an `M×K` matrix of
signed INT8, **B** (weights) is a `K×N` matrix of signed INT8, and **C** is an
`M×N` matrix of signed INT32. Compute is performed by an `AH×AW`
weight-stationary systolic array of INT8 multiply-accumulate processing
elements (PEs). Data enters and leaves over AXI-Stream; operation is
configured through a small register file and sequenced by a control FSM.

### 1.1 Design parameters

| Parameter | Default | Range | Description |
|---|---|---|---|
| `AH` | 8 | 2–16, power of 2 | Array height (rows of PEs = rows of a weight tile, K-dimension) |
| `AW` | 8 | 2–16, power of 2 | Array width (cols of PEs = cols of a weight tile, N-dimension) |
| `DW_IN` | 8 | fixed | Operand width (signed INT8) |
| `DW_ACC` | 32 | fixed | Accumulator width (signed INT32) |
| `DIM_W` | 16 | fixed | Width of the M/K/N dimension config registers |

The RTL is written as a single `N×N`-generic array (`AH = AW` in v1); it is
verified at 4×4 and synthesized at 8×8.

### 1.2 Constraints (v1 scope guards)

- `M`, `K`, `N` must each be a non-zero multiple of the array dimension.
  Arbitrary sizes via tiling with edge-padding is future work.
- Streaming interfaces only; no memory-mapped DMA.
- Output is raw INT32. ReLU + requantization to INT8 is a specified but
  optional output stage (§7), gated by a config bit, stretch goal for RTL.

### 1.3 Why weight-stationary

Weights are reused across all `M` rows of activations, so pinning a weight
tile in the array amortizes one weight load over `M` MACs per PE. This is the
dataflow used by the TPU and most inference accelerators, and it minimizes
the highest-bandwidth operand path (weights never move during compute).

---

## 2. Block diagram

```
                ┌─────────────────────────────────────────────────────┐
                │                    gemm_top                         │
 s_axis_w ─────▶│  ┌──────────────┐                                   │
 (weights)      │  │ Weight buffer│  wcol[AW]   ┌─────────────────┐   │
                │  │ (double bank:│────────────▶│                 │   │
                │  │  W0 / W1)    │  (preload)  │  AH×AW systolic │   │
                │  └──────────────┘             │  PE array       │   │
 s_axis_a ─────▶│  ┌──────────────┐  arow[AH]   │  (weight-       │   │
 (activations)  │  │ Input skew   │────────────▶│   stationary)   │   │
                │  │ registers    │  (staggered)│                 │   │
                │  └──────────────┘             └────────┬────────┘   │
                │                                        │ psum[AW]   │
                │  ┌──────────────┐             ┌────────▼────────┐   │
 cfg (regs) ───▶│  │ Control FSM  │             │ Output deskew + │   │
 start/done ◀──▶│  │ + counters   │             │ (opt) ReLU/quant│───┼──▶ m_axis_c
                │  └──────────────┘             └─────────────────┘   │  (results)
                └─────────────────────────────────────────────────────┘
```

---

## 3. Processing element (PE)

Each PE holds one stationary weight and forwards activations east and partial
sums south.

Per-cycle behavior (when `en` asserted):

```
a_out    <= a_in;                          // activation moves east
psum_out <= psum_in + a_in * w_reg;        // INT8*INT8 → INT16, + INT32 → INT32
w_reg    <= w_load ? w_in : w_reg;         // weight capture (load phase only)
```

- Multiply: signed 8×8 → signed 16-bit product, sign-extended to 32 bits
  before addition. All arithmetic is two's-complement.
- **Accumulator width justification:** worst-case single product magnitude is
  `(-128)×(-128) = 16384 = 2^14`. Summing `K` products needs
  `14 + ceil(log2(K))` bits plus sign. INT32 is safe for any
  `K ≤ 2^(31-14) = 131072`, far beyond v1's `K ≤ 65535` (DIM_W=16). The
  golden model asserts this bound; RTL adds an SVA for it.
- Weight loading uses the same vertical `psum`/dedicated `w_in` path,
  shifting a column of weights in over `AH` cycles per bank (no extra
  horizontal wiring).

---

## 4. Dataflow and timing

### 4.1 Tile schedule

With `AH=AW=n`, the operation is decomposed into weight tiles
`B[kt·n:(kt+1)·n, nt·n:(nt+1)·n]` for `kt ∈ [0, K/n)`, `nt ∈ [0, N/n)`.
For each tile, all `M` rows of the corresponding activation column-block
`A[:, kt·n:(kt+1)·n]` stream through. Partial results for a given `nt` are
accumulated across the `kt` loop in the output accumulation RAM (§5.3);
the tile loop order is `for nt: for kt:` so each output column-block is
finished, drained, and its accumulator RAM reused.

### 4.2 Skewed wavefront

Row `i` of the activation block enters PE row `i` delayed by `i` cycles
(input skew registers), so the diagonal wavefront meets the correct partial
sums. Column `j` of results emerges from the bottom of the array delayed by
`j` cycles and is deskewed before the output stage.

Timing for one `M`-row pass through one tile (array `n×n`):

```
cycle:      0 ... n-1 | n ... n+M-1        | ... n+M+n-2 | +n-1 more
            ──────────┼────────────────────┼─────────────┼──────────
weights:    load col  |  (next bank preloading in shadow)|
activations:          | rows 0..M-1 enter  | pipe drain  |
results:              |                    | rows emerge | last col
```

- Fill latency: `n-1` cycles (skew) + `n` cycles (vertical depth).
- Steady state: **one result row per cycle** — `n` MACs/PE-row · `n` rows
  = `n²` MACs/cycle (128 GOPS at 8×8, 1 GHz, counting mul+add).
- Weight preload of the next tile happens during compute (double buffer, §5.2),
  so back-to-back tiles lose zero cycles when `M ≥ n`.

> **Correction (Phase 2 RTL).** The `M ≥ n` bound above is the condition for the
> weight tile to *arrive* in time. It is not sufficient for the commit. With one
> shadow register per PE, a weight shift cycle moves every row's shadow down, so
> `PE[i][j]`'s shadow is destroyed on the *first* shift cycle of column `j` —
> not when its own row arrives. The commit ripples diagonally to `PE[i][j]` at
> cycle `L+i+j`, so the next load cannot start until `L+n`. Combined with the
> settle deadline `s0 ≤ L−n`, back-to-back tiles are free only when **`M ≥ 2n`**.
>
> Two consequences, both implemented in `rtl/`:
> 1. The weight load is *skewed by column* (delay `j` on column `j`), putting it
>    on the same diagonal as the commit. Without this the bound is `M ≥ 3n−1`.
> 2. For `M < 2n` the controller withholds the tile's last activation row until
>    the shadow is ready, inserting a bubble in the activation stream while the
>    array keeps clocking. Measured overhead is constant in the tile count for
>    `M ≥ 2n` and grows only for `M < 2n`.
>
> See the timing budget comment at the top of `rtl/gemm_ctrl.sv`.

---

## 5. Memories

### 5.1 Input skew registers
Triangular register file, `Σ i for i in [0,n)` = `n(n-1)/2` bytes. Not a RAM.

### 5.2 Weight buffer (double-banked)
Two banks of `n×n` INT8 (64 B each at 8×8). While bank X drives the array,
bank Y is filled from `s_axis_w`. Bank swap occurs at tile boundaries under
FSM control. If the next tile hasn't fully arrived at swap time, the FSM
stalls compute (back-pressure propagates to `s_axis_a` via `tready`).

### 5.3 Output accumulation RAM
`M_max_tile × n` × INT32. Because `kt` is the inner loop, partial sums for the
current output column-block are read-modify-accumulated here across `kt`
iterations, then streamed out and cleared. v1 sizes this for
`M ≤ 256` rows per pass (8×8: 256×8×4 B = 8 KiB); larger `M` is future work
(outer-M tiling).

---

## 6. Interfaces

### 6.1 AXI-Stream (all: `tvalid`/`tready`/`tdata`/`tlast`, 8-byte `tdata` at n=8)

| Port | Dir | Contents | Order |
|---|---|---|---|
| `s_axis_w` | slave | one weight tile column per beat (`n` INT8) | column-major within tile; tiles in schedule order (§4.1) |
| `s_axis_a` | slave | one activation row-slice per beat (`n` INT8) | row-major within column-block; block repeats per `kt` |
| `m_axis_c` | master | one result row-slice per beat (`n` INT32 → 2 beats at n=8, or widened bus; v1: `n·32`-bit bus, 1 beat/row) | row-major per output column-block |

`tlast` marks the final beat of each tile (`s_axis_w`), each activation block
(`s_axis_a`), and the final result of the whole GEMM (`m_axis_c`). Standard
AXI-Stream rules apply: no `tdata` change while `tvalid && !tready`; `tvalid`
may not wait on `tready`.

### 6.2 Configuration registers

| Reg | Bits | Access | Description |
|---|---|---|---|
| `CTRL` | 0: `start`, 1: `quant_en` (stretch) | RW | write-1 to start; ignored while busy |
| `STATUS` | 0: `busy`, 1: `done` (W1C) | RO/W1C | |
| `DIM_M`, `DIM_K`, `DIM_N` | 15:0 | RW | matrix dims; sampled at `start` |
| `QPARAM` (stretch) | 31:8 multiplier, 7:0 shift | RW | requantization constants (§7) |

v1 exposes these as simple parallel inputs latched on `start` (a full
AXI-Lite slave is a wrapper-level nicety, not core scope).

### 6.3 Control FSM

```
IDLE ──start──▶ LOAD_W0 ──bank ready──▶ COMPUTE ──last row──▶ DRAIN ─┐
  ▲                                      ▲   │ (next tile? swap bank) │
  │                                      └───┘                        │
  └────────────────────────── all tiles done ──▶ DONE ────────────────┘
```

Illegal-transition and one-hot-state assertions are part of the Phase 3
verification plan.

---

## 7. Output stage (stretch): ReLU + requantization

When `CTRL.quant_en=1`, each INT32 result `acc` is mapped to INT8:

```
x   = max(acc, 0)                       # ReLU
y   = round_half_up((x * MULT) >> SHIFT) # fixed-point scale, MULT: 24-bit unsigned,
                                         # SHIFT: 0–31; rounding: add (1 << (SHIFT-1)) before shift
out = clamp(y, -128, 127)                # saturate (post-ReLU: effectively 0..127)
```

This matches the golden model's `requantize()` exactly (including the
`SHIFT=0` no-rounding case). Rounding mode is round-half-up on the
non-negative post-ReLU value, chosen because it is one adder — cheaper than
round-to-nearest-even and bit-exact reproducible in NumPy.

---

## 8. Verification hooks (forward references to Phase 3)

- Golden model produces bit-exact `C` for any legal (M, K, N, seed);
  `model/generate_vectors.py` emits `.memh` stimulus/expected files consumed
  by the cocotb testbench.
- The golden model also includes a cycle-level systolic simulator
  (`SystolicArraySim`) that reproduces the §4.2 schedule, used to
  cross-check RTL latency/ordering, not just values.
- Key assertions to carry into RTL: accumulator-overflow bound (§3),
  AXI-Stream handshake stability (§6.1), FSM legality (§6.3).
