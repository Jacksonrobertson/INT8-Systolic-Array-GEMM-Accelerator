// Control FSM and tile counters (SPEC sections 4.1 and 6.3).
//
// Runs the tile schedule `for nt: for kt:`. Two cooperating state machines:
//
//   main    streams M activation rows per tile, back to back across tiles.
//   loader  independently pulls the next tile out of the weight buffer and
//           shifts it into the array's shadow registers WHILE the current tile
//           computes. Handshake is a single flag, shadow_ready.
//
// Only the first tile of a GEMM uses a broadcast commit (S_LOAD_W/S_SWAP, with
// the array empty). Every later tile is committed diagonally: the main FSM
// raises swap_row on the tile's last activation row, and that token rides the
// skew network so each PE swaps on exactly the cycle it consumes that row.
// Back-to-back tiles therefore cost zero cycles.
//
// TIMING BUDGET
// Let L_T be the cycle tile T's last activation row is injected. Tile T+1's
// weights commit on that row, and its shift must start at s0 where:
//
//   settle      s0 <= L_T - N
//               Column j finishes loading at s0+j+N-1 and PE[0][j] commits at
//               L_T+j, so the whole shift must precede the commit by N.
//
//   no clobber  s0 >= L_{T-1} + N
//               A shift cycle moves EVERY row's shadow down one, so PE[i][j]'s
//               shadow is destroyed on the FIRST shift cycle of column j, not
//               when its own row arrives. Tile T's commit ripple runs until
//               L_{T-1}+2(N-1), and PE[i][j] of that ripple commits at
//               L_{T-1}+i+j, so the next shift must trail it by N.
//
// With L_T = L_{T-1}+M the window is [L_{T-1}+N, L_{T-1}+M-N], non-empty
// exactly when M >= 2N. (SPEC section 4.2 claims M >= n suffices; that holds
// only for the weight ARRIVAL, not for a single shadow register per PE.)
// hold_cnt below enforces the lower bound.
//
// For M < 2N the window is empty. Rather than special-case it,
// a_stream is simply withheld when the last row is due and shadow_ready is
// still low. That inserts a bubble in the ACTIVATION stream while the array
// keeps clocking, so the loader continues to make progress -- lowering core_en
// instead would freeze the very shift being waited on, and deadlock.
//
// Control outputs are combinational decodes of state and counters. A
// registered version is off by one at each of the weight-handoff boundaries.
module gemm_ctrl
  import gemm_pkg::*;
