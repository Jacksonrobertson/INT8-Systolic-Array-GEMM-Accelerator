// Triangular delay network (SPEC sections 4.2 and 5.1).
//
// Lane i is delayed by DELAY_ASC ? i : N-1-i cycles. One lane is a pure wire,
// so total storage is N*(N-1)/2 words either way.
//
//   DELAY_ASC=1  input skew: activation row i must enter PE row i i cycles
//                late, so the diagonal wavefront meets the right partial sums.
//
//   DELAY_ASC=0  output deskew: column j's result for activation row r emerges
//                from the array at cycle r+n+j, so column j needs N-1-j more
//                cycles to realign every column of a row onto one beat.
//
// Used for activations (DW=DW_IN), for the diagonal swap token and valid
// sideband (DW=1, every lane driven with the same bit), and for results
// (DW=DW_ACC).
module skew_buffer #(
  parameter int N         = 8,
  parameter int DW        = 8,
  parameter bit DELAY_ASC = 1
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 en,
  input  logic [N-1:0][DW-1:0] din,
  output logic [N-1:0][DW-1:0] dout
);

  for (genvar i = 0; i < N; i++) begin : g_lane
    localparam int D = DELAY_ASC ? i : N - 1 - i;

    if (D == 0) begin : g_wire
      assign dout[i] = din[i];
    end else begin : g_delay
      logic [D-1:0][DW-1:0] sr;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sr <= '0;
        end else if (en) begin
          sr[0] <= din[i];
          for (int k = 1; k < D; k++) sr[k] <= sr[k-1];
        end
      end

      assign dout[i] = sr[D-1];
    end
  end

endmodule
