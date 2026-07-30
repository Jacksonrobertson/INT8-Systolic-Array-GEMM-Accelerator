# Viewing Waveforms

How to look at a single GEMM in GTKWave, and what was added to make that
practical. Companion to `docs/PHASE3_VERIFICATION.md`, which covers the cocotb
regression itself.

---

## 1. Quick start

```bash
sudo apt install gtkwave     # once; the repo assumes it is on PATH
sim/wave.sh                  # smallest real matmul: 2x2 * 2x2 on a 2x2 array
```

That builds the DUT with tracing on, runs one GEMM, generates a save file and
opens GTKWave. The default case is 29 clock cycles and a 40 KB VCD — small
enough to read every transition on one screen.

```bash
sim/wave.sh -d 4x4x4                 # one 4x4 tile
sim/wave.sh -d 8x4x4                 # two activation tiles down a 4x4 array
sim/wave.sh -d 4x8x4 -q              # two K tiles, requantized output
sim/wave.sh -v full                  # same run, all 82 traces
sim/wave.sh -t test_bubble_path -n 4 # a named regression test instead
sim/wave.sh -d 2x2x2 -- --seed 1     # anything after -- goes to run.py
sim/wave.sh -h                       # option summary
```

| Option | Meaning |
|---|---|
| `-d MxKxN` | GEMM dimensions, default `2x2x2` |
| `-n SIZE` | array size; defaults to `K`, so `-d` alone gives a single-tile GEMM |
| `-t TEST` | run a named test from `test_gemm_top.py` instead; `-d` is ignored |
| `-v VIEW` | `control` (default) or `full` |
| `-q` | enable requantization (`WAVE_MULT` / `WAVE_SHIFT` to tune) |

Bad arguments are rejected before any simulation starts, so a typo costs a
second rather than a confusing SVA failure.

## 2. Pick a small case

Dump size drives readability more than anything else:

| Run | Cycles | VCD |
|---|---|---|
| `sim/wave.sh` (2×2·2×2, N=2) | 29 | 40 KB |
| `sim/wave.sh -d 8x4x4` (N=4) | 45 | 129 KB |
| `python tb/cocotb/run.py -n 4 --waves` (all 8 tests) | 5,240 | 11 MB |

A plain `run.py --waves` puts **every test in one dump**. GTKWave opens zoomed
to the full extent, so the GEMM you actually wanted is under 1% of the window
and reads as a solid blur. `wave.sh` always constrains itself to a single test
for that reason, and deletes the previous dump first so you can never be
looking at a stale one.

### The array size must be a power of two

`2x2x2` is the floor. Tile counts are computed as `>> $clog2(N)` and
`gemm_ctrl.sv` asserts `cfg_k[LOG2N-1:0] == '0`, so **N=3 cannot work** — it
fires that assertion a few nanoseconds in rather than producing a smaller
waveform. `wave.sh` rejects a non-power-of-two size up front.

`M` is the one dimension that need not be a multiple of the array size; `K`
and `N` must be.

## 3. What you are looking at

Two views, both generated into `sim/build/cocotb_n<N>/<view>.gtkw`:

- **`control`** (default, 41 traces) — the control signals that drive one
  GEMM, each placed next to the data it governs.
- **`full`** (82 traces) — adds the weight-loader FSM, flow control,
  weight-buffer internals, the skew network's edges, both accumulator ports
  and lane 0 of the requantizer.

The `control` view reads top to bottom as the story of one GEMM:

| Group | What it answers |
|---|---|
| command | `start` → `busy` → `done`, and the dimensions latched |
| FSM and tile counters | `state`, `kt`/`nt`, `row_cnt` |
| weights in | stream handshake → `w_shift_en` / `swap_bcast` → `PE[0][0].w_reg` landing |
| activations in | stream handshake → `a_valid` / `a_row` → `swap_row` diagonal commit |
| PE[0][0] arithmetic | `a_in`, `prod`, `psum_in`, `psum_out` in signed decimal |
| array out | `c_valid` / `c_row` → `in_first` / `in_last` |
| result out | `tvalid` / `tready` / `tdata` / `tlast` |

Both FSMs are one-hot and shown in hex, so they read directly:

| `u_ctrl.state` | | `u_ctrl.wl_state` | |
|---|---|---|---|
| `01` | `S_IDLE` | `1` | `WL_IDLE` |
| `02` | `S_LOAD_W` | `2` | `WL_SHIFT` |
| `04` | `S_SWAP` | `4` | `WL_SETTLE` |
| `08` | `S_COMPUTE` | | |
| `10` | `S_DRAIN` | | |
| `20` | `S_DONE` | | |

