// Unit test for pe.sv.
//
// Checks the four things the array depends on:
//   1. the MAC recurrence, psum_out <= psum_in + a_in * w_reg, using the
//      activation ARRIVING this cycle (the SystolicArraySim convention);
//   2. signed arithmetic at the corners, including (-128)*(-128) = +16384;
//   3. `en` low freezes every register;
//   4. both weight-commit paths, and specifically that a diagonal swap_in
//      commits in time for the very next activation, with no lost cycle.
module pe_tb;

  localparam int DW_IN  = 8;
  localparam int DW_ACC = 32;
  localparam time TCK   = 10ns;

  logic clk = 0, rst_n = 0, en = 1;
  logic signed [DW_IN-1:0]  a_in = 0, w_in = 0;
  logic signed [DW_ACC-1:0] psum_in = 0;
  logic swap_in = 0, w_shift_en = 0, swap_bcast = 0;
  logic signed [DW_IN-1:0]  a_out, w_out;
  logic signed [DW_ACC-1:0] psum_out;
  logic swap_out;

  int errors = 0;

  always #(TCK/2) clk = ~clk;

  pe #(.DW_IN(DW_IN), .DW_ACC(DW_ACC)) dut (.*);

  // Advance one cycle with inputs already driven, then settle so the checks
  // below observe the registers that just updated.
  task automatic step();
    @(posedge clk);
    #1;
  endtask

  task automatic check(string what, int unsigned got, int unsigned exp);
    if (got !== exp) begin
      $error("%s: got %0d (0x%08x), expected %0d (0x%08x)",
             what, $signed(got), got, $signed(exp), exp);
      errors++;
    end
  endtask

  // Push one weight through the shadow chain and commit it by broadcast.
  task automatic load_weight_bcast(input logic signed [DW_IN-1:0] w);
    w_in = w; w_shift_en = 1;
    step();
    w_shift_en = 0;
    check("w_out follows w_shadow", w_out, w);
    swap_bcast = 1;
    step();
    swap_bcast = 0;
  endtask

  initial begin
    repeat (2) @(posedge clk);
    rst_n = 1;
    #1;
    check("psum_out reset", psum_out, 0);
    check("a_out reset", a_out, 0);

    // ---- 1. basic MAC recurrence -----------------------------------------
    load_weight_bcast(8'sd7);

    a_in = 8'sd3; psum_in = 32'sd100;
    step();
    check("100 + 3*7", psum_out, 121);
    check("a_out forwards a_in", a_out, 3);

    // psum_out must track the value arriving each cycle, one per cycle.
    a_in = -8'sd5; psum_in = 32'sd10;
    step();
    check("10 + (-5)*7", psum_out, -25);

    // ---- 2. signed corners ------------------------------------------------
    load_weight_bcast(-8'sd128);
    a_in = -8'sd128; psum_in = 0;
    step();
    check("(-128)*(-128)", psum_out, 16384);

    a_in = 8'sd127; psum_in = 0;
    step();
    check("127*(-128)", psum_out, -16256);

    load_weight_bcast(8'sd127);
    a_in = 8'sd127; psum_in = 32'sh7FFF_0000;
    step();
    check("psum_in + 127*127", psum_out, 32'sh7FFF_0000 + 16129);

    // ---- 3. stall freezes everything -------------------------------------
    a_in = 8'sd1; psum_in = 32'sd0;
    step();
    check("pre-stall value", psum_out, 127);
    begin
      automatic logic signed [DW_ACC-1:0] frozen = psum_out;
      automatic logic signed [DW_IN-1:0]  frozen_a = a_out;
      en = 0;
      a_in = 8'sd99; psum_in = 32'sd12345;
      repeat (3) step();
      check("psum_out frozen while en=0", psum_out, frozen);
      check("a_out frozen while en=0", a_out, frozen_a);
      en = 1;
      step();
      check("resumes after stall", psum_out, 12345 + 99 * 127);
    end

    // ---- 4. diagonal swap commits with zero lost cycles -------------------
    // w_reg = 127 from above. Preload the shadow with a different weight
    // while "computing", then let swap_in ride the last activation.
    a_in = 0; psum_in = 0;
    w_in = 8'sd2; w_shift_en = 1;
    step();
    w_shift_en = 0;

    // This cycle is the outgoing tile's last activation row: it must still
    // use the OLD weight (127), and the same edge commits the shadow.
    a_in = 8'sd10; psum_in = 0; swap_in = 1;
    step();
    swap_in = 0;
    check("last activation uses old weight", psum_out, 1270);
    check("swap_out pipelines east", swap_out, 1);

    // The next activation is the new tile's first row: new weight, no bubble.
    a_in = 8'sd10; psum_in = 0;
    step();
    check("next activation uses new weight", psum_out, 20);
    check("swap_out deasserts", swap_out, 0);

    // A commit with no preceding shift must be idempotent, not corrupting.
    swap_bcast = 1; a_in = 8'sd10; psum_in = 0;
    step();
    swap_bcast = 0;
    step();
    check("redundant commit keeps weight", psum_out, 20);

    if (errors == 0) $display("pe_tb: PASS");
    else begin
      $display("pe_tb: FAIL (%0d errors)", errors);
      $fatal(1, "pe_tb failed");
    end
    $finish;
  end

  initial begin
    #(TCK * 10000);
    $fatal(1, "pe_tb: timeout");
  end

endmodule
