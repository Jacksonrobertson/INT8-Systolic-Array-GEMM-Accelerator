// Double-banked weight tile buffer (SPEC section 5.2).
//
// Also the transposer for the design. s_axis_w delivers one tile COLUMN per
// beat (see model/generate_vectors.py: beat j is B[kt*n:(kt+1)*n, nt*n+j], so
// its N lanes are N different rows of one column), but the array shifts
// weights down through the columns and therefore consumes one tile ROW per
// cycle. This buffer absorbs that mismatch: written column-wise, read
// row-wise.
//
// Two banks: while one drains into the array's shadow registers, the other
// fills from the stream. With M=n -- the tightest legal schedule -- a tile
// pass is only n cycles long, exactly enough to overlap an n-cycle fill with
// an n-cycle drain, which is why one bank is not sufficient.
//
// Contract: bank_swap may only be asserted when fill_full is high, so a swap
// can never race an in-flight column write. Asserted below.
module weight_buffer #(
  parameter int N     = 8,
  parameter int DW_IN = 8
) (
  input  logic                     clk,
  input  logic                     rst_n,

  // Lane vectors are flat (lane i at bits [i*DW_IN +: DW_IN]): mainline yosys
  // cannot parse multidimensional packed arrays, and OpenLane runs it.

  // Fill side: one tile column per beat.
  input  logic [N*DW_IN-1:0]       col_data,
  input  logic                     col_valid,
  output logic                     col_ready,

  // Bank control.
  input  logic                     bank_swap,
  output logic                     fill_full,

  // Drain side: one tile row per cycle, combinationally read.
  input  logic [$clog2(N)-1:0]     rd_row,
  output logic [N*DW_IN-1:0]       w_row
);

  localparam int CNT_W = $clog2(N + 1);

  // mem[bank][row] is one packed tile row; lane j is column j.
  logic [N*DW_IN-1:0] mem [2][N];

  logic             fill_bank;   // bank currently being filled
  logic [CNT_W-1:0] col_cnt;     // columns written into the fill bank

  assign fill_full = (col_cnt == CNT_W'(N));
  assign col_ready = !fill_full;
  assign w_row     = mem[!fill_bank][rd_row];

  wire col_fire = col_valid && col_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fill_bank <= 1'b0;
      col_cnt   <= '0;
    end else begin
      if (bank_swap) begin
        fill_bank <= !fill_bank;
        col_cnt   <= '0;
      end else if (col_fire) begin
        col_cnt <= col_cnt + 1'b1;
      end

      // Beat col_cnt carries column col_cnt: scatter its N lanes down the
      // rows of the fill bank. This is the transpose.
      if (col_fire) begin
        for (int i = 0; i < N; i++)
          mem[fill_bank][i][col_cnt[$clog2(N)-1:0]*DW_IN +: DW_IN]
            <= col_data[i*DW_IN +: DW_IN];
      end
    end
  end

`ifdef SIM_ASSERT
  // A swap while the fill bank is still incomplete would hand the array a
  // partially written tile.
  assert property (@(posedge clk) disable iff (!rst_n)
                   bank_swap |-> fill_full)
    else $error("weight_buffer: bank_swap while fill bank incomplete");
`endif

endmodule