### Number formats

Counters, dimensions, addresses and tags are shown in **decimal**; genuine
signed scalars (`w_reg`, `w_shadow`, `a_in`, `prod`, `psum_in/out`, `acc`, `q`)
in **signed decimal**.

Packed buses stay **hex** — `tdata`, `a_row`, `c_row`, `w_row` and
`psum_south` each carry N independent lanes, so one decimal reading of the
whole bus would be meaningless. Read the lanes off the hex digits: at N=4,
`a_row[31:0]` is four INT8 operands, two hex digits each, lane 0 in the low
byte.

**Per-lane decimal cannot be put in a save file** — see §5. To get it, select
the trace in the GUI and use *Edit → Data Format*, which applies to the whole
bus, or add the individual lanes by hand from the signal tree.

## 4. Regenerating and reopening

The dump and save file persist, so you can reopen without re-simulating:

```bash
gtkwave sim/build/cocotb_n2/dump.vcd sim/build/cocotb_n2/control.gtkw
```

To change which signals appear, edit the `CONTROL` / `FULL` layout lists at the
top of `sim/waves/gen_gtkw.py` and rerun `sim/wave.sh`. The generator reports
any signal a layout names that the VCD does not contain, so an RTL rename
surfaces as a message rather than a silently missing trace.

Both the dump and the generated save file live under `sim/build/`, which is
already gitignored.

## 5. GTKWave save-file gotchas

These cost real time to find, all confirmed against **GTKWave 3.3.116** by
round-tripping a handcrafted save file through GTKWave (`-S` Tcl, write the
save file back out) and keeping only what survived. This is why the save files
are generated instead of checked in.

1. **A vector needs its full declared range.** `TOP.cfg_m[15:0]` binds the
   16-bit vector; a bare `TOP.cfg_m` silently binds a *single bit*. Since the
   ranges move with the array size N, a static save file cannot be correct at
   more than one N.
2. **A partial slice is dropped without warning.** `c_row[31:0]` on a `[63:0]`
   signal simply disappears from the loaded file. Hence no per-lane traces.
3. **A 1-bit signal must carry no range at all**, even when the VCD declares
   one. At N=2, `$clog2(N)`-wide signals appear as `wire 1 ... [0:0]`, and
   emitting that range drops the trace. `gen_gtkw.py` therefore keys off the
   declared *width*, not the presence of a range.

Trace-flag values, same method — the flag line precedes the traces it applies
to:

| Flag | Format |
|---|---|
| `@28` | single bit |
| `@22` | hex |
| `@24` | decimal |
| `@824` | signed decimal |
| `@200` | group label (the following `-name` line) |

### Two Verilator/cocotb wrinkles

Worth knowing if you drive Verilator directly rather than through `wave.sh`:

- cocotb 1.9's Verilator runner passes plain `--trace`, so the dump is **VCD**
  at `sim/build/cocotb_n<N>/dump.vcd` — not the FST that `run.py --waves`'s
  help text implies.
- The harness emits an **unnamed root scope**, which leaves every hierarchical
  path starting with a bare `.`. `wave.sh` rewrites that scope to `TOP` before
  launching, which is what the generated save files assume.

## 6. What was added

| File | Change |
|---|---|
| `sim/wave.sh` | new — build, run one GEMM with tracing, generate the save file, open GTKWave |
| `sim/waves/gen_gtkw.py` | new — generate a save file from a VCD with correct bit ranges; holds the `control` and `full` layouts |
| `tb/cocotb/run.py` | added `--testcase` to run a single test; forwards the `WAVE_*` environment variables |
| `tb/cocotb/test_gemm_top.py` | added `test_wave_custom`, a GEMM at caller-chosen dimensions, skipped unless `WAVE_DIMS` is set |
| `docs/PHASE3_VERIFICATION.md` | §7 points here |

`test_wave_custom` is gated on `WAVE_DIMS`, so it is skipped in a normal
session and the regression is unchanged: `python tb/cocotb/run.py --seed 42`
gives 8 pass / 1 skip at both N=4 and N=8 with functional coverage closed.

Verification of the save files themselves: both views were round-tripped
through GTKWave at N=2 and N=4, with 41/41 and 82/82 traces surviving at both
sizes and all four number formats intact.
