// Unit test for skew_buffer.sv.
//
// Drives both configurations with a stream of lane-distinguishable values and
// checks every lane against a recorded history: lane i of the ascending
// instance must reproduce the input from i cycles ago, and lane i of the
// descending instance the input from N-1-i cycles ago. Also checks that a
// stall holds the whole triangle still, since the array's correctness depends
// on skew and compute advancing in lockstep.
//
// TESTBENCH STYLE NOTE (applies to every tb/ file here):
// DUT inputs are driven from a clocked process with non-blocking assignments,
// and outputs are sampled at negedge. Under Verilator's --timing scheduler, an
// input written with a BLOCKING assignment from a delayed process does not
// propagate through combinational paths until the next clock event, so the
// zero-delay lanes read a full cycle stale. That is a simulator scheduling
// artifact, not a design bug, but it silently corrupts results either way.
module skew_buffer_tb;

  localparam int  N    = 4;
  localparam int  DW   = 8;
  localparam time TCK  = 10ns;
  localparam int  NVAL = 40;

  logic clk = 0, rst_n = 0, en = 1;
  logic [N-1:0][DW-1:0] din;
  logic [N-1:0][DW-1:0] dout_asc, dout_desc;

  int drive_ctr = 0;
  int errors    = 0;

  always #(TCK/2) clk = ~clk;

  skew_buffer #(.N(N), .DW(DW), .DELAY_ASC(1)) dut_asc (
    .clk(clk), .rst_n(rst_n), .en(en), .din(din), .dout(dout_asc));

  skew_buffer #(.N(N), .DW(DW), .DELAY_ASC(0)) dut_desc (
    .clk(clk), .rst_n(rst_n), .en(en), .din(din), .dout(dout_desc));

  // ---- stimulus ---------------------------------------------------------
  // A new vector every cycle. Low nibble is the lane index and high nibble a
  // cycle tag, so a value leaking into a neighbouring lane is visible.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      din       <= '0;
      drive_ctr <= 0;
    end else begin
      for (int i = 0; i < N; i++) din[i] <= 8'(((drive_ctr + 1) << 4) | i);
      drive_ctr <= drive_ctr + 1;
    end
  end

  // ---- checker ----------------------------------------------------------
  logic [N-1:0][DW-1:0] history [0:NVAL+N];
  int  cyc      = 0;
  bit  checking = 0;

  task automatic check(string what, int lane, int got, int exp);
    if (got !== exp) begin
      $error("%s lane %0d @cyc %0d: got 0x%02x, expected 0x%02x",
             what, lane, cyc, got, exp);
      errors++;
    end
  endtask

  // Sampled at negedge, mid-cycle, with everything settled. A lane of delay D
  // must present the value driven D cycles ago; D=0 falls out of the same
  // expression, since history[cyc] is this cycle's input.
  always begin
    @(negedge clk);
    if (checking) begin
      history[cyc] = din;
      for (int i = 0; i < N; i++) begin
        int d_asc  = i;
        int d_desc = N - 1 - i;
        if (cyc - d_asc  >= 0) check("asc",  i, dout_asc[i],  history[cyc-d_asc][i]);
        if (cyc - d_desc >= 0) check("desc", i, dout_desc[i], history[cyc-d_desc][i]);
      end
      cyc++;
    end
  end

  initial begin
    repeat (2) @(posedge clk);
    rst_n    = 1;
    @(posedge clk);
    checking = 1;

    repeat (NVAL) @(posedge clk);

    // ---- stall holds the triangle still ----------------------------------
    // The stimulus driver keeps changing din, so any lane that moves while
    // en=0 is a real stall bug. Zero-delay lanes are combinational and
    // legitimately follow din, so they are excluded.
    @(negedge clk);
    checking = 0;
    en       = 0;
    begin
      automatic logic [N-1:0][DW-1:0] frozen_asc  = dout_asc;
      automatic logic [N-1:0][DW-1:0] frozen_desc = dout_desc;
      repeat (5) @(negedge clk);
      for (int i = 0; i < N; i++) begin
        if (i != 0)   check("asc frozen",  i, dout_asc[i],  frozen_asc[i]);
        if (i != N-1) check("desc frozen", i, dout_desc[i], frozen_desc[i]);
      end
    end

    if (errors == 0) $display("skew_buffer_tb: PASS (%0d cycles checked)", cyc);
    else begin
      $display("skew_buffer_tb: FAIL (%0d errors)", errors);
      $fatal(1, "skew_buffer_tb failed");
    end
    $finish;
  end

  initial begin
    #(TCK * 10000);
    $fatal(1, "skew_buffer_tb: timeout");
  end

endmodule
