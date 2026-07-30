// Compute datapath: input skew + PE grid + output deskew (SPEC section 4.2).
//
// Presents a clean row-in/row-out interface. Drive one unskewed activation
// row-slice per cycle with a_valid high; the matching result row-slice appears
// on c_row with c_valid high exactly 2N-1 cycles later, one row per cycle.
//
// Timing, all cycles relative to activation row 0 entering at cycle 0:
//   a_west[i]      = a_row[i] delayed i cycles       (input skew)
//   psum_south[j]  carries row r during cycle r+N+j  (grid latency + skew)
//   c_row          carries row r during cycle r+2N-1 (output deskew of N-1-j)
//
// So the fill latency is (N-1) skew + N vertical depth = 2N-1, and after that
// it is one complete result row per cycle. This is checked against the golden
// model's own emergence log in tb/systolic_array_tb.sv rather than against
// the derivation above.
//
// swap_row must be asserted on the cycle carrying the LAST activation row of
// a tile. It rides the same skew triangle and the same east-going pipeline as
// the activations, so PE[i][j] commits its shadow weight on exactly the cycle
// it consumes that last row -- the next tile's first row then meets the new
// weight with no bubble. See the comment in pe.sv for why a broadcast pulse
// cannot achieve this.
module systolic_array #(
  parameter int N      = 8,
  parameter int DW_IN  = 8,
  parameter int DW_ACC = 32,
  parameter int TAG_W  = 2
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en,

  // Lane vectors are flat (lane i at bits [i*W +: W]): mainline yosys cannot
  // parse multidimensional packed arrays, and OpenLane runs mainline yosys.

  // Activation input: one unskewed row-slice per cycle, lane i = K index.
  input  logic [N*DW_IN-1:0]       a_row,
  input  logic                     a_valid,
  input  logic                     swap_row,
  // Sideband travelling with the row, emerging with its result. Carries which
  // K tile the row belongs to, so the accumulator can tell an initialising
  // row from an accumulating or final one without knowing the pipeline depth.
  input  logic [TAG_W-1:0]         a_tag,

  // Weight shift chain into the top of the grid.
  input  logic [N*DW_IN-1:0]       w_top,
  input  logic                     w_shift_en,
  input  logic                     swap_bcast,

  // Result output: one deskewed row-slice per cycle, lane j = N index.
  output logic [N*DW_ACC-1:0]      c_row,
  output logic                     c_valid,
  output logic [TAG_W-1:0]         c_tag
);

  localparam int LATENCY = 2 * N - 1;

  // ---- input skew -------------------------------------------------------
  // Gaps in the activation stream must inject zeros, not stale data: an idle
  // PE still accumulates a_in * w_reg into the partial sum flowing past it.
  // This mirrors the golden model, which feeds 0 outside the row range.
  logic [N*DW_IN-1:0] a_gated;
  logic [N-1:0]       swap_bcast_lanes;
  logic [N*DW_IN-1:0] a_west;
  logic [N-1:0]       swap_west;

  assign a_gated = a_valid ? a_row : '0;

  skew_buffer #(.N(N), .DW(DW_IN), .DELAY_ASC(1)) u_skew_a (
    .clk(clk), .rst_n(rst_n), .en(en), .din(a_gated), .dout(a_west));

  // Same triangle, one bit wide: every lane is fed the same token so that row
  // i's swap arrives with row i's activation.
  assign swap_bcast_lanes = {N{swap_row & a_valid}};

  skew_buffer #(.N(N), .DW(1), .DELAY_ASC(1)) u_skew_swap (
    .clk(clk), .rst_n(rst_n), .en(en),
    .din(swap_bcast_lanes), .dout(swap_west));

  // ---- skewed weight load ------------------------------------------------
  // The commit ripples diagonally: PE[i][j] takes its shadow on cycle
  // (last row)+i+j. A globally synchronous shift chain would rewrite PE[i]'s
  // shadow on the same cycle in EVERY column, so columns with j >= 2 would
  // commit a weight that had already been overwritten by the next tile.
  //
  // Delaying column j's load by j cycles puts the load on the same diagonal as
  // the commit. PE[i][j]'s shadow then settles on cycle s0+j+N-1 and is not
  // disturbed until s0'+i+j of the following load, which always trails that
  // column's commit. Without this, overlapping tiles would need M >= 3N-1
  // instead of M >= N+1.
  logic [N*DW_IN-1:0] w_top_skewed;
  logic [N-1:0]       w_shift_lanes;
  logic [N-1:0]       w_shift_skewed;

  skew_buffer #(.N(N), .DW(DW_IN), .DELAY_ASC(1)) u_skew_w (
    .clk(clk), .rst_n(rst_n), .en(en), .din(w_top), .dout(w_top_skewed));

  assign w_shift_lanes = {N{w_shift_en}};

  skew_buffer #(.N(N), .DW(1), .DELAY_ASC(1)) u_skew_wen (
    .clk(clk), .rst_n(rst_n), .en(en),
    .din(w_shift_lanes), .dout(w_shift_skewed));

  // ---- PE grid ----------------------------------------------------------
  logic [N*DW_ACC-1:0] psum_south;

  pe_array #(.N(N), .DW_IN(DW_IN), .DW_ACC(DW_ACC)) u_grid (
    .clk        (clk),
    .rst_n      (rst_n),
    .en         (en),
    .a_west     (a_west),
    .swap_west  (swap_west),
    .w_top      (w_top_skewed),
    .w_shift_en (w_shift_skewed),
    .swap_bcast (swap_bcast),
    .psum_south (psum_south)
  );

  // ---- output deskew ----------------------------------------------------
  skew_buffer #(.N(N), .DW(DW_ACC), .DELAY_ASC(0)) u_deskew_c (
    .clk(clk), .rst_n(rst_n), .en(en), .din(psum_south), .dout(c_row));

  // Valid and tag track a_valid through the same LATENCY cycles of pipeline.
  logic [LATENCY-1:0]       valid_sr;
  logic [LATENCY*TAG_W-1:0] tag_sr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_sr <= '0;
      tag_sr   <= '0;
    end else if (en) begin
      valid_sr <= {valid_sr[LATENCY-2:0], a_valid};
      for (int s = LATENCY-1; s > 0; s--)
        tag_sr[s*TAG_W +: TAG_W] <= tag_sr[(s-1)*TAG_W +: TAG_W];
      tag_sr[0 +: TAG_W] <= a_tag;
    end
  end

  assign c_valid = valid_sr[LATENCY-1];
  assign c_tag   = tag_sr[(LATENCY-1)*TAG_W +: TAG_W];

endmodule
