// End-to-end test for gemm_top.sv against the golden model's test vectors.
//
// Drives the three AXI-Stream interfaces from vectors/<case>/{w,a,c}.memh in
// exactly the beat order model/generate_vectors.py documents, and checks every
// result beat and the final tlast.
//
// Run with +CASE=<vectors dir>; parameter N must match the case's n.
// +STALL=<pct> injects random gaps on the input streams and random backpressure
// on the output, exercising the global clock-enable stall path.
//
// See tb/skew_buffer_tb.sv for the NBA-driver style rule.
module gemm_top_tb;

  parameter int N = 4;

  localparam int  DW_IN   = 8;
  localparam int  DW_ACC  = 32;
  localparam int  M_MAX   = 256;
  localparam int  MAX_BEA = 8192;
  localparam time TCK     = 10ns;

  logic clk = 0, rst_n = 0;

  logic                start = 0;
  logic [15:0]         cfg_m, cfg_k, cfg_n;
  logic                cfg_quant_en = 0;
  logic [23:0]         cfg_mult = 1;
  logic [4:0]          cfg_shift = 0;
  logic                busy, done;

  logic                s_axis_w_tvalid, s_axis_w_tready, s_axis_w_tlast;
  logic [N*DW_IN-1:0]  s_axis_w_tdata;
  logic                s_axis_a_tvalid, s_axis_a_tready, s_axis_a_tlast;
  logic [N*DW_IN-1:0]  s_axis_a_tdata;
  logic                m_axis_c_tvalid, m_axis_c_tready, m_axis_c_tlast;
  logic [N*DW_ACC-1:0] m_axis_c_tdata;

  int errors = 0;

  always #(TCK/2) clk = ~clk;

  gemm_top #(.N(N), .M_MAX(M_MAX)) dut (.*);

  // ---- vectors -----------------------------------------------------------
  logic [N*DW_IN-1:0]  w_mem [0:MAX_BEA-1];
  logic [N*DW_IN-1:0]  a_mem [0:MAX_BEA-1];
  logic [N*DW_ACC-1:0] c_mem [0:MAX_BEA-1];
  logic [N*8-1:0]      cq_mem [0:MAX_BEA-1];

  string case_dir;
  int    p_m, p_k, p_n, p_nn, p_seed;
  int    w_total, a_total, c_total;
  int    stall_pct = 0;
  bit    quant     = 0;   // +QUANT=1 checks the INT8 output stage instead

  initial begin
    int fd, code;
    if (!$value$plusargs("CASE=%s", case_dir))
      $fatal(1, "gemm_top_tb: +CASE=<dir> required");
    void'($value$plusargs("STALL=%d", stall_pct));
    void'($value$plusargs("QUANT=%d", quant));

    fd = $fopen({case_dir, "/params.txt"}, "r");
    if (fd == 0) $fatal(1, "cannot open %s/params.txt", case_dir);
    code = $fscanf(fd, "M=%d K=%d N=%d n=%d seed=%d", p_m, p_k, p_nn, p_n, p_seed);
    if (code != 5) $fatal(1, "malformed params.txt (parsed %0d fields)", code);
    $fclose(fd);

    if (p_n != N) $fatal(1, "case is n=%0d but RTL built with N=%0d", p_n, N);
    if (p_m > M_MAX) $fatal(1, "M=%0d exceeds M_MAX=%0d", p_m, M_MAX);

    // Beat counts, per SPEC section 6.1 / generate_vectors.py.
    w_total = (p_nn/N) * (p_k/N) * N;
    a_total = (p_nn/N) * (p_k/N) * p_m;
    c_total = (p_nn/N) * p_m;

    $readmemh({case_dir, "/w.memh"}, w_mem);
    $readmemh({case_dir, "/a.memh"}, a_mem);
    $readmemh({case_dir, "/c.memh"}, c_mem);
    $readmemh({case_dir, "/cq.memh"}, cq_mem);

    if (quant) begin
      int qfd, qcode, qm, qs;
      qfd = $fopen({case_dir, "/qparams.txt"}, "r");
      if (qfd == 0) $fatal(1, "cannot open %s/qparams.txt", case_dir);
      qcode = $fscanf(qfd, "mult=%d shift=%d", qm, qs);
      if (qcode != 2) $fatal(1, "malformed qparams.txt");
      $fclose(qfd);
      cfg_mult     = 24'(qm);
      cfg_shift    = 5'(qs);
      cfg_quant_en = 1'b1;
      $display("             quant: mult=%0d shift=%0d", qm, qs);
    end

    cfg_m = 16'(p_m);
    cfg_k = 16'(p_k);
    cfg_n = 16'(p_nn);

    $display("gemm_top_tb: %s (M=%0d K=%0d N=%0d n=%0d, stall=%0d%%, quant=%0d)",
             case_dir, p_m, p_k, p_nn, p_n, stall_pct, quant);
    $display("             beats: w=%0d a=%0d c=%0d", w_total, a_total, c_total);
  end

  // ---- start pulse -------------------------------------------------------
  bit start_req = 0;
  bit started   = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start   <= 1'b0;
      started <= 1'b0;
    end else begin
      start <= 1'b0;
      if (start_req && !started) begin
        start   <= 1'b1;
        started <= 1'b1;
      end
    end
  end

  // ---- weight stream master ---------------------------------------------
  // Standard AXI-Stream master: tdata/tlast hold while tvalid && !tready, and
  // tvalid never waits on tready.
  int w_idx = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axis_w_tvalid <= 1'b0;
      s_axis_w_tdata  <= '0;
      s_axis_w_tlast  <= 1'b0;
      w_idx           <= 0;
    end else if (!s_axis_w_tvalid || s_axis_w_tready) begin
      if (w_idx < w_total && (stall_pct == 0 || ($urandom_range(99) >= stall_pct))) begin
        s_axis_w_tvalid <= 1'b1;
        s_axis_w_tdata  <= w_mem[w_idx];
        s_axis_w_tlast  <= ((w_idx % N) == N-1);  // last column of a tile
        w_idx           <= w_idx + 1;
      end else begin
        s_axis_w_tvalid <= 1'b0;
      end
    end
  end

  // ---- activation stream master -----------------------------------------
  int a_idx = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s_axis_a_tvalid <= 1'b0;
      s_axis_a_tdata  <= '0;
      s_axis_a_tlast  <= 1'b0;
      a_idx           <= 0;
    end else if (!s_axis_a_tvalid || s_axis_a_tready) begin
      if (a_idx < a_total && (stall_pct == 0 || ($urandom_range(99) >= stall_pct))) begin
        s_axis_a_tvalid <= 1'b1;
        s_axis_a_tdata  <= a_mem[a_idx];
        s_axis_a_tlast  <= ((a_idx % p_m) == p_m-1);  // last row of a block
        a_idx           <= a_idx + 1;
      end else begin
        s_axis_a_tvalid <= 1'b0;
      end
    end
  end

  // ---- result stream slave ----------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) m_axis_c_tready <= 1'b1;
    else        m_axis_c_tready <= (stall_pct == 0) ||
                                   ($urandom_range(99) >= stall_pct);
  end

  // Cycles from start to done, for comparing against the ideal schedule.
  int run_cycles = 0;
  bit counting = 0;
  always_ff @(posedge clk) if (counting) run_cycles <= run_cycles + 1;

  int c_idx = 0;

  always @(negedge clk) begin
    if (rst_n && m_axis_c_tvalid && m_axis_c_tready) begin
      if (c_idx >= c_total) begin
        $error("extra result beat #%0d", c_idx);
        errors++;
      end else begin
        // In quantized mode only the low N bytes carry results; the rest of
        // the bus must be zero.
        if (quant) begin
          if (m_axis_c_tdata[N*8-1:0] !== cq_mem[c_idx] ||
              m_axis_c_tdata[N*DW_ACC-1:N*8] !== '0) begin
            $error("quant beat %0d mismatch:\n  got %h\n  exp %h",
                   c_idx, m_axis_c_tdata[N*8-1:0], cq_mem[c_idx]);
            errors++;
          end
        end else if (m_axis_c_tdata !== c_mem[c_idx]) begin
          $error("result beat %0d mismatch:\n  got %h\n  exp %h",
                 c_idx, m_axis_c_tdata, c_mem[c_idx]);
          errors++;
        end
        if (m_axis_c_tlast !== (c_idx == c_total-1)) begin
          $error("beat %0d: tlast=%0b, expected %0b",
                 c_idx, m_axis_c_tlast, (c_idx == c_total-1));
          errors++;
        end
      end
      c_idx++;
    end
  end

  // ---- optional control trace (+DEBUG=1) ---------------------------------
  bit debug = 0;
  int dbg_cyc = 0;
  initial void'($value$plusargs("DEBUG=%d", debug));

  // Dump each PE's committed weight register, to compare against the tile the
  // array should be holding on that cycle.
  always @(negedge clk) if (debug && rst_n) begin
    dbg_cyc++;
    if (dbg_cyc < 220)
      $display("%4d st=%-9s wl=%b kt=%0d nt=%0d row=%0d | rdy=%b set=%b bswap=%b wsh=%b rd=%0d | astr=%b afire=%b swr=%b | cval=%b ctag=%b | oval=%b",
        dbg_cyc, dut.u_ctrl.state.name(), dut.u_ctrl.wl_state,
        dut.u_ctrl.kt, dut.u_ctrl.nt, dut.u_ctrl.row_cnt,
        dut.u_ctrl.shadow_ready, dut.u_ctrl.shadow_settled,
        dut.wb_bank_swap_gated, dut.w_shift_en, dut.wb_rd_row,
        dut.a_stream, dut.a_fire, dut.swap_row,
        dut.arr_c_valid, dut.arr_c_tag, dut.acc_out_valid);
  end

  // ---- sequencing --------------------------------------------------------
  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    start_req = 1;
    counting  = 1;

    // `done` reflects the schedule finishing; under backpressure the last
    // rows may still be draining through the output register behind it.
    wait (done);
    wait (c_idx == c_total);
    repeat (5) @(posedge clk);

    if (c_idx != c_total) begin
      $error("got %0d result beats, expected %0d", c_idx, c_total);
      errors++;
    end
    if (a_idx != a_total) begin
      $error("consumed %0d activation beats, expected %0d", a_idx, a_total);
      errors++;
    end

    begin
      // Ideal steady state is one activation row per cycle for every tile;
      // the rest is first-tile weight load, pipeline fill and drain.
      automatic int ideal = a_total;
      $display("             cycles=%0d ideal_stream=%0d overhead=%0d",
               run_cycles, ideal, run_cycles - ideal);
    end
    if (errors == 0) $display("gemm_top_tb: PASS (%0d result beats)", c_idx);
    else begin
      $display("gemm_top_tb: FAIL (%0d errors)", errors);
      $fatal(1, "gemm_top_tb failed");
    end
    $finish;
  end

  initial begin
    #(TCK * 2000000);
    $fatal(1, "gemm_top_tb: timeout (c_idx=%0d of %0d)", c_idx, c_total);
  end

endmodule