#(
  parameter int N     = 8,
  parameter int M_MAX = 256
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               core_en,

  // Configuration, sampled at start (SPEC section 6.2).
  input  logic               start,
  input  logic [DIM_W-1:0]   cfg_m,
  input  logic [DIM_W-1:0]   cfg_k,
  input  logic [DIM_W-1:0]   cfg_n,
  output logic               busy,
  output logic               done,

  // Weight buffer.
  input  logic               wb_fill_full,
  output logic               wb_bank_swap,
  output logic [$clog2(N)-1:0] wb_rd_row,

  // Array control.
  output logic               w_shift_en,
  output logic               swap_bcast,  // commit every PE (array empty)
  output logic               swap_row,    // commit diagonally, with this row
  output logic               a_stream,    // an activation beat is wanted now
  input  logic               a_fire,      // s_axis_a handshake completed
  output logic [1:0]         a_tag,       // {first kt, last kt}

  // Sampled dimensions, for the datapath.
  output logic [DIM_W-1:0]   dim_m,
  output logic [DIM_W-1:0]   dim_n,
  output state_e             state
);

  localparam int LOG2N     = $clog2(N);
  localparam int LATENCY   = 2 * N - 1;
  // After the final activation row: LATENCY for it to reach the deskew output,
  // plus the accumulator's 2 stages.
  localparam int DRAIN_CYC = LATENCY + 2;
  localparam int DRAIN_W   = $clog2(DRAIN_CYC + 1);
  localparam int SET_W     = $clog2(N + 1);
  localparam int HOLD_W    = $clog2(N + 1);

  typedef enum logic [2:0] {
    WL_IDLE   = 3'b001,
    WL_SHIFT  = 3'b010,
    WL_SETTLE = 3'b100
  } wl_state_e;

  logic [DIM_W-1:0]   m_q, k_q, n_q;
  logic [DIM_W-1:0]   kt, nt;          // tile being computed
  logic [DIM_W-1:0]   l_kt, l_nt;      // tile being loaded
  logic               l_done;          // every tile has been loaded
  logic [DIM_W-1:0]   row_cnt;
  logic [DRAIN_W-1:0] drain_cnt;
  wl_state_e          wl_state;
  logic [SET_W-1:0]   wl_cnt;
  logic               shadow_ready;    // shift issued; safe for a diagonal commit
  logic               shadow_settled;  // all columns settled; safe for a broadcast
  // Blocks the next shift until the previous diagonal commit has rippled past
  // the deepest PE row. Without it the shift clobbers shadows that later rows
  // have not committed yet. N-2 because the loader already spends one cycle in
  // WL_IDLE asserting bank_swap before the first shift cycle.
  logic [HOLD_W-1:0]  hold_cnt;

  wire [DIM_W-1:0] kt_max = (k_q >> LOG2N) - 1'b1;
  wire [DIM_W-1:0] nt_max = (n_q >> LOG2N) - 1'b1;

  assign dim_m = m_q;
  assign dim_n = n_q;

  // ---- tile bookkeeping --------------------------------------------------
  wire last_tile  = (kt == kt_max) && (nt == nt_max);
  wire last_row   = (row_cnt == m_q - 1'b1);
  wire need_swap  = last_row && !last_tile;   // hand over to the next tile here
  wire l_last     = (l_kt == kt_max) && (l_nt == nt_max);

  // ---- combinational control --------------------------------------------
  assign wb_bank_swap = (wl_state == WL_IDLE) && !shadow_ready && !l_done &&
                        (hold_cnt == '0) && wb_fill_full;
  assign w_shift_en   = (wl_state == WL_SHIFT);
  // Rows are pushed deepest-first: the first row shifted in travels furthest.
  assign wb_rd_row    = LOG2N'(N-1) - wl_cnt[LOG2N-1:0];

  assign swap_bcast   = (state == S_SWAP);
  // Withhold the last row until the next tile's weights are in the shadows.
  assign a_stream     = (state == S_COMPUTE) && !(need_swap && !shadow_ready);
  assign swap_row     = a_fire && need_swap;
  assign a_tag        = {kt == '0, kt == kt_max};

  // ---- sequencing --------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= S_IDLE;
      busy           <= 1'b0;
      done           <= 1'b0;
      m_q            <= '0;
      k_q            <= '0;
      n_q            <= '0;
      kt             <= '0;
      nt             <= '0;
      l_kt           <= '0;
      l_nt           <= '0;
      l_done         <= 1'b0;
      row_cnt        <= '0;
      drain_cnt      <= '0;
      wl_state       <= WL_IDLE;
      wl_cnt         <= '0;
      shadow_ready   <= 1'b0;
      shadow_settled <= 1'b0;
      hold_cnt       <= '0;
    end else if (core_en) begin

      if (hold_cnt != '0) hold_cnt <= hold_cnt - 1'b1;

      // ---- weight loader, concurrent with compute ----
      case (wl_state)
        WL_IDLE: if (!shadow_ready && !l_done && (hold_cnt == '0) && wb_fill_full) begin
          // wb_bank_swap is asserted combinationally this cycle; the buffer
          // presents the new drain bank from the next cycle, which is the
          // first cycle w_shift_en is high.
          wl_cnt   <= '0;
          wl_state <= WL_SHIFT;
        end

        WL_SHIFT: begin
          if (wl_cnt == SET_W'(N-1)) begin
            wl_cnt       <= '0;
            wl_state     <= WL_SETTLE;
            // N shift cycles issued. That is already enough for a diagonal
            // commit, whose per-column deadline moves with the same skew.
            shadow_ready <= 1'b1;
            if (l_last) begin
              l_done <= 1'b1;
            end else if (l_kt == kt_max) begin
              l_kt <= '0;
              l_nt <= l_nt + 1'b1;
            end else begin
              l_kt <= l_kt + 1'b1;
            end
          end else begin
            wl_cnt <= wl_cnt + 1'b1;
          end
        end

        // The load is skewed, so the last column settles N-1 cycles after the
        // source-side shift ends. Only a BROADCAST commit has to wait for that.
        WL_SETTLE: begin
          if (wl_cnt == SET_W'(N-2)) begin
            wl_cnt         <= '0;
            wl_state       <= WL_IDLE;
            shadow_settled <= 1'b1;
          end else begin
            wl_cnt <= wl_cnt + 1'b1;
          end
        end

        default: wl_state <= WL_IDLE;
      endcase

      // ---- main schedule ----
      case (state)
        S_IDLE: if (start) begin
          m_q            <= cfg_m;
          k_q            <= cfg_k;
          n_q            <= cfg_n;
          kt             <= '0;
          nt             <= '0;
          l_kt           <= '0;
          l_nt           <= '0;
          l_done         <= 1'b0;
          row_cnt        <= '0;
          wl_state       <= WL_IDLE;
          wl_cnt         <= '0;
          shadow_ready   <= 1'b0;
          shadow_settled <= 1'b0;
          hold_cnt       <= '0;
          busy           <= 1'b1;
          done           <= 1'b0;
          state          <= S_LOAD_W;
        end

        // First tile only: the array is empty, so it is committed by broadcast
        // and must wait for every column of the skewed load to settle.
        S_LOAD_W: if (shadow_settled) state <= S_SWAP;

        S_SWAP: begin
          shadow_ready   <= 1'b0;   // frees the loader to fetch the next tile
          shadow_settled <= 1'b0;
          row_cnt        <= '0;
          state          <= S_COMPUTE;
        end

        S_COMPUTE: if (a_fire) begin
          if (last_row) begin
            if (last_tile) begin
              drain_cnt <= '0;
              state     <= S_DRAIN;
            end else begin
              // Diagonal commit went out with this row; advance to the next
              // tile with no gap and release the loader.
              shadow_ready   <= 1'b0;
              shadow_settled <= 1'b0;
              row_cnt        <= '0;
              // Hold the loader off until this commit has rippled through.
              hold_cnt       <= HOLD_W'(N - 2);
              if (kt == kt_max) begin
                kt <= '0;
                nt <= nt + 1'b1;
              end else begin
                kt <= kt + 1'b1;
              end
            end
          end else begin
            row_cnt <= row_cnt + 1'b1;
          end
        end

        S_DRAIN: begin
          if (drain_cnt == DRAIN_W'(DRAIN_CYC - 1)) state <= S_DONE;
          else drain_cnt <= drain_cnt + 1'b1;
        end

        S_DONE: begin
          busy  <= 1'b0;
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

`ifdef SIM_ASSERT
  // SPEC section 5.3: the accumulation RAM is sized for M rows per pass.
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_IDLE && start) |-> (cfg_m <= DIM_W'(M_MAX)))
    else $error("gemm_ctrl: M=%0d exceeds M_MAX=%0d", cfg_m, M_MAX);

  // SPEC section 1.2: dimensions must be non-zero multiples of the array size.
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_IDLE && start) |->
                   (cfg_m != 0 && cfg_k != 0 && cfg_n != 0 &&
                    cfg_k[LOG2N-1:0] == '0 && cfg_n[LOG2N-1:0] == '0))
    else $error("gemm_ctrl: illegal dimensions M=%0d K=%0d N=%0d",
                cfg_m, cfg_k, cfg_n);

  // A diagonal commit must never go out against an unloaded shadow.
  assert property (@(posedge clk) disable iff (!rst_n)
                   swap_row |-> shadow_ready)
    else $error("gemm_ctrl: diagonal commit with shadow not ready");

  // SPEC section 6.3: FSM legality. The encoding is one-hot by construction,
  // so this catches a corrupted or unreachable state rather than a bad decode.
  assert property (@(posedge clk) disable iff (!rst_n) $onehot(state))
    else $error("gemm_ctrl: state not one-hot (%b)", state);

  assert property (@(posedge clk) disable iff (!rst_n) $onehot(wl_state))
    else $error("gemm_ctrl: wl_state not one-hot (%b)", wl_state);

  // Legal transitions. Each set includes the state itself, since a stall
  // (core_en low) holds every state register.
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_IDLE)    |=> (state inside {S_IDLE, S_LOAD_W}))
    else $error("gemm_ctrl: illegal transition out of S_IDLE");
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_LOAD_W)  |=> (state inside {S_LOAD_W, S_SWAP}))
    else $error("gemm_ctrl: illegal transition out of S_LOAD_W");
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_SWAP)    |=> (state inside {S_SWAP, S_COMPUTE}))
    else $error("gemm_ctrl: illegal transition out of S_SWAP");
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_COMPUTE) |=> (state inside {S_COMPUTE, S_DRAIN}))
    else $error("gemm_ctrl: illegal transition out of S_COMPUTE");
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_DRAIN)   |=> (state inside {S_DRAIN, S_DONE}))
    else $error("gemm_ctrl: illegal transition out of S_DRAIN");
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_DONE)    |=> (state inside {S_DONE, S_IDLE}))
    else $error("gemm_ctrl: illegal transition out of S_DONE");

  // The row counter must never run past the configured M.
  assert property (@(posedge clk) disable iff (!rst_n)
                   (state == S_COMPUTE) |-> (row_cnt < m_q))
    else $error("gemm_ctrl: row_cnt %0d exceeds M=%0d", row_cnt, m_q);
`endif

endmodule
