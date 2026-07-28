// INT8 weight-stationary systolic GEMM accelerator, top level (SPEC section 2).
//
// C = A x B, A is MxK int8, B is KxN int8, C is MxN int32. Streams in over
// AXI-Stream, configured by parallel registers latched at start.
//
// Stream ordering follows model/generate_vectors.py exactly:
//   s_axis_w  for nt, for kt: N beats, beat j = tile column j
//   s_axis_a  for nt, for kt: M beats, beat r = activation row r of the block
//             (the activation block is re-streamed once per output column-block)
//   m_axis_c  for nt: M beats, beat r = result row r of that column-block
//
// STALL MODEL
// A single core_en gates the whole datapath and the FSM. The core stalls when
// an activation beat is wanted but absent, or when a result is offered and the
// consumer is not ready. Freezing everything together is what makes the
// skewed wavefront safe to interrupt: partial sums in flight, the input skew
// triangle, the output deskew triangle and the tile counters all hold their
// relative positions.
//
// The weight FILL path is deliberately outside core_en. Weights for the next
// tile must keep arriving while the core is stalled or draining -- that is the
// entire purpose of the double bank. Only the bank swap is gated, because it
// is the point where the fill side hands over to the frozen side.
module gemm_top
  import gemm_pkg::*;
#(
  parameter int N     = 8,
  parameter int M_MAX = 256
) (
  input  logic                  clk,
  input  logic                  rst_n,

  // Configuration (SPEC section 6.2), sampled at start.
  input  logic                  start,
  input  logic [DIM_W-1:0]      cfg_m,
  input  logic [DIM_W-1:0]      cfg_k,
  input  logic [DIM_W-1:0]      cfg_n,
  // Optional INT8 output stage (SPEC sections 6.2 and 7). When quant_en is
  // set, each lane's INT32 result is ReLU'd and requantized to INT8 and the N
  // bytes are packed into the LOW N*8 bits of m_axis_c_tdata, upper bits zero.
  // The bus width is unchanged so the two modes share one interface.
  input  logic                  cfg_quant_en,
  input  logic [23:0]           cfg_mult,
  input  logic [4:0]            cfg_shift,
  output logic                  busy,
  output logic                  done,

  // Weights: one tile column per beat.
  input  logic                  s_axis_w_tvalid,
  output logic                  s_axis_w_tready,
  input  logic [N*DW_IN-1:0]    s_axis_w_tdata,
  input  logic                  s_axis_w_tlast,

  // Activations: one row-slice per beat.
  input  logic                  s_axis_a_tvalid,
  output logic                  s_axis_a_tready,
  input  logic [N*DW_IN-1:0]    s_axis_a_tdata,
  input  logic                  s_axis_a_tlast,

  // Results: one row-slice per beat.
  output logic                  m_axis_c_tvalid,
  input  logic                  m_axis_c_tready,
  output logic [N*DW_ACC-1:0]   m_axis_c_tdata,
  output logic                  m_axis_c_tlast
);

  localparam int LOG2N  = $clog2(N);
  localparam int ADDR_W = $clog2(M_MAX);

  // ---- control ----------------------------------------------------------
  logic             core_en;
  logic             wb_fill_full, wb_bank_swap, wb_bank_swap_gated;
  logic [LOG2N-1:0] wb_rd_row;
  logic             w_shift_en, swap_bcast, swap_row, a_stream, a_fire;
  logic [1:0]       a_tag;
  logic [DIM_W-1:0] dim_m, dim_n;
  state_e           state;

  gemm_ctrl #(.N(N), .M_MAX(M_MAX)) u_ctrl (
    .clk          (clk),
    .rst_n        (rst_n),
    .core_en      (core_en),
    .start        (start),
    .cfg_m        (cfg_m),
    .cfg_k        (cfg_k),
    .cfg_n        (cfg_n),
    .busy         (busy),
    .done         (done),
    .wb_fill_full (wb_fill_full),
    .wb_bank_swap (wb_bank_swap),
    .wb_rd_row    (wb_rd_row),
    .w_shift_en   (w_shift_en),
    .swap_bcast   (swap_bcast),
    .swap_row     (swap_row),
    .a_stream     (a_stream),
    .a_fire       (a_fire),
    .a_tag        (a_tag),
    .dim_m        (dim_m),
    .dim_n        (dim_n),
    .state        (state)
  );

  // ---- stall generation --------------------------------------------------
  // The core stalls when a required activation beat is absent, or when the
  // accumulator is holding a finished row the output register cannot take.
  logic in_starved, out_blocked, oq_can_accept;

  assign in_starved  = a_stream && !s_axis_a_tvalid;
  assign out_blocked = acc_out_valid && !oq_can_accept;
  assign core_en     = !in_starved && !out_blocked;

  // tready may depend on tvalid; only tvalid is forbidden from waiting on
  // tready (SPEC section 6.1).
  assign s_axis_a_tready = a_stream && !out_blocked;
  assign a_fire          = s_axis_a_tvalid && s_axis_a_tready;

  // ---- weight buffer -----------------------------------------------------
  logic [N-1:0][DW_IN-1:0] wb_col_data, wb_w_row;

  assign wb_col_data        = s_axis_w_tdata;
  assign wb_bank_swap_gated = wb_bank_swap && core_en;

  weight_buffer #(.N(N), .DW_IN(DW_IN)) u_wbuf (
    .clk       (clk),
    .rst_n     (rst_n),
    .col_data  (wb_col_data),
    .col_valid (s_axis_w_tvalid),
    .col_ready (s_axis_w_tready),
    .bank_swap (wb_bank_swap_gated),
    .fill_full (wb_fill_full),
    .rd_row    (wb_rd_row),
    .w_row     (wb_w_row)
  );

  // ---- compute datapath --------------------------------------------------
  logic [N-1:0][DW_IN-1:0]  arr_a_row;
  logic [N-1:0][DW_ACC-1:0] arr_c_row;
  logic                     arr_c_valid;
  logic [1:0]               arr_c_tag;

  assign arr_a_row = s_axis_a_tdata;

  systolic_array #(.N(N), .DW_IN(DW_IN), .DW_ACC(DW_ACC), .TAG_W(2)) u_array (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (core_en),
    .a_row      (arr_a_row),
    .a_valid    (a_fire),
    // Rides the skew network so each PE commits the next tile's weight on the
    // cycle it consumes this tile's final row -- zero-bubble tile handover.
    .swap_row   (swap_row),
    .a_tag      (a_tag),
    .w_top      (wb_w_row),
    .w_shift_en (w_shift_en),
    .swap_bcast (swap_bcast),
    .c_row      (arr_c_row),
    .c_valid    (arr_c_valid),
    .c_tag      (arr_c_tag)
  );

  // ---- accumulation ------------------------------------------------------
  // Result rows arrive in order, so their address is just a wrapping count of
  // rows seen this pass. The tag rides with the row rather than being read
  // from the FSM, so the accumulator stays correct once tiles overlap.
  logic [DIM_W-1:0] acc_row;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_row <= '0;
    end else if (core_en && arr_c_valid) begin
      acc_row <= (acc_row == dim_m - 1'b1) ? '0 : acc_row + 1'b1;
    end
  end

  logic                     acc_out_valid;
  logic [ADDR_W-1:0]        acc_out_addr;
  logic [N-1:0][DW_ACC-1:0] acc_out_data;

  accum_ram #(.N(N), .DW_ACC(DW_ACC), .M_MAX(M_MAX)) u_acc (
    .clk       (clk),
    .rst_n     (rst_n),
    .en        (core_en),
    .in_valid  (arr_c_valid),
    .in_addr   (acc_row[ADDR_W-1:0]),
    .in_data   (arr_c_row),
    .in_first  (arr_c_tag[1]),
    .in_last   (arr_c_tag[0]),
    .out_valid (acc_out_valid),
    .out_addr  (acc_out_addr),
    .out_data  (acc_out_data)
  );

  // ---- output stream -----------------------------------------------------
  // A one-deep output register decouples m_axis_c from core_en. Without it,
  // the core stalling for want of an activation beat would freeze the
  // accumulator with out_valid still asserted, and a ready consumer would
  // accept the same row on every stalled cycle. Deasserting tvalid instead is
  // not an option: AXI-Stream requires tvalid to stay asserted once raised
  // until the handshake completes (SPEC section 6.1).
  //
  // The accumulator is only advanced when core_en is high, and core_en already
  // includes out_blocked, so core_en && acc_out_valid guarantees this register
  // can take the row -- the transfer needs no separate handshake.
  logic                     oq_valid, oq_last;
  logic [N*DW_ACC-1:0]      oq_data;
  logic                     oq_load;

  assign oq_can_accept = !oq_valid || m_axis_c_tready;
  assign oq_load       = acc_out_valid && core_en;

  // ---- optional ReLU + requantization ------------------------------------
  // One unit per lane, combinational, selected as the row is captured into the
  // output register so the quantized path costs no extra cycle.
  logic [N-1:0][7:0]   q_lane;
  logic [N*DW_ACC-1:0] out_mux;

  for (genvar j = 0; j < N; j++) begin : g_requant
    requant_unit #(.DW_ACC(DW_ACC)) u_rq (
      .acc     (acc_out_data[j]),
      .mult    (cfg_mult),
      .shift   (cfg_shift),
      .relu_en (1'b1),
      .q       (q_lane[j])
    );
  end

  assign out_mux = cfg_quant_en ? {{(N*DW_ACC - N*8){1'b0}}, q_lane}
                                : acc_out_data;

  // tlast marks the final beat of the whole GEMM. Counted as rows leave the
  // accumulator rather than read from the FSM's current tile, so it stays
  // correct however far the output trails the schedule.
  logic [DIM_W-1:0] out_row, out_nt;
  wire  [DIM_W-1:0] nt_max   = (dim_n >> LOG2N) - 1'b1;
  wire              out_done = (out_row == dim_m - 1'b1) && (out_nt == nt_max);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_row <= '0;
      out_nt  <= '0;
    end else if (start) begin
      out_row <= '0;
      out_nt  <= '0;
    end else if (oq_load) begin
      if (out_row == dim_m - 1'b1) begin
        out_row <= '0;
        out_nt  <= out_nt + 1'b1;
      end else begin
        out_row <= out_row + 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      oq_valid <= 1'b0;
      oq_data  <= '0;
      oq_last  <= 1'b0;
    end else if (oq_load) begin
      // Load takes priority over drain: a simultaneous handshake refills the
      // register in the same cycle, so full-rate streaming is not interrupted.
      oq_valid <= 1'b1;
      oq_data  <= out_mux;
      oq_last  <= out_done;
    end else if (m_axis_c_tready) begin
      oq_valid <= 1'b0;
    end
  end

  assign m_axis_c_tvalid = oq_valid;
  assign m_axis_c_tdata  = oq_data;
  assign m_axis_c_tlast  = oq_last;

  // Input tlast is informational in v1; the schedule is driven by the
  // configured dimensions, not by the stream framing.
  wire unused = &{1'b0, s_axis_w_tlast, s_axis_a_tlast, acc_out_addr, state};

`ifdef SIM_ASSERT
  // SPEC section 6.1: AXI-Stream handshake stability. Once tvalid is asserted
  // it must stay asserted, with tdata/tlast held, until tready completes the
  // handshake. This is the property the output register was added to preserve.
  assert property (@(posedge clk) disable iff (!rst_n)
                   (m_axis_c_tvalid && !m_axis_c_tready) |=>
                   (m_axis_c_tvalid && $stable(m_axis_c_tdata)
                                    && $stable(m_axis_c_tlast)))
    else $error("gemm_top: m_axis_c violated AXI-Stream stability");

  // The same rule applied to the inbound streams. Here it checks the traffic
  // generator rather than the DUT, which is still worth catching: a testbench
  // that changes tdata under a stalled handshake would invalidate the run.
  assert property (@(posedge clk) disable iff (!rst_n)
                   (s_axis_a_tvalid && !s_axis_a_tready) |=>
                   (s_axis_a_tvalid && $stable(s_axis_a_tdata)))
    else $error("gemm_top: s_axis_a violated AXI-Stream stability");
  assert property (@(posedge clk) disable iff (!rst_n)
                   (s_axis_w_tvalid && !s_axis_w_tready) |=>
                   (s_axis_w_tvalid && $stable(s_axis_w_tdata)))
    else $error("gemm_top: s_axis_w violated AXI-Stream stability");

  // A result beat may only be offered while the core believes it is running.
  assert property (@(posedge clk) disable iff (!rst_n)
                   oq_load |-> oq_can_accept)
    else $error("gemm_top: accumulator output dropped by a full register");
`endif

endmodule
