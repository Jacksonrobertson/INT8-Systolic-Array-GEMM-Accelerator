# Phase 2 — RTL Implementation Report

**Scope:** SystemVerilog RTL for the accelerator specified in [SPEC.md](SPEC.md),
built bottom-up and verified at each level against the Phase 1 golden model.

**Status:** complete. 15/15 testbenches pass, RTL is lint-clean under Verilator
`-Wall`, and the end-to-end vector suite passes at 4×4 and 8×8 across six
stall/quantization combinations.

---

## 1. What was built

| File | Lines | Purpose |
|---|---:|---|
| `rtl/gemm_pkg.sv` | 32 | Shared widths, overflow bound, one-hot FSM states |
| `rtl/pe.sv` | 99 | INT8 MAC, weight register + shadow, dual commit paths |
| `rtl/pe_array.sv` | 67 | `N×N` PE grid, per-column weight shift enables |
| `rtl/skew_buffer.sv` | 49 | Triangular delay; input skew, output deskew, weight-load skew |
| `rtl/systolic_array.sv` | 149 | Skew + grid + deskew; clean row-in/row-out datapath |
| `rtl/weight_buffer.sv` | 80 | Double-banked tile buffer; **the column→row transposer** |
| `rtl/accum_ram.sv` | 94 | Read-modify-accumulate across the `kt` loop |
| `rtl/gemm_ctrl.sv` | 335 | Tile schedule FSM + concurrent weight loader |
| `rtl/gemm_top.sv` | 306 | AXI-Stream plumbing, stall model, output register |
| `rtl/requant_unit.sv` | 49 | ReLU + fixed-point requantization (SPEC §7) |

Testbenches (`tb/`, 1176 lines) and the Verilator build (`sim/Makefile`)
accompany these, plus two vector generators added to `model/`.

## 2. Key design decisions

### Timing contract derived from the model, not from prose

The PE recurrence was taken from `SystolicArraySim.run()`'s index algebra rather
than from the spec text, because one detail matters and is easy to get backwards:
**the multiply consumes the activation arriving this cycle, not the registered
one.** From that, activation at `PE[i][j]` on cycle `t` is row `r = t−i−j`,
column `j`'s result for row `r` emerges at `t = r+n+j`, so output deskew delays
column `j` by `n−1−j` and the fill latency is `2n−1`.

None of this is asserted against a hand-derived constant. `model/generate_array_vectors.py`
reads the first-emergence cycle out of the simulator's own `emergence_log` and
writes it into `params.txt`; the testbench then requires result row `r` to land
on exactly `latency+r`. A pipeline that produced right answers in the wrong
order, or with a bubble, still fails.

### The weight buffer is the transposer

`s_axis_w` delivers one tile **column** per beat (`generate_vectors.py` beat `j`
is `B[kt·n:(kt+1)·n, nt·n+j]`), but the array shifts weights down through its
columns and consumes one tile **row** per cycle. The double-banked buffer
absorbs that mismatch: written column-wise, read row-wise. Getting this backwards
yields a transposed tile, which still produces plausible INT32 results — so it is
tested directly with row/column-tagged data where an error shows as swapped
nibbles rather than as noise.

Rows are pushed **deepest-first** (row `N−1` first), since the first value into a
downward shift chain travels furthest.

### Single global clock enable, with two deliberate exceptions

One `core_en` gates the datapath and the FSM together. Freezing everything at
once is what makes the skewed wavefront safe to interrupt — partial sums in
flight, both skew triangles, and the tile counters all hold their relative
positions.

The two exceptions are load-bearing:

1. **The weight fill path runs outside `core_en`.** Weights for the next tile
   must keep arriving while the core is stalled; that is the entire purpose of
   the double bank. Only the bank *swap* is gated, since that is the handover
   point to the frozen side.
2. **The output register runs outside `core_en`** (see §4).

## 3. Verification approach

Each level was verified before the next was built.

| Level | Checked against |
|---|---|
| `pe`, `skew_buffer` | Directed tests: MAC recurrence, signed corners incl. `(−128)²`, stall freeze, both commit paths |
| `systolic_array` | `SystolicArraySim` — values **and** per-cycle emergence order |
| `weight_buffer`, `accum_ram` | Transpose correctness, double-bank isolation, RMW across `kt`, stall mid-flight |
| `gemm_top` | 7 vector cases at 4×4 and 8×8, every result beat and `tlast` |
| `requant_unit` | `requantize()` — 3612 cases |

**Testbenches were mutation-tested rather than trusted because they were green.**
Each of these was injected and confirmed to fail:

- reversed weight push order (ascending instead of descending)
- transposed weight write in the buffer → caught as `0x10` vs `0x01`
- one wide add instead of lane-wise adds in the accumulator → caught as lane 3
  off by 2, from carries leaking across lane boundaries
- dropped shadow-ready guard in the controller → caught by SVA

Assertions (SPEC §8) are compiled in via `+define+SIM_ASSERT`: accumulator
overflow (computed one bit wide and required to be pure sign extension),
AXI-Stream handshake stability on all three streams, FSM one-hot plus per-state
legal-transition checks.

## 4. Bugs found and fixed

### Duplicate output beats under combined backpressure

When output backpressure coincided with input starvation, `c_fire` could complete
while `core_en` was low. The accumulator stayed frozen with `out_valid` asserted,
so a ready consumer accepted the same row on every stalled cycle.

