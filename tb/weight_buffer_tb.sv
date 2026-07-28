// Unit test for weight_buffer.sv.
//
// The buffer is the design's transposer, so the central check is that a tile
// written as N COLUMN beats reads back as N ROWS: after writing beat j with
// column j, reading row i must yield lane j = tile[i][j]. Getting this
// backwards produces a transposed weight tile, which still yields plausible
// INT32 results and is the easiest bug in the design to miss.
//
// Also checks double-buffering: bank B is filled while bank A is being read,
// and A's contents must not move.
//
// See tb/skew_buffer_tb.sv for the NBA-driver style rule.
module weight_buffer_tb;

  localparam int  N     = 4;
  localparam int  DW_IN = 8;
  localparam time TCK   = 10ns;

  logic clk = 0, rst_n = 0;
  logic [N-1:0][DW_IN-1:0] col_data;
  logic                    col_valid;
  logic                    col_ready;
  logic                    bank_swap;
  logic                    fill_full;
  logic [$clog2(N)-1:0]    rd_row;
  logic [N-1:0][DW_IN-1:0] w_row;

  int errors = 0;

  always #(TCK/2) clk = ~clk;

  weight_buffer #(.N(N), .DW_IN(DW_IN)) dut (.*);

  // Two reference tiles, tile[t][i][j].
  logic [DW_IN-1:0] tile [2][N][N];

  task automatic check(string what, int got, int exp);
    if (got !== exp) begin
      $error("%s: got 0x%02x, expected 0x%02x", what, got, exp);
      errors++;
    end
  endtask

  // ---- driver -----------------------------------------------------------
  // A tiny sequencer. DUT inputs are driven from always_ff, per the style
  // rule; the initial block below only sets these command registers.
  typedef enum logic [2:0] { C_NOP, C_WRCOL, C_SWAP, C_RDROW } cmd_e;

  cmd_e cmd      = C_NOP;
  int   cmd_arg  = 0;   // column index, or row index
  int   cmd_bank = 0;   // which reference tile a write sources from

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      col_data  <= '0;
      col_valid <= 1'b0;
      bank_swap <= 1'b0;
      rd_row    <= '0;
    end else begin
      col_valid <= 1'b0;
      bank_swap <= 1'b0;
      case (cmd)
        // Beat j carries column j: lane i is tile[i][j].
        C_WRCOL: begin
          col_valid <= 1'b1;
          for (int i = 0; i < N; i++) col_data[i] <= tile[cmd_bank][i][cmd_arg];
        end
        C_SWAP:  bank_swap <= 1'b1;
        C_RDROW: rd_row    <= cmd_arg[$clog2(N)-1:0];
        default: ;
      endcase
    end
  end

  // Issue one command, taking two cycles: the first edge registers the DUT
  // inputs, the second is the cycle on which the DUT consumes them. Returning
  // only after that second edge means a caller can check the DUT's response
  // immediately, with no off-by-one. `cmd` is cleared after `#1` so it is
  // never changed in the same delta as the edge that samples it.
  task automatic issue(input cmd_e c, input int arg, input int bank = 0);
    cmd = c; cmd_arg = arg; cmd_bank = bank;
    @(posedge clk);
    #1;
    cmd = C_NOP;
    @(posedge clk);
    #1;
  endtask

  task automatic fill_tile(input int bank);
    for (int j = 0; j < N; j++) issue(C_WRCOL, j, bank);
  endtask

  task automatic verify_tile(input int bank, input string tag);
    for (int i = 0; i < N; i++) begin
      issue(C_RDROW, i);
      @(negedge clk);   // rd_row applied; w_row is a combinational read
      for (int j = 0; j < N; j++)
        check($sformatf("%s row %0d lane %0d", tag, i, j), w_row[j], tile[bank][i][j]);
    end
  endtask

  initial begin
    // Distinguishable data: bit 7 = tile, high nibble = row, low nibble =
    // column, so a transpose error shows up as swapped nibbles, not as noise.
    for (int t = 0; t < 2; t++)
      for (int i = 0; i < N; i++)
        for (int j = 0; j < N; j++)
          tile[t][i][j] = 8'((t << 7) | (i << 4) | j);

    repeat (3) @(posedge clk);
    rst_n = 1;
    @(negedge clk);

    check("col_ready when empty", col_ready, 1);
    check("fill_full when empty", fill_full, 0);

    // ---- fill bank A -----------------------------------------------------
    fill_tile(0);
    @(negedge clk);
    check("fill_full after N columns", fill_full, 1);
    check("col_ready deasserts when full", col_ready, 0);

    // ---- swap, then read A while filling B -------------------------------
    issue(C_SWAP, 0);
    @(negedge clk);
    check("fill_full clears after swap", fill_full, 0);
    check("col_ready reasserts after swap", col_ready, 1);

    verify_tile(0, "tileA");

    // Fill B while A is the drain bank, then re-verify A: filling must not
    // disturb the bank the array is reading.
    fill_tile(1);
    verify_tile(0, "tileA after filling B");

    // ---- swap and read B -------------------------------------------------
    issue(C_SWAP, 0);
    verify_tile(1, "tileB");

    // Refill the (now) fill bank with A and swap back, confirming the buffer
    // alternates rather than latching onto one bank. bank_swap is only legal
    // when fill_full, so the refill is required, not incidental.
    fill_tile(0);
    issue(C_SWAP, 0);
    verify_tile(0, "tileA after swapping back");

    if (errors == 0) $display("weight_buffer_tb: PASS");
    else begin
      $display("weight_buffer_tb: FAIL (%0d errors)", errors);
      $fatal(1, "weight_buffer_tb failed");
    end
    $finish;
  end

  initial begin
    #(TCK * 10000);
    $fatal(1, "weight_buffer_tb: timeout");
  end

endmodule
