# Dataflow: Streams, Buffering, and the Weight Transpose

How data physically gets into and out of the accelerator: the three AXI-Stream
channels, what each byte position of `tdata` means, why weights are buffered
and activations are not, and exactly where the weight transpose happens.

Companion to [CONTROL.md](CONTROL.md), which covers the state machines, the
handshake signals and the stall network. Where the two overlap, CONTROL.md §3
is authoritative for **beat ordering and handshake timing**; this document
covers **layout and movement**.

---

## 1. Three channels, not one multiplexed bus

The design has three physically separate AXI-Stream interfaces, each with its
own `tvalid`/`tready`/`tdata`/`tlast`. They are not time-multiplexed and do not
take turns.

| Channel | Dir | Width @ N=8 | Destination | Buffered? |
|---|---|---|---|---|
| `s_axis_w` | in | `N*8` = 64 b | `weight_buffer` | yes — 2 banks × N rows |
| `s_axis_a` | in | `N*8` = 64 b | skew triangle → PE grid | **no** |
| `m_axis_c` | out | `N*32` = 256 b | from `accum_ram` | 1-deep output register |

Configuration is not AXI at all: `start`, `cfg_m/k/n`, `cfg_quant_en`,
`cfg_mult` and `cfg_shift` are plain parallel registers latched on
`S_IDLE && start`.

There are no packets, headers, line encoding, routing or credit counters. One
synchronous clock domain, one beat per cycle, and the entire protocol is
`tvalid && tready`.

### 1.1 They overlap in time

Tile T's weights must be resident before tile T's activations are consumed —
that ordering is real — but the *streams* run concurrently. In steady state all
three buses are busy on the same cycle:

```
          ┌─ weights for tile T+1 filling the spare bank
cycle t ──┼─ activations for tile T entering the array
          └─ results from an earlier tile leaving
```

That overlap is the entire purpose of the double bank and the `2N-1` pipeline.
Rough timeline at N=4:

```
s_axis_w   ████ ████ ─────backpressured (fill_full)───── ████ ...
           tile0 tile1                                    tile2

s_axis_a   ──── ──── ██████████████████████████████████ ...
           (tready low: not in S_COMPUTE)   tile0 rows, then tile1 rows, ...

m_axis_c   ──── ──── ─────────  2N+1 latency  ─────────── ████████ ...
```

`s_axis_w` runs *ahead*: it delivers tile 0 and tile 1 back to back, then
`col_ready` drops because both banks are occupied, and stays low until the
loader swaps again. Backpressure is per channel — the weight producer being
stalled by `fill_full` has no effect on the activation channel.

### 1.2 What a producer has to know

Neither producer needs any knowledge of the FSMs, the tiles or the timing. Each
pushes beats in a fixed order and honours `tready`:

- **`s_axis_w`** — `for nt: for kt:` then `j = 0..N-1`, one tile *column* per beat
- **`s_axis_a`** — `for nt: for kt:` then `r = 0..M-1`, one row-slice per beat
  (the A block is re-sent once per `nt`)
- **`m_axis_c`** — `for nt:` then `r = 0..M-1`, one result row-slice per beat,
  `tlast` on the final beat of the GEMM

Beat order plus `tready` is the whole contract. All scheduling — when to swap
banks, when to shift, when to commit, when to stall — is inferred inside the
accelerator from `fill_full`, `a_fire` and the configured dimensions. That
contract is encoded independently by `model/generate_vectors.py`, the checked-in
`.memh` vectors and the cocotb BFMs in `tb/cocotb/axis.py`, which is how a
mismatch gets caught.

---

## 2. What a "lane" means here

Throughout these docs, *lane* means a fixed byte field of `tdata`. This is
**addressing, not striping** — the analogy to bonded serial links (PCIe lanes,
where bytes are sprayed round-robin and reassembled at the receiver, and lane
index carries no meaning) does not hold.

AXI-Stream has no lane concept of its own: `tdata` is one wide parallel word
transferred on a single clock edge. What makes the byte positions meaningful is
that each maps to a fixed physical location in the array:

| Channel | field `[i*W +: W]` means | goes physically to |
|---|---|---|
| `s_axis_a` | K index `i` | PE **row** `i` (west edge) |
| `s_axis_w` | row `i` of that tile column | `mem[bank][i]` |
| `m_axis_c` | output column `j` (32-bit fields) | from PE **column** `j` (south edge) |

Byte positions therefore cannot be permuted, and the word cannot be serialised
without losing the mapping. It is closer to a SIMD vector register or a wide
DDR bus than to a bonded serial link.

Lane 0 is always in the LSBs (`model/generate_vectors.py:_pack_hex`).

---

## 3. Why weights are buffered and activations are not

This is the "weight-stationary" part of the architecture.

- A **weight** `B[i][j]` sits in `PE[i][j]` and is reused by every activation
  row that passes through — M rows over M cycles, at one fixed location. It
  must be *resident* before compute starts. Hence: buffer, shift chain, shadow
  register, commit.
- An **activation** element is a *wave*. It enters the west edge, is used once
  per cycle as it moves east across its row, and falls out the far side. It is
  reused N times too, but at N different PEs on N different cycles — and the
  thing carrying it between those uses is the `a_out` pipeline register inside
  each PE. The array's own registers already hold it in the right place at the
  right time.

Weights are stored *because they do not move*. Activations are not stored
*because they do*.

|  | Weights | Activations |
|---|---|---|
| On-chip storage | 2 banks × N rows, + a shadow register per PE | none |
| Wait policy | block until a full tile is buffered | consumed on arrival |
| If data is late | producer is backpressured (`col_ready`) | whole core freezes (`core_en`) |
| Alignment mechanism | skewed load + diagonal commit | skew triangle |
| Reuse | across M rows, in place | across N columns, in motion |

```
s_axis_w  ──► weight_buffer (2 banks)  ──► array      stored
s_axis_a  ─────────────────────────────► array      NOT stored
m_axis_c  ◄── 1-deep output register   ◄── accum     1 beat
```

The absence of activation storage is exactly why A must be re-streamed once per
output column-block: there is nowhere to keep it. The design trades
interconnect bandwidth for zero on-chip activation storage.

---

## 4. Load geometry: weights from the top, activations from the left

```
                    w_top  (weights, one tile ROW per cycle)
                      │ │ │ │
                      ▼ ▼ ▼ ▼
        a_west  ──►  ┌─┬─┬─┬─┐
     (activations,   ├─┼─┼─┼─┤   PE[i][j] holds B[i][j]
      one row-slice  ├─┼─┼─┼─┤     i = K dim (vertical)
      per cycle)     └─┴─┴─┴─┘     j = N dim (horizontal)
                      │ │ │ │
                      ▼ ▼ ▼ ▼
                    psum_south (results)
```

Partial sums also flow top to bottom, on wires separate from the weight shift
chain. Activations exit the east edge unused.

The weight bus `w_top` is `N*DW_IN` bits — one whole tile row, lane `j` = column
`j` (`pe_array.sv:57`). Each grid column is an independent vertical shift chain,
so the load is **N-wide parallel, N-deep serial**: N² weights land in N cycles
using only N input wires. A truly parallel load would need N² wires reaching
every PE, which is the register-file design a systolic array exists to avoid.

---

## 5. The weight transpose

### 5.1 Order of operations

| Stage | Layout |
|---|---|
| 1. `s_axis_w` beats | **column-major** — beat `j` = `B[kt*N:(kt+1)*N, nt*N+j]` |
| 2. `weight_buffer` write | **transposed here**, on the write port (`weight_buffer.sv:69-73`) |
| 3. buffer storage | **row-major** — `mem[bank][i]` is tile row `i`, lane `j` = column `j` |
| 4. buffer read | one row per cycle, **descending**: `rd_row = N-1-wl_cnt` |
| 5. into the grid | top edge, shifting down one row per cycle |

The transpose happens **before** the array, on the write side. By the time
anything reaches the grid it is already row-major.

The write is a parallel scatter — all N lanes of a beat on one clock edge, into
N different rows, at the same column offset:

```systemverilog
if (col_fire)
  for (int i = 0; i < N; i++)
    mem[fill_bank][i][col_cnt*DW_IN +: DW_IN] <= col_data[i*DW_IN +: DW_IN];
```

