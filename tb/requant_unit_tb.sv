// Unit test for requant_unit.sv against the golden model.
//
// Reads vectors/requant/cases.txt, produced by model/generate_requant_vectors
// from requantize() itself, and requires an exact match on every case. The
// vector set targets the SHIFT=0 no-rounding rule, exact round-half-up
// boundaries, saturation both ways, ReLU on and off, and the INT32 extremes,
// plus a randomised sweep over the whole legal (mult, shift) space.
//
// Since Phase 4 the unit registers its multiply, so each case is driven on a
// clock edge and checked one cycle later. The en-freeze path gets a directed
// check too: a case is held with en low and must not advance.
module requant_unit_tb;

  localparam int  DW_ACC = 32;
  localparam time TCK    = 10ns;

  logic clk = 0, rst_n = 0, en = 1;

  logic signed [DW_ACC-1:0] acc;
  logic        [23:0]       mult;
  logic        [4:0]        shift;
  logic                     relu_en;
  logic signed [7:0]        q;

  int errors = 0;
  int checked = 0;

  always #(TCK/2) clk = ~clk;

  requant_unit #(.DW_ACC(DW_ACC)) dut (
    .clk(clk), .rst_n(rst_n), .en(en),
    .acc(acc), .mult(mult), .shift(shift), .relu_en(relu_en), .q(q));

  task automatic check_case(input logic [31:0] acc_h, input logic [23:0] mult_h,
                            input int sh, input int relu, input int exp);
    acc     = acc_h;
    mult    = mult_h;
    shift   = 5'(sh);
    relu_en = relu[0];
    @(posedge clk);       // multiply registered on this edge
    #1;                   // stage-2 combinational settle
    if (q !== 8'(exp)) begin
      $error("acc=%08h mult=%06h shift=%0d relu=%0d: got %0d, expected %0d",
             acc_h, mult_h, sh, relu, q, exp);
      errors++;
      if (errors > 20) $fatal(1, "too many errors");
    end
    checked++;
  endtask

  initial begin
    int fd, code, sh, relu, exp;
    logic [31:0] acc_h;
    logic [23:0] mult_h;
    logic signed [7:0] q_frozen;
    string path;

    if (!$value$plusargs("CASES=%s", path))
      $fatal(1, "requant_unit_tb: +CASES=<file> required");

    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);

    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    while (1) begin
      code = $fscanf(fd, "%h %h %d %d %d\n", acc_h, mult_h, sh, relu, exp);
      if (code != 5) break;
      check_case(acc_h, mult_h, sh, relu, exp);
    end
    $fclose(fd);

    if (checked == 0) $fatal(1, "requant_unit_tb: no cases parsed from %s", path);

    // en low must freeze the registered product: change the inputs under
    // !en and require q to hold the previous case's value.
    q_frozen = q;
    en  = 0;
    acc = ~acc;
    repeat (2) @(posedge clk);
    #1;
    if (q !== q_frozen) begin
      $error("en=0 did not freeze the pipeline: q %0d -> %0d", q_frozen, q);
      errors++;
    end
    en = 1;

    if (errors == 0) $display("requant_unit_tb: PASS (%0d cases + freeze)", checked);
    else begin
      $display("requant_unit_tb: FAIL (%0d errors of %0d)", errors, checked);
      $fatal(1, "requant_unit_tb failed");
    end
    $finish;
  end

endmodule
