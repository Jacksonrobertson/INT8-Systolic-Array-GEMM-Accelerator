// Array-level test for systolic_array.sv: one weight tile, one activation
// block, checked against the golden model for BOTH values and timing.
//
// Timing is not compared against a hand-derived latency. params.txt carries
// the cycle SystolicArraySim's own emergence log says a fully deskewed row 0
// becomes available, and the testbench requires result row r to land on
// exactly cycle latency+r -- so a pipeline that produced right answers in the
// wrong order, or with a bubble, still fails.
//
// Run with +CASE=<vectors/array_* dir>; parameter N must match the case.
// See tb/skew_buffer_tb.sv for the NBA-driver style rule these testbenches
// follow.
module systolic_array_tb;

  parameter int N = 4;

  localparam int  DW_IN  = 8;
  localparam int  DW_ACC = 32;
  localparam int  MAX_M  = 512;
  localparam time TCK    = 10ns;

  logic clk = 0, rst_n = 0;
  logic en = 1'b1;

  logic [N-1:0][DW_IN-1:0]  a_row;
  logic                     a_valid, swap_row;
  logic [N-1:0][DW_IN-1:0]  w_top;
  logic                     w_shift_en, swap_bcast;
  logic [N-1:0][DW_ACC-1:0] c_row;
  logic                     c_valid;
  // Tag passthrough is exercised at the top level; tied off here.
  logic [1:0]               a_tag = '0;
  logic [1:0]               c_tag;

  always #(TCK/2) clk = ~clk;

  systolic_array #(.N(N), .DW_IN(DW_IN), .DW_ACC(DW_ACC)) dut (.*);

  // ---- stimulus / expected data ----------------------------------------
  logic [N-1:0][DW_IN-1:0]  w_rows [0:N-1];
  logic [N-1:0][DW_IN-1:0]  a_mem  [0:MAX_M-1];
  logic [N-1:0][DW_ACC-1:0] c_exp  [0:MAX_M-1];

  string case_dir;
  int    n_param, m_param, lat_param, seed_param;
  int    errors = 0;

  initial begin
    int fd, code;
    if (!$value$plusargs("CASE=%s", case_dir))
      $fatal(1, "systolic_array_tb: +CASE=<dir> required");

    fd = $fopen({case_dir, "/params.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/params.txt", case_dir);
    code = $fscanf(fd, "n=%d M=%d latency=%d seed=%d",
                   n_param, m_param, lat_param, seed_param);
    if (code != 4) $fatal(1, "malformed params.txt (parsed %0d fields)", code);
    $fclose(fd);

    if (n_param != N)
      $fatal(1, "case is n=%0d but RTL built with N=%0d", n_param, N);
    if (m_param > MAX_M)
      $fatal(1, "M=%0d exceeds MAX_M=%0d", m_param, MAX_M);

    $readmemh({case_dir, "/w_rows.memh"}, w_rows);
    $readmemh({case_dir, "/a.memh"},      a_mem);
    $readmemh({case_dir, "/c.memh"},      c_exp);
    $display("systolic_array_tb: %s (n=%0d M=%0d latency=%0d)",
             case_dir, n_param, m_param, lat_param);
  end

  // ---- driver -----------------------------------------------------------
  typedef enum logic [2:0] {
    D_IDLE, D_WLOAD, D_SETTLE, D_SWAP, D_STREAM, D_DRAIN, D_END
  } dstate_e;

  dstate_e dstate = D_IDLE;
  int wcnt = 0, acnt = 0, dcnt = 0;
  bit go = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dstate     <= D_IDLE;
      a_row      <= '0;
      a_valid    <= 1'b0;
      swap_row   <= 1'b0;
      w_top      <= '0;
      w_shift_en <= 1'b0;
      swap_bcast <= 1'b0;
      wcnt       <= 0;
      acnt       <= 0;
      dcnt       <= 0;
    end else begin
      // Defaults; each state asserts only what it needs this cycle.
      a_valid    <= 1'b0;
      swap_row   <= 1'b0;
      w_shift_en <= 1'b0;
      swap_bcast <= 1'b0;

      case (dstate)
        D_IDLE: if (go) begin
          dstate <= D_WLOAD;
          wcnt   <= 0;
        end

        // Weights shift in from the top of each column, so the LAST row of
        // the tile must be pushed first to end up deepest in the array.
        D_WLOAD: begin
          w_shift_en <= 1'b1;
          w_top      <= w_rows[N-1-wcnt];
          wcnt       <= wcnt + 1;
          if (wcnt == N-1) begin
            wcnt   <= 0;
            dstate <= D_SETTLE;
          end
        end

        // The weight load is skewed by column (systolic_array.sv), so the last
        // column is still shifting for N-1 cycles after the source-side shift
        // ends. A broadcast commit must wait for all of them.
        D_SETTLE: begin
          wcnt <= wcnt + 1;
          if (wcnt == N-2) dstate <= D_SWAP;
        end

        // Array is idle and holds no wavefront, so a broadcast commit is safe
        // here. The diagonal swap_row path is exercised at the top level.
        D_SWAP: begin
          swap_bcast <= 1'b1;
          acnt       <= 0;
          dstate     <= D_STREAM;
        end

        D_STREAM: begin
          a_valid <= 1'b1;
          a_row   <= a_mem[acnt];
          acnt    <= acnt + 1;
          if (acnt == m_param-1) begin
            dcnt   <= 0;
            dstate <= D_DRAIN;
          end
        end

        D_DRAIN: begin
          dcnt <= dcnt + 1;
          if (dcnt == lat_param + 4) dstate <= D_END;
        end

        D_END: ;
        default: dstate <= D_IDLE;
      endcase
    end
  end

  // ---- monitor ----------------------------------------------------------
  // Sampled at negedge: mid-cycle, everything settled.
  int cyc = -1;          // cycles since activation row 0 was presented
  int out_count = 0;

  always @(negedge clk) begin
    if (cyc >= 0)       cyc = cyc + 1;
    else if (a_valid)   cyc = 0;

    if (rst_n && c_valid) begin
      if (out_count >= m_param) begin
        $error("extra result beat #%0d @cyc %0d", out_count, cyc);
        errors++;
      end else begin
        // Row r must land on exactly cycle latency+r: right value, right
        // cycle, one row per cycle with no gaps.
        if (cyc != lat_param + out_count) begin
          $error("row %0d landed on cycle %0d, expected %0d",
                 out_count, cyc, lat_param + out_count);
          errors++;
        end
        if (c_row !== c_exp[out_count]) begin
          $error("row %0d value mismatch:\n  got %h\n  exp %h",
                 out_count, c_row, c_exp[out_count]);
          errors++;
        end
        out_count++;
      end
    end
  end

  // ---- sequencing -------------------------------------------------------
  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    go = 1;

    wait (dstate == D_END);

    if (out_count != m_param) begin
      $error("got %0d result rows, expected %0d", out_count, m_param);
      errors++;
    end

    if (errors == 0)
      $display("systolic_array_tb: PASS (%0d rows, first @cyc %0d)",
               out_count, lat_param);
    else begin
      $display("systolic_array_tb: FAIL (%0d errors)", errors);
      $fatal(1, "systolic_array_tb failed");
    end
    $finish;
  end

  initial begin
    #(TCK * 100000);
    $fatal(1, "systolic_array_tb: timeout");
  end

endmodule
