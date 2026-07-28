// N x N grid of weight-stationary PEs (SPEC section 2 block diagram).
//
// Pure grid: activations arrive at the west edge ALREADY SKEWED and partial
// sums leave the south edge STILL SKEWED (column j is j cycles late). The
// skew/deskew triangles live in systolic_array.sv, which wraps this.
//
// PE[i][j] holds weight tile element B[i][j]: row index i is the K dimension,
// column index j the N dimension.
//
// Weights enter the top of each column and shift down one row per cycle while
// w_shift_en is high, so the weight buffer must present tile rows in
// DESCENDING order (row N-1 first) for them to land in the right rows.
module pe_array #(
  parameter int N      = 8,
  parameter int DW_IN  = 8,
  parameter int DW_ACC = 32
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en,

  input  logic [N-1:0][DW_IN-1:0]  a_west,      // skewed activations, row i
  input  logic [N-1:0]             swap_west,   // skewed swap token, row i

  // Weight shift chain. Per-column enable: the load is skewed to follow the
  // same diagonal as the commit (see systolic_array.sv), so column j shifts on
  // its own cycles rather than in lockstep with the rest.
  input  logic [N-1:0][DW_IN-1:0]  w_top,       // one tile row, column j
  input  logic [N-1:0]             w_shift_en,
  input  logic                     swap_bcast,

  output logic [N-1:0][DW_ACC-1:0] psum_south   // skewed results, column j
);

  // [i][j] = output of PE[i][j] on each of the three flow directions.
  logic [DW_IN-1:0]  a_h    [N][N];  // east
  logic              swap_h [N][N];  // east
  logic [DW_ACC-1:0] psum_v [N][N];  // south
  logic [DW_IN-1:0]  w_v    [N][N];  // south (shadow shift chain)

  for (genvar i = 0; i < N; i++) begin : g_row
    for (genvar j = 0; j < N; j++) begin : g_col
      pe #(.DW_IN(DW_IN), .DW_ACC(DW_ACC)) u_pe (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        // West edge takes the skewed input; interior takes the neighbour.
        .a_in       (j == 0 ? a_west[i]    : a_h[i][j-1]),
        .a_out      (a_h[i][j]),
        .swap_in    (j == 0 ? swap_west[i] : swap_h[i][j-1]),
        .swap_out   (swap_h[i][j]),
        // Top row starts each column's accumulation at zero.
        .psum_in    (i == 0 ? '0 : psum_v[i-1][j]),
        .psum_out   (psum_v[i][j]),
        .w_in       (i == 0 ? w_top[j] : w_v[i-1][j]),
        .w_out      (w_v[i][j]),
        .w_shift_en (w_shift_en[j]),
        .swap_bcast (swap_bcast)
      );
    end
  end

  for (genvar j = 0; j < N; j++) begin : g_south
    assign psum_south[j] = psum_v[N-1][j];
  end

endmodule
