// Common parameters and types for the INT8 weight-stationary systolic GEMM
// accelerator. See docs/SPEC.md.
package gemm_pkg;

  // Fixed numeric widths (SPEC section 1.1).
  parameter int DW_IN  = 8;   // signed INT8 operands
  parameter int DW_ACC = 32;  // signed INT32 accumulator
  parameter int DIM_W  = 16;  // width of the M/K/N config registers

  // Worst-case single product is (-128)*(-128) = 2^14, so INT32 holds K such
  // products for any K <= 2^(31-14). Mirrors K_MAX_NO_OVERFLOW in the golden
  // model (SPEC section 3).
  parameter int K_MAX_NO_OVERFLOW = 1 << (DW_ACC - 1 - 2 * (DW_IN - 1));

  // Control FSM states (SPEC section 6.3). One-hot encoded so the Phase 3
  // one-hot assertion is a direct property of the encoding.
  //
  // Refines the spec's LOAD_W0 into two states. The commit of the shadow
  // weights must land on its own cycle: it can be neither on the last shift
  // cycle (the shadow register is still being written on that edge) nor on
  // the first compute cycle (PE[0][0] sees an activation with zero skew and
  // would consume it against the outgoing weight). S_SWAP is that cycle.
  typedef enum logic [5:0] {
    S_IDLE    = 6'b000001,
    S_LOAD_W  = 6'b000010,  // wait for a full bank, swap it in, shift N rows
    S_SWAP    = 6'b000100,  // commit shadow -> w_reg, one cycle
    S_COMPUTE = 6'b001000,
    S_DRAIN   = 6'b010000,
    S_DONE    = 6'b100000
  } state_e;

endpackage
