// INT32 -> INT8 output stage: ReLU + fixed-point requantization (SPEC §7).
//
// Bit-exact with requantize() in model/golden_model.py:
//
//   x   = relu_en ? max(acc, 0) : acc
//   y   = (x * mult + (shift > 0 ? 1 << (shift-1) : 0)) >>> shift
//   out = clamp(y, -128, 127)
//
// mult is a 24-bit UNSIGNED multiplier and shift is 0..31. Rounding is
// round-half-up, which is one adder rather than the comparison tree that
// round-to-nearest-even needs, and it reproduces exactly in NumPy.
//
// The SHIFT=0 case adds no rounding constant at all -- note that this differs
// from adding (1 << -1) == 0, because a rounding term of 1<<31 would otherwise
// be implied by a naive expression. The golden model special-cases it and so
// does this.
//
// Purely combinational; the caller registers the result.
module requant_unit #(
  parameter int DW_ACC = 32
) (
  input  logic signed [DW_ACC-1:0] acc,
  input  logic        [23:0]       mult,
  input  logic        [4:0]        shift,
  input  logic                     relu_en,
  output logic signed [7:0]        q
);

  // 64-bit intermediates mirror the golden model's int64 arithmetic. The true
  // maximum is |acc| * mult < 2^31 * 2^24 = 2^55, plus a rounding term below
  // 2^31, so nothing here can overflow and synthesis will trim the slack.
  logic signed [63:0] x, prod, rnd, y;

  // ReLU. With relu_en low, negative values pass through and take the same
  // add-then-arithmetic-shift path, matching relu=False in the model.
  assign x = (relu_en && acc[DW_ACC-1]) ? 64'sd0 : 64'(acc);

  // Signed x by unsigned mult: zero-extend the multiplier so it stays positive.
  assign prod = x * $signed({40'b0, mult});

  assign rnd  = (shift != 5'd0) ? (64'sd1 << (shift - 5'd1)) : 64'sd0;
  assign y    = (prod + rnd) >>> shift;

  // Saturate. With ReLU on, the low limit is unreachable, but it is applied
  // unconditionally so relu_en=0 behaves like the model too.
  assign q = (y > 64'sd127)  ?  8'sd127 :
             (y < -64'sd128) ? -8'sd128 : y[7:0];

endmodule
