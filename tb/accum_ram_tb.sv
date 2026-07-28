// Unit test for accum_ram.sv.
//
// Models the `for kt:` inner loop the FSM will run: K passes of M result rows
// each, at addresses 0..M-1, with in_first on the first pass and in_last on
// the last. Checks that
//   - nothing is emitted except on the last pass,
//   - the emitted rows are the full lane-wise sum over all K passes,
//   - rows come out in address order, two cycles behind their input,
//   - a stall freezes the pipeline without dropping or duplicating a row.
//
// The lane-wise sum is the point of the value check: a single wide add would
// let a carry out of lane j corrupt lane j+1, which only shows up when a lane
// sum crosses its 32-bit boundary.
//
// See tb/skew_buffer_tb.sv for the NBA-driver style rule.
module accum_ram_tb;

  localparam int  N      = 4;
  localparam int  DW_ACC = 32;
  localparam int  M_MAX  = 16;
  localparam int  ADDR_W = $clog2(M_MAX);
  localparam int  M      = 6;   // rows per pass
  localparam int  K      = 3;   // tile passes accumulated
  localparam time TCK    = 10ns;

  logic clk = 0, rst_n = 0, en = 1;
  logic                     in_valid, in_first, in_last;
  logic [ADDR_W-1:0]        in_addr;
  logic [N-1:0][DW_ACC-1:0] in_data;
  logic                     out_valid;
  logic [ADDR_W-1:0]        out_addr;
  logic [N-1:0][DW_ACC-1:0] out_data;

  int errors = 0;

  always #(TCK/2) clk = ~clk;

  accum_ram #(.N(N), .DW_ACC(DW_ACC), .M_MAX(M_MAX)) dut (.*);

  // ---- reference --------------------------------------------------------
  logic signed [DW_ACC-1:0] data [K][M][N];
  logic signed [DW_ACC-1:0] ref_sum  [M][N];

  initial begin
    for (int kt = 0; kt < K; kt++)
      for (int r = 0; r < M; r++)
        for (int j = 0; j < N; j++) begin
          // Deterministic, signed, and large enough that a lane sum lands
          // near the 32-bit boundary on at least one lane.
          automatic logic signed [DW_ACC-1:0] v =
              32'sd715827882 * (j == 1 ? 1 : 0)            // pushes lane 1 high
            + 32'sd104729 * kt - 32'sd7919 * r - 32'sd1299709 * j;
          data[kt][r][j] = v;
        end
    for (int r = 0; r < M; r++)
      for (int j = 0; j < N; j++) begin
        automatic logic signed [DW_ACC-1:0] s = '0;
        for (int kt = 0; kt < K; kt++) s += data[kt][r][j];
        ref_sum[r][j] = s;
      end
  end

  // ---- driver -----------------------------------------------------------
  typedef enum logic [1:0] { D_IDLE, D_RUN, D_DRAIN, D_END } dst_e;
  dst_e dst = D_IDLE;
  int   kt = 0, r = 0, dcnt = 0;
  bit   go = 0;

  // The driver honours `en` too: a stall freezes the producer as well as the
  // RAM, which is how the real datapath behaves under a global clock enable.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dst      <= D_IDLE;
      in_valid <= 1'b0;
      in_first <= 1'b0;
      in_last  <= 1'b0;
      in_addr  <= '0;
      in_data  <= '0;
      kt <= 0; r <= 0; dcnt <= 0;
    end else if (en) begin
      in_valid <= 1'b0;
      case (dst)
        D_IDLE: if (go) begin dst <= D_RUN; kt <= 0; r <= 0; end

        D_RUN: begin
          in_valid <= 1'b1;
          in_addr  <= ADDR_W'(r);
          in_first <= (kt == 0);
          in_last  <= (kt == K-1);
          for (int j = 0; j < N; j++) in_data[j] <= data[kt][r][j];
          if (r == M-1) begin
            r <= 0;
            if (kt == K-1) begin dst <= D_DRAIN; dcnt <= 0; end
            else kt <= kt + 1;
          end else begin
            r <= r + 1;
          end
        end

        D_DRAIN: begin
          dcnt <= dcnt + 1;
          if (dcnt == 6) dst <= D_END;
        end

        D_END: ;
        default: dst <= D_IDLE;
      endcase
    end
  end

  // ---- monitor ----------------------------------------------------------
  // Counted in ENABLED cycles only: a stalled cycle holds every register,
  // including out_valid, and must not be counted twice.
  int ecyc = -1, out_seen = 0, first_out_ecyc = -1;

  always @(negedge clk) begin
    if (rst_n && en) begin
      if (ecyc >= 0)          ecyc = ecyc + 1;
      else if (in_valid)      ecyc = 0;

      if (out_valid) begin
        if (first_out_ecyc < 0) first_out_ecyc = ecyc;
        if (out_seen >= M) begin
          $error("extra output beat #%0d", out_seen);
          errors++;
        end else begin
          if (out_addr !== ADDR_W'(out_seen)) begin
            $error("output %0d has addr %0d, expected %0d", out_seen, out_addr, out_seen);
            errors++;
          end
          for (int j = 0; j < N; j++)
            if ($signed(out_data[j]) !== ref_sum[out_seen][j]) begin
              $error("row %0d lane %0d: got %0d, expected %0d",
                     out_seen, j, $signed(out_data[j]), ref_sum[out_seen][j]);
              errors++;
            end
        end
        out_seen++;
      end
    end
  end

  // Stall in the middle of the second pass, with rows in flight in both
  // pipeline stages and a partially accumulated row in the RAM.
  initial begin
    wait (rst_n && dst == D_RUN && kt == 1 && r == M/2);
    @(negedge clk);
    en = 0;
    repeat (5) @(negedge clk);
    en = 1;
  end

  // ---- sequencing -------------------------------------------------------
  initial begin
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    go = 1;

    wait (dst == D_END);
    repeat (4) @(posedge clk);

    if (out_seen != M) begin
      $error("got %0d output rows, expected %0d", out_seen, M);
      errors++;
    end
    // Rows are only emitted on the last pass, so the first output trails the
    // first input of that pass -- (K-1)*M cycles in -- by the 2-cycle
    // read/accumulate pipeline.
    if (first_out_ecyc != (K-1)*M + 2) begin
      $error("first output at enabled-cycle %0d, expected %0d",
             first_out_ecyc, (K-1)*M + 2);
      errors++;
    end

    if (errors == 0)
      $display("accum_ram_tb: PASS (%0d rows, %0d passes, first out @ecyc %0d)",
               out_seen, K, first_out_ecyc);
    else begin
      $display("accum_ram_tb: FAIL (%0d errors)", errors);
      $fatal(1, "accum_ram_tb failed");
    end
    $finish;
  end

  initial begin
    #(TCK * 100000);
    $fatal(1, "accum_ram_tb: timeout");
  end

endmodule
