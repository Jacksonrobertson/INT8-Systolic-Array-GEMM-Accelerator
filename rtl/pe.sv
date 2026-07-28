// Processing element: one INT8 MAC of the weight-stationary systolic array.
//
// Per-cycle behavior when `en` is high (SPEC section 3). This matches
// SystolicArraySim.run() exactly, including the detail that the multiply
// consumes the activation ARRIVING this cycle rather than the registered one:
//
//   a_out    <= a_in
//   psum_out <= psum_in + a_in * w_reg
//
// Weights reach w_reg by two paths:
//
//  1. The w_shadow shift chain. w_in comes from the PE to the north and
//     shifts down one row per cycle while w_shift_en is high, so a column of
//     AH shadows fills in AH cycles. Because the first value pushed travels
//     furthest, the weight buffer must present rows in DESCENDING order
//     (row AH-1 first).
//
//  2. The commit, w_reg <= w_shadow, by either:
//       swap_bcast - every PE at once, used when the array holds no in-flight
//                    wavefront (first tile of a pass, or after a flush);
//       swap_in    - carried diagonally. It rides the activation skew network
//                    and the east-going pipeline, so it reaches PE[i][j] on
//                    cycle (M-1)+i+j: the same cycle that PE consumes the
//                    outgoing tile's LAST activation row. w_reg therefore
//                    updates on the edge ending that cycle and is already new
//                    when the next tile's first activation arrives at
//                    cycle M+i+j. A global swap pulse cannot do this, since
//                    each PE's handoff cycle differs.
//
// Everything is gated by `en` so that a stall freezes the whole core
// coherently: an in-flight wavefront and the weight shift chain must not
// advance relative to one another.
module pe #(
  parameter int DW_IN  = 8,
  parameter int DW_ACC = 32
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en,          // global clock enable / stall

  // West -> east: activations and the diagonal swap token.
  input  logic signed [DW_IN-1:0]  a_in,
  output logic signed [DW_IN-1:0]  a_out,
  input  logic                     swap_in,
  output logic                     swap_out,

  // North -> south: partial sums.
  input  logic signed [DW_ACC-1:0] psum_in,
  output logic signed [DW_ACC-1:0] psum_out,

  // North -> south: the weight shadow shift chain.
  input  logic signed [DW_IN-1:0]  w_in,
  output logic signed [DW_IN-1:0]  w_out,
  input  logic                     w_shift_en,
  input  logic                     swap_bcast
);

  logic signed [DW_IN-1:0]   w_reg;     // stationary weight, in use
  logic signed [DW_IN-1:0]   w_shadow;  // next tile's weight, preloading
  logic signed [2*DW_IN-1:0] prod;      // INT8 * INT8 -> INT16, both signed

  assign prod  = a_in * w_reg;
  assign w_out = w_shadow;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out    <= '0;
      swap_out <= 1'b0;
      psum_out <= '0;
      w_reg    <= '0;
      w_shadow <= '0;
    end else if (en) begin
      a_out    <= a_in;
      swap_out <= swap_in;
      // Sign-extend the INT16 product to INT32 before accumulating.
      psum_out <= psum_in + DW_ACC'(prod);

      // Reads w_shadow's pre-edge value, so a shift and a commit may land on
      // the same cycle without the shift being lost.
      if (swap_in || swap_bcast) w_reg <= w_shadow;
      if (w_shift_en)            w_shadow <= w_in;
    end
  end

`ifdef SIM_ASSERT
  // SPEC section 3: INT32 provably cannot overflow for K <= 2^17, and the
  // golden model asserts the same bound. The RTL accumulator wraps silently,
  // so compute the sum one bit wider and require the extra bit to be pure sign
  // extension -- that is exactly "no signed overflow".
  logic signed [DW_ACC:0] sum_ext;
  assign sum_ext = DW_ACC'(psum_in) + DW_ACC'(prod);

  assert property (@(posedge clk) disable iff (!rst_n)
                   en |-> (sum_ext[DW_ACC] == sum_ext[DW_ACC-1]))
    else $error("pe: INT32 accumulator overflow (psum_in=%0d prod=%0d)",
                psum_in, prod);
`endif

endmodule