Deasserting `tvalid` would fix it but violates AXI-Stream, which requires
`tvalid` to stay asserted once raised until `tready` completes the handshake. The
fix is a one-deep output register that decouples `m_axis_c` from `core_en`. Since
`core_en` already includes `out_blocked`, `core_en && acc_out_valid` guarantees
that register can accept — the transfer needs no separate handshake. There is now
an SVA for exactly this property.

### A lint waiver that would have hidden a class of testbench bugs

Verilator executes `<=` inside an `initial` block **as a blocking assignment**.
Combined with the scheduler behaviour in §6, that silently reintroduces stale
combinational reads in any testbench using the readable `initial`-driver style.
`INITIALDLY` had been waived pre-emptively; it is now deliberately **not** waived,
with a comment in `sim/tb_waivers.vlt` explaining that keeping it a hard error is
what forces stimulus into `always_ff` drivers.

## 5. Correction to SPEC §4.2 — zero-bubble requires `M ≥ 2n`

The spec states back-to-back tiles lose zero cycles when `M ≥ n`. That is the
condition for the tile to *arrive*; it is not sufficient for the commit.

With one shadow register per PE, **a weight shift cycle moves every row's shadow
down one**, so `PE[i][j]`'s shadow is destroyed on the *first* shift cycle of
column `j` — not when its own row arrives. This was the subtlest issue in the
build; the initial analysis conflated the two and produced silently wrong weights
in the deepest PE row only.

Writing `L_T` for the cycle tile `T`'s last activation row is injected and `s0`
for the start of tile `T+1`'s shift:

- **settle:** `s0 ≤ L_T − n` — column `j` finishes at `s0+j+n−1`, `PE[0][j]`
  commits at `L_T+j`
- **no clobber:** `s0 ≥ L_{T−1} + n` — the previous commit ripples to `PE[i][j]`
  at `L_{T−1}+i+j`

With `L_T = L_{T−1}+M` the window `[L_{T−1}+n, L_{T−1}+M−n]` is non-empty exactly
when **`M ≥ 2n`**.

Two consequences, both implemented:

1. **The weight load is skewed by column** (delay `j` on column `j`, reusing
   `skew_buffer`), putting it on the same diagonal as the commit. Without this
   the bound degrades to `M ≥ 3n−1`.
2. **For `M < 2n` the controller withholds the tile's last activation row** until
   the shadow is ready. This inserts a bubble in the *activation stream* while
   the array keeps clocking — lowering `core_en` instead would freeze the very
   shift being waited on, and deadlock.

`tight_4x4` and `tight_8x8` were added to `model/generate_vectors.py` because
every original vector case was either single-tile or `M ≥ 2n`, leaving the
bubble-insertion path with no coverage.

### Measured result

Overhead beyond the ideal one-row-per-cycle stream, from `gemm_top_tb`:

| Case | M, K, N, n | Tiles | Cycles | Ideal | Overhead |
|---|---|---:|---:|---:|---:|
| `smoke_4x4` | 4, 4, 4, 4 | 1 | 31 | 4 | 27 |
| `multi_tile_4x4` | 8, 12, 8, 4 | 6 | 75 | 48 | **27** |
| `tight_4x4` | 4, 8, 8, 4 | 4 | 53 | 16 | 37 |
| `smoke_8x8` | 8, 8, 8, 8 | 1 | 55 | 8 | 47 |
| `large_8x8` | 64, 32, 16, 8 | 8 | 559 | 512 | **47** |
| `tight_8x8` | 8, 16, 16, 8 | 4 | 97 | 32 | 65 |

Overhead is **constant in the tile count** for `M ≥ 2n` — six tiles cost the same
as one — which is the zero-bubble property measured directly. Only the `tight_*`
cases (`M < 2n`) pay a per-handover bubble, as predicted.

## 6. Environment note

`sudo` requires a password unavailable to the build, so Verilator 5.020 was
installed userspace: `apt-get download verilator` + `dpkg-deb -x` into
`~/.local/opt/verilator`, with `~/.local/bin/verilator` as a wrapper setting
`VERILATOR_ROOT`. The `.deb` layout needs `verilator_bin` symlinked into
`$VERILATOR_ROOT/bin/`.

One scheduler behaviour shapes every testbench here: under `--timing`, a DUT
input written with a **blocking** assignment from a delayed process does not
propagate through combinational paths until the next clock event, so the output
reads a full cycle stale. This was reduced to a 12-line probe — same design, same
values, blocking driver stale, clocked NBA driver correct. All testbenches
therefore drive inputs from `always_ff` with `<=` and sample at `negedge`.

## 7. Running it

Requires Verilator 5.x.

```bash
cd sim
make                  # lint + all 15 testbenches
make lint             # RTL lint only (-Wall)
make top STALL=30     # end-to-end with 30% random stream stalls / backpressure
make top QUANT=1      # end-to-end through the INT8 output stage
```

Regenerate vectors after changing the model:

```bash
python -m model.generate_vectors           # end-to-end cases (+ quantized expected)
python -m model.generate_array_vectors     # array-level cases with model timing
python -m model.generate_requant_vectors   # 3612 requantization cases
```

## 8. Known limitations

- `M ≤ M_MAX = 256` rows per pass (SPEC §5.3). Outer-M tiling is future work.
- `M`, `K`, `N` must be non-zero multiples of `n`; edge padding is not implemented.
- The accumulation RAM is inferred, not a Sky130 macro — a Phase 4 concern.
- `tlast` on the inbound streams is accepted but ignored; the schedule is driven
  by the configured dimensions, not by stream framing.
- Phase 3's cocotb layer is still open. SystemVerilog testbenches were used for
  bring-up, as planned; the SVA and vector regression it called for are done.