The read is parallel too: `w_row = mem[!fill_bank][rd_row]` returns a whole row,
all N lanes, combinationally. Both ports are fully parallel; the only asymmetry
is which dimension each addresses. That is the transpose, and it costs nothing
but wiring.

### 5.2 The PEs end up untransposed

The buffer transposes the *access pattern*, not the matrix, and the two cancel.
Final placement is `PE[i][j] = B[i][j]`, natural orientation.

Worked through at N=4:

```
tile B = [ b00 b01 b02 b03 ]
         [ b10 b11 b12 b13 ]
         [ b20 b21 b22 b23 ]
         [ b30 b31 b32 b33 ]
```

Beat 0 is column 0, `[b00 b10 b20 b30]`, lane `i` = `b_i0`. Scattered down the
bank rows at column offset 0. After 4 beats:

```
mem[bank][0] = [ b00 b01 b02 b03 ]   ← row 0
mem[bank][1] = [ b10 b11 b12 b13 ]
mem[bank][2] = [ b20 b21 b22 b23 ]
mem[bank][3] = [ b30 b31 b32 b33 ]
```

Row 3 is read first, `[b30 b31 b32 b33]`; lane `j` goes to grid column `j`.
Pushed first, it shifts down to PE row 3, so `PE[3][j] = b3j`. Then row 2 lands
in PE row 2, and so on — giving `PE[i][j] = b_ij`.

### 5.3 Why descending row order

The first value pushed into a shift chain travels furthest. For one column at
N=4:

| Shift cycle | Pushed into `PE[0][j]` | Ends up at |
|---|---|---|
| 0 | `B[3][j]` | `PE[3][j]` |
| 1 | `B[2][j]` | `PE[2][j]` |
| 2 | `B[1][j]` | `PE[1][j]` |
| 3 | `B[0][j]` | `PE[0][j]` |

All N columns shift together, each taking its own lane of the presented row —
staggered by `j` cycles by `u_skew_w`, but every column runs the identical
`row N-1 → row 0` sequence. Everything lands in `w_shadow`; the commit
(`swap_bcast` or the diagonal `swap_in`) is what makes it live. See CONTROL.md
§1 for why the load is skewed onto the commit diagonal.

### 5.4 The buffer as a per-column parallel-to-serial converter

The clearest way to see the buffer's job is to compare what arrives on the wire
with what one grid column consumes:

```
beat 0 delivered:  [b00, b10, b20, b30]   ← in parallel, one cycle
column 0 receives:  b30, b20, b10, b00    ← serially, one per cycle (reversed)
```

Same four values. Column `j`'s data comes from beat `j` and goes down grid
column `j` — nothing is permuted between the two. The stream hands over a column
all at once; the array wants it one element per cycle in reverse order. The
buffer converts.

This also explains the whole-tile wait: all N columns must shift **together**,
so all N beats must have arrived before any column can start. A partially
filled bank is not "some rows ready" — because a beat scatters one byte into
every row, a partial fill leaves *every* row incomplete:

```
after 3 of 8 beats:
mem[bank][0] = [w00 w01 w02  ?  ?  ?  ?  ? ]   ← row 0, 5 lanes stale
mem[bank][1] = [w10 w11 w12  ?  ?  ?  ?  ? ]
...
```

Hence `fill_full` gating the loader out of `WL_IDLE`, and the
`bank_swap |-> fill_full` assertion at `weight_buffer.sv:80`.

---

## 6. The activation path

There is no activation buffer anywhere in the design. A beat goes straight from
the bus into the skew triangle and through the grid.

### 6.1 The skew triangle is N delay lines, not a selector

`skew_buffer.sv:31-50` builds N independent shift registers; lane `i` has `i`
flops in front of it. There is no select, no per-lane enable and no discard —
all N lanes go in every cycle and all N come out every cycle. Nothing is
sampled selectively.

What can mislead is the shape of the *output* bus. With `dout` lane `i` equal to
`din` lane `i` from `i` cycles ago, the bus at any instant carries N **different
beats**:

