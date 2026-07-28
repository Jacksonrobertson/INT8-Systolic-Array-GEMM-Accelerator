// Unit test for requant_unit.sv against the golden model.
//
// Reads vectors/requant/cases.txt, produced by model/generate_requant_vectors
// from requantize() itself, and requires an exact match on every case. The
// vector set targets the SHIFT=0 no-rounding rule, exact round-half-up
// boundaries, saturation both ways, ReLU on and off, and the INT32 extremes,
// plus a randomised sweep over the whole legal (mult, shift) space.
//
// requant_unit is combinational, so this needs no clock; each case is applied
// and checked after a settling delay.
module requant_unit_tb;

  localparam int DW_ACC = 32;

  logic signed [DW_ACC-1:0] acc;
  logic        [23:0]       mult;
  logic        [4:0]        shift;
  logic                     relu_en;
  logic signed [7:0]        q;

  int errors = 0;
  int checked = 0;

  requant_unit #(.DW_ACC(DW_ACC)) dut (
    .acc(acc), .mult(mult), .shift(shift), .relu_en(relu_en), .q(q));

  initial begin
    int fd, code, sh, relu, exp;
    logic [31:0] acc_h;
    logic [23:0] mult_h;
    string path;

    if (!$value$plusargs("CASES=%s", path))
      $fatal(1, "requant_unit_tb: +CASES=<file> required");

    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "cannot open %s", path);

    forever begin
      code = $fscanf(fd, "%h %h %d %d %d\n", acc_h, mult_h, sh, relu, exp);
      if (code != 5) break;

      acc     = acc_h;
      mult    = mult_h;
      shift   = 5'(sh);
      relu_en = relu[0];
      #1;   // combinational settle

      if (q !== 8'(exp)) begin
        $error("acc=%08h mult=%06h shift=%0d relu=%0d: got %0d, expected %0d",
               acc_h, mult_h, sh, relu, q, exp);
        errors++;
        if (errors > 20) $fatal(1, "too many errors");
      end
      checked++;
    end
    $fclose(fd);

    if (checked == 0) $fatal(1, "requant_unit_tb: no cases parsed from %s", path);

    if (errors == 0) $display("requant_unit_tb: PASS (%0d cases)", checked);
    else begin
      $display("requant_unit_tb: FAIL (%0d errors of %0d)", errors, checked);
      $fatal(1, "requant_unit_tb failed");
    end
    $finish;
  end

endmodule
