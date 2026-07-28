// Output accumulation RAM (SPEC section 5.3).
//
// The tile loop is `for nt: for kt:`, so the K tiles contributing to one
// output column-block arrive as a sequence of partial results for the same M
// rows. This block read-modify-accumulates them: kt=0 initialises a row, later
// kt values add into it, and the final kt emits the finished row.
//
// Because the last kt's sum is produced by the adder here, the finished row is
// forwarded straight out rather than written back and re-read. That removes
// the separate drain pass and the second RAM read port it would need.
//
// Two-stage pipeline, so this maps onto a plain synchronous-read RAM rather
// than a register file (8 KiB at N=8, M_MAX=256):
//   stage 1  issue read of mem[in_addr], register the incoming row
//   stage 2  add, write back, and drive the output
// Result rows arrive at addresses 0..M-1 in order and each address is touched
// once per tile pass, so no read-after-write hazard exists between the stages.
module accum_ram #(
  parameter int N      = 8,
  parameter int DW_ACC = 32,
  parameter int M_MAX  = 256,
  // Derived; not intended to be overridden.
  parameter int ADDR_W = $clog2(M_MAX)
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en,        // global clock enable / stall

  // A finished result row from the array's deskew stage.
  input  logic                     in_valid,
  input  logic [ADDR_W-1:0]        in_addr,   // row index within the pass
  input  logic [N-1:0][DW_ACC-1:0] in_data,
  input  logic                     in_first,  // kt==0: initialise, do not add
  input  logic                     in_last,   // final kt: emit the row

  // Finished output rows, two cycles behind the corresponding in_valid.
  output logic                     out_valid,
  output logic [ADDR_W-1:0]        out_addr,
  output logic [N-1:0][DW_ACC-1:0] out_data
);

  logic [N-1:0][DW_ACC-1:0] mem [0:M_MAX-1];

  // ---- stage 1: read issue ---------------------------------------------
  logic                     s1_valid, s1_first, s1_last;
  logic [ADDR_W-1:0]        s1_addr;
  logic [N-1:0][DW_ACC-1:0] s1_data, rd_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
      s1_first <= 1'b0;
      s1_last  <= 1'b0;
      s1_addr  <= '0;
      s1_data  <= '0;
      rd_q     <= '0;
    end else if (en) begin
      s1_valid <= in_valid;
      s1_first <= in_first;
      s1_last  <= in_last;
      s1_addr  <= in_addr;
      s1_data  <= in_data;
      rd_q     <= mem[in_addr];
    end
  end

  // ---- stage 2: accumulate, write back, emit ---------------------------
  // Lane-wise INT32 adds. This must NOT be one wide addition: a carry out of
  // lane j would corrupt lane j+1.
  logic [N-1:0][DW_ACC-1:0] sum;

  always_comb begin
    for (int j = 0; j < N; j++) begin
      sum[j] = (s1_first ? DW_ACC'(0) : rd_q[j]) + s1_data[j];
    end
  end

  always_ff @(posedge clk) begin
    if (en && s1_valid) mem[s1_addr] <= sum;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_addr  <= '0;
      out_data  <= '0;
    end else if (en) begin
      out_valid <= s1_valid && s1_last;
      out_addr  <= s1_addr;
      out_data  <= sum;
    end
  end

endmodule