```
                 lane0      lane1      lane2      lane3
  cycle 0        a[0][0]      0          0          0
  cycle 1        a[1][0]    a[0][1]      0          0
  cycle 2        a[2][0]    a[1][1]    a[0][2]      0
  cycle 3        a[3][0]    a[2][1]    a[1][2]    a[0][3]   ← steady state
  cycle 4        a[4][0]    a[3][1]    a[2][2]    a[1][3]
```

In steady state every lane is live every cycle; they simply belong to different
rows of A. That anti-diagonal **is** the wavefront. The zeros in the top-left
triangle are the pipeline filling, and `valid_sr` marks those results invalid on
the way out.

### 6.2 Why the skew is needed

A beat is `A[r, kt*N .. kt*N+N-1]` — N different **K** elements of the same row
`r`. Lane `i` is K index `i`, and `PE[i][j]` holds `B[i][j]` where `i` is also
the K index. The dot product is formed **vertically**: `PE[0][j]` contributes
`a[r][0]*b[0][j]`, `PE[1][j]` adds `a[r][1]*b[1][j]`, and the partial sum
accumulates as it flows south.

The partial sum moves down one row per cycle, so lane `i` must arrive at row `i`
exactly `i` cycles late or it meets the wrong psum. Hence `u_skew_a`:

```
beat r arrives at cycle r
        │
   lane 0 ──────────────────────────► PE row 0   at cycle r      (pure wire, D=0)
   lane 1 ──[1 reg]────────────────► PE row 1   at cycle r+1
   lane 2 ──[2 regs]──────────────► PE row 2   at cycle r+2
   lane 3 ──[3 regs]────────────► PE row 3   at cycle r+3
```

A single beat is therefore not consumed in one cycle. It is fanned out over N
cycles, and each lane then takes another N cycles to cross east — one beat is
smeared diagonally across the whole array. Tracking row `r` at N=4:

| Cycle | Where row `r`'s data is |
|---|---|
| `r` | lane 0 enters `PE[0][0]`; lanes 1-3 still in the skew triangle |
| `r+1` | lane 0 at `PE[0][1]`, lane 1 enters `PE[1][0]` |
| `r+2` | lane 0 at `PE[0][2]`, lane 1 at `PE[1][1]`, lane 2 enters `PE[2][0]` |
| … | the wavefront sweeps southeast |
| `r+N+j` | column `j`'s finished sum leaves the bottom of the grid |
| `r+2N-1` | `u_deskew_c` has realigned all columns → one complete result row |

### 6.3 Consequences of having no buffer

1. **Backpressure instead of buffering.** No storage to absorb a gap, so an
   absent beat freezes the whole datapath (`in_starved` → `core_en` low).
   Everything holds position and resumes coherently.
2. **`tready` is a hard ordering gate.** `a_stream` is only high in `S_COMPUTE`,
   so activations physically cannot enter before the first weight tile is
   committed.
3. **A is re-streamed per output column-block**, giving
   `M * (K/N) * (Ncols/N)` activation beats.

### 6.4 Where incomplete data is genuinely a concern

Two places, both handled by gating rather than lane selection:

- **A partially filled weight bank** — §5.4 above; gated at whole-tile
  granularity by `fill_full`.
- **A gap in the activation stream** — `a_gated = a_valid ? a_row : '0`
  (`systolic_array.sv:67`) forces zeros rather than admitting stale `tdata`,
  because an idle PE still computes `a_in * w_reg`. All N lanes are zeroed
  together, never a subset.

---

## 7. The result path

The mirror image of the activation path, and it needs no transpose either:
`psum_south` lane `j` is output column `j`, and `u_deskew_c` only realigns the
columns in time (lane `j` delayed `N-1-j`) so one complete row lands on one
beat. `m_axis_c` beat `r` is `C[r, nt*N:(nt+1)*N]` — a row-slice, the same
layout as the activation input.

With `cfg_quant_en`, each lane's INT32 is ReLU'd and requantized to INT8
combinationally as the row is captured into the output register, and the N bytes
are packed into the **low `N*8` bits** with the upper bits zero. The bus width is
unchanged so both modes share one interface.

See CONTROL.md §3.3 for the output register and `tlast` generation.
