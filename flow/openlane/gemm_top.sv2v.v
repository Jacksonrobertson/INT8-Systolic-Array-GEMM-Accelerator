module pe (
	clk,
	rst_n,
	en,
	a_in,
	a_out,
	swap_in,
	swap_out,
	psum_in,
	psum_out,
	w_in,
	w_out,
	w_shift_en,
	swap_bcast
);
	parameter signed [31:0] DW_IN = 8;
	parameter signed [31:0] DW_ACC = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire signed [DW_IN - 1:0] a_in;
	output reg signed [DW_IN - 1:0] a_out;
	input wire swap_in;
	output reg swap_out;
	input wire signed [DW_ACC - 1:0] psum_in;
	output reg signed [DW_ACC - 1:0] psum_out;
	input wire signed [DW_IN - 1:0] w_in;
	output wire signed [DW_IN - 1:0] w_out;
	input wire w_shift_en;
	input wire swap_bcast;
	reg signed [DW_IN - 1:0] w_reg;
	reg signed [DW_IN - 1:0] w_shadow;
	wire signed [(2 * DW_IN) - 1:0] prod;
	assign prod = a_in * w_reg;
	assign w_out = w_shadow;
	function automatic signed [DW_ACC - 1:0] sv2v_cast_F992E_signed;
		input reg signed [DW_ACC - 1:0] inp;
		sv2v_cast_F992E_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			a_out <= 1'sb0;
			swap_out <= 1'b0;
			psum_out <= 1'sb0;
			w_reg <= 1'sb0;
			w_shadow <= 1'sb0;
		end
		else if (en) begin
			a_out <= a_in;
			swap_out <= swap_in;
			psum_out <= psum_in + sv2v_cast_F992E_signed(prod);
			if (swap_in || swap_bcast)
				w_reg <= w_shadow;
			if (w_shift_en)
				w_shadow <= w_in;
		end
endmodule
module pe_array (
	clk,
	rst_n,
	en,
	a_west,
	swap_west,
	w_top,
	w_shift_en,
	swap_bcast,
	psum_south
);
	parameter signed [31:0] N = 8;
	parameter signed [31:0] DW_IN = 8;
	parameter signed [31:0] DW_ACC = 32;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire [(N * DW_IN) - 1:0] a_west;
	input wire [N - 1:0] swap_west;
	input wire [(N * DW_IN) - 1:0] w_top;
	input wire [N - 1:0] w_shift_en;
	input wire swap_bcast;
	output wire [(N * DW_ACC) - 1:0] psum_south;
	wire [DW_IN - 1:0] a_h [0:N - 1][0:N - 1];
	wire swap_h [0:N - 1][0:N - 1];
	wire [DW_ACC - 1:0] psum_v [0:N - 1][0:N - 1];
	wire [DW_IN - 1:0] w_v [0:N - 1][0:N - 1];
	genvar _gv_i_1;
	generate
		for (_gv_i_1 = 0; _gv_i_1 < N; _gv_i_1 = _gv_i_1 + 1) begin : g_row
			localparam i = _gv_i_1;
			genvar _gv_j_1;
			for (_gv_j_1 = 0; _gv_j_1 < N; _gv_j_1 = _gv_j_1 + 1) begin : g_col
				localparam j = _gv_j_1;
				localparam signed [31:0] sv2v_uu_u_pe_DW_ACC = DW_ACC;
				localparam signed [DW_ACC - 1:0] sv2v_uu_u_pe_ext_psum_in_0 = 1'sb0;
				pe #(
					.DW_IN(DW_IN),
					.DW_ACC(DW_ACC)
				) u_pe(
					.clk(clk),
					.rst_n(rst_n),
					.en(en),
					.a_in((j == 0 ? a_west[i * DW_IN+:DW_IN] : a_h[i][j - 1])),
					.a_out(a_h[i][j]),
					.swap_in((j == 0 ? swap_west[i] : swap_h[i][j - 1])),
					.swap_out(swap_h[i][j]),
					.psum_in((i == 0 ? sv2v_uu_u_pe_ext_psum_in_0 : psum_v[i - 1][j])),
					.psum_out(psum_v[i][j]),
					.w_in((i == 0 ? w_top[j * DW_IN+:DW_IN] : w_v[i - 1][j])),
					.w_out(w_v[i][j]),
					.w_shift_en(w_shift_en[j]),
					.swap_bcast(swap_bcast)
				);
			end
		end
	endgenerate
	genvar _gv_j_2;
	generate
		for (_gv_j_2 = 0; _gv_j_2 < N; _gv_j_2 = _gv_j_2 + 1) begin : g_south
			localparam j = _gv_j_2;
			assign psum_south[j * DW_ACC+:DW_ACC] = psum_v[N - 1][j];
		end
	endgenerate
endmodule
module skew_buffer (
	clk,
	rst_n,
	en,
	din,
	dout
);
	parameter signed [31:0] N = 8;
	parameter signed [31:0] DW = 8;
	parameter [0:0] DELAY_ASC = 1;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire [(N * DW) - 1:0] din;
	output wire [(N * DW) - 1:0] dout;
	genvar _gv_i_2;
	generate
		for (_gv_i_2 = 0; _gv_i_2 < N; _gv_i_2 = _gv_i_2 + 1) begin : g_lane
			localparam i = _gv_i_2;
			localparam signed [31:0] D = (DELAY_ASC ? i : (N - 1) - i);
			if (D == 0) begin : g_wire
				assign dout[i * DW+:DW] = din[i * DW+:DW];
			end
			else begin : g_delay
				reg [(D * DW) - 1:0] sr;
				always @(posedge clk or negedge rst_n)
					if (!rst_n)
						sr <= 1'sb0;
					else if (en) begin
						sr[0+:DW] <= din[i * DW+:DW];
						begin : sv2v_autoblock_1
							reg signed [31:0] k;
							for (k = 1; k < D; k = k + 1)
								sr[k * DW+:DW] <= sr[(k - 1) * DW+:DW];
						end
					end
				assign dout[i * DW+:DW] = sr[(D - 1) * DW+:DW];
			end
		end
	endgenerate
endmodule
module systolic_array (
	clk,
	rst_n,
	en,
	a_row,
	a_valid,
	swap_row,
	a_tag,
	w_top,
	w_shift_en,
	swap_bcast,
	c_row,
	c_valid,
	c_tag
);
	parameter signed [31:0] N = 8;
	parameter signed [31:0] DW_IN = 8;
	parameter signed [31:0] DW_ACC = 32;
	parameter signed [31:0] TAG_W = 2;
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire [(N * DW_IN) - 1:0] a_row;
	input wire a_valid;
	input wire swap_row;
	input wire [TAG_W - 1:0] a_tag;
	input wire [(N * DW_IN) - 1:0] w_top;
	input wire w_shift_en;
	input wire swap_bcast;
	output wire [(N * DW_ACC) - 1:0] c_row;
	output wire c_valid;
	output wire [TAG_W - 1:0] c_tag;
	localparam signed [31:0] LATENCY = (2 * N) - 1;
	wire [(N * DW_IN) - 1:0] a_gated;
	wire [N - 1:0] swap_bcast_lanes;
	wire [(N * DW_IN) - 1:0] a_west;
	wire [N - 1:0] swap_west_p;
	wire [N - 1:0] swap_west;
	assign a_gated = (a_valid ? a_row : {N * DW_IN {1'sb0}});
	skew_buffer #(
		.N(N),
		.DW(DW_IN),
		.DELAY_ASC(1)
	) u_skew_a(
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.din(a_gated),
		.dout(a_west)
	);
	genvar _gv_i_3;
	generate
		for (_gv_i_3 = 0; _gv_i_3 < N; _gv_i_3 = _gv_i_3 + 1) begin : g_swap_in
			localparam i = _gv_i_3;
			assign swap_bcast_lanes[i] = swap_row & a_valid;
		end
	endgenerate
	skew_buffer #(
		.N(N),
		.DW(1),
		.DELAY_ASC(1)
	) u_skew_swap(
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.din(swap_bcast_lanes),
		.dout(swap_west_p)
	);
	genvar _gv_i_4;
	generate
		for (_gv_i_4 = 0; _gv_i_4 < N; _gv_i_4 = _gv_i_4 + 1) begin : g_swap_flat
			localparam i = _gv_i_4;
			assign swap_west[i] = swap_west_p[i];
		end
	endgenerate
	wire [(N * DW_IN) - 1:0] w_top_skewed;
	wire [N - 1:0] w_shift_lanes;
	wire [N - 1:0] w_shift_skewed_p;
	wire [N - 1:0] w_shift_skewed;
	skew_buffer #(
		.N(N),
		.DW(DW_IN),
		.DELAY_ASC(1)
	) u_skew_w(
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.din(w_top),
		.dout(w_top_skewed)
	);
	genvar _gv_j_3;
	generate
		for (_gv_j_3 = 0; _gv_j_3 < N; _gv_j_3 = _gv_j_3 + 1) begin : g_wshift
			localparam j = _gv_j_3;
			assign w_shift_lanes[j] = w_shift_en;
			assign w_shift_skewed[j] = w_shift_skewed_p[j];
		end
	endgenerate
	skew_buffer #(
		.N(N),
		.DW(1),
		.DELAY_ASC(1)
	) u_skew_wen(
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.din(w_shift_lanes),
		.dout(w_shift_skewed_p)
	);
	wire [(N * DW_ACC) - 1:0] psum_south;
	pe_array #(
		.N(N),
		.DW_IN(DW_IN),
		.DW_ACC(DW_ACC)
	) u_grid(
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.a_west(a_west),
		.swap_west(swap_west),
		.w_top(w_top_skewed),
		.w_shift_en(w_shift_skewed),
		.swap_bcast(swap_bcast),
		.psum_south(psum_south)
	);
	skew_buffer #(
		.N(N),
		.DW(DW_ACC),
		.DELAY_ASC(0)
	) u_deskew_c(
		.clk(clk),
		.rst_n(rst_n),
		.en(en),
		.din(psum_south),
		.dout(c_row)
	);
	reg [LATENCY - 1:0] valid_sr;
	reg [(LATENCY * TAG_W) - 1:0] tag_sr;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			valid_sr <= 1'sb0;
			tag_sr <= 1'sb0;
		end
		else if (en) begin
			valid_sr <= {valid_sr[LATENCY - 2:0], a_valid};
			begin : sv2v_autoblock_1
				reg signed [31:0] s;
				for (s = LATENCY - 1; s > 0; s = s - 1)
					tag_sr[s * TAG_W+:TAG_W] <= tag_sr[(s - 1) * TAG_W+:TAG_W];
			end
			tag_sr[0+:TAG_W] <= a_tag;
		end
	assign c_valid = valid_sr[LATENCY - 1];
	assign c_tag = tag_sr[(LATENCY - 1) * TAG_W+:TAG_W];
endmodule
module weight_buffer (
	clk,
	rst_n,
	col_data,
	col_valid,
	col_ready,
	bank_swap,
	fill_full,
	rd_row,
	w_row
);
	parameter signed [31:0] N = 8;
	parameter signed [31:0] DW_IN = 8;
	input wire clk;
	input wire rst_n;
	input wire [(N * DW_IN) - 1:0] col_data;
	input wire col_valid;
	output wire col_ready;
	input wire bank_swap;
	output wire fill_full;
	input wire [$clog2(N) - 1:0] rd_row;
	output wire [(N * DW_IN) - 1:0] w_row;
	localparam signed [31:0] CNT_W = $clog2(N + 1);
	reg [(N * DW_IN) - 1:0] mem [0:1][0:N - 1];
	reg fill_bank;
	reg [CNT_W - 1:0] col_cnt;
	function automatic signed [CNT_W - 1:0] sv2v_cast_7B3D1_signed;
		input reg signed [CNT_W - 1:0] inp;
		sv2v_cast_7B3D1_signed = inp;
	endfunction
	assign fill_full = col_cnt == sv2v_cast_7B3D1_signed(N);
	assign col_ready = !fill_full;
	assign w_row = mem[!fill_bank][rd_row];
	wire col_fire = col_valid && col_ready;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			fill_bank <= 1'b0;
			col_cnt <= 1'sb0;
		end
		else begin
			if (bank_swap) begin
				fill_bank <= !fill_bank;
				col_cnt <= 1'sb0;
			end
			else if (col_fire)
				col_cnt <= col_cnt + 1'b1;
			if (col_fire) begin : sv2v_autoblock_1
				reg signed [31:0] i;
				for (i = 0; i < N; i = i + 1)
					mem[fill_bank][i][col_cnt[$clog2(N) - 1:0] * DW_IN+:DW_IN] <= col_data[i * DW_IN+:DW_IN];
			end
		end
endmodule
module accum_ram (
	clk,
	rst_n,
	en,
	in_valid,
	in_addr,
	in_data,
	in_first,
	in_last,
	out_valid,
	out_addr,
	out_data
);
	reg _sv2v_0;
	parameter signed [31:0] N = 8;
	parameter signed [31:0] DW_ACC = 32;
	parameter signed [31:0] M_MAX = 256;
	parameter signed [31:0] ADDR_W = $clog2(M_MAX);
	input wire clk;
	input wire rst_n;
	input wire en;
	input wire in_valid;
	input wire [ADDR_W - 1:0] in_addr;
	input wire [(N * DW_ACC) - 1:0] in_data;
	input wire in_first;
	input wire in_last;
	output reg out_valid;
	output reg [ADDR_W - 1:0] out_addr;
	output reg [(N * DW_ACC) - 1:0] out_data;
	reg [(N * DW_ACC) - 1:0] mem [0:M_MAX - 1];
	reg s1_valid;
	reg s1_first;
	reg s1_last;
	reg [ADDR_W - 1:0] s1_addr;
	reg [(N * DW_ACC) - 1:0] s1_data;
	reg [(N * DW_ACC) - 1:0] rd_q;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			s1_valid <= 1'b0;
			s1_first <= 1'b0;
			s1_last <= 1'b0;
			s1_addr <= 1'sb0;
			s1_data <= 1'sb0;
			rd_q <= 1'sb0;
		end
		else if (en) begin
			s1_valid <= in_valid;
			s1_first <= in_first;
			s1_last <= in_last;
			s1_addr <= in_addr;
			s1_data <= in_data;
			rd_q <= mem[in_addr];
		end
	reg [(N * DW_ACC) - 1:0] sum;
	function automatic signed [DW_ACC - 1:0] sv2v_cast_F992E_signed;
		input reg signed [DW_ACC - 1:0] inp;
		sv2v_cast_F992E_signed = inp;
	endfunction
	always @(*) begin
		if (_sv2v_0)
			;
		begin : sv2v_autoblock_1
			reg signed [31:0] j;
			for (j = 0; j < N; j = j + 1)
				sum[j * DW_ACC+:DW_ACC] = (s1_first ? sv2v_cast_F992E_signed(0) : rd_q[j * DW_ACC+:DW_ACC]) + s1_data[j * DW_ACC+:DW_ACC];
		end
	end
	always @(posedge clk)
		if (en && s1_valid)
			mem[s1_addr] <= sum;
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			out_valid <= 1'b0;
			out_addr <= 1'sb0;
			out_data <= 1'sb0;
		end
		else if (en) begin
			out_valid <= s1_valid && s1_last;
			out_addr <= s1_addr;
			out_data <= sum;
		end
	initial _sv2v_0 = 0;
endmodule
module gemm_ctrl (
	clk,
	rst_n,
	core_en,
	start,
	cfg_m,
	cfg_k,
	cfg_n,
	busy,
	done,
	wb_fill_full,
	wb_bank_swap,
	wb_rd_row,
	w_shift_en,
	swap_bcast,
	swap_row,
	a_stream,
	a_fire,
	a_tag,
	dim_m,
	dim_n,
	state
);
	parameter signed [31:0] N = 8;
	parameter signed [31:0] M_MAX = 256;
	input wire clk;
	input wire rst_n;
	input wire core_en;
	input wire start;
	localparam signed [31:0] gemm_pkg_DIM_W = 16;
	input wire [15:0] cfg_m;
	input wire [15:0] cfg_k;
	input wire [15:0] cfg_n;
	output reg busy;
	output reg done;
	input wire wb_fill_full;
	output wire wb_bank_swap;
	output wire [$clog2(N) - 1:0] wb_rd_row;
	output wire w_shift_en;
	output wire swap_bcast;
	output wire swap_row;
	output wire a_stream;
	input wire a_fire;
	output wire [1:0] a_tag;
	output wire [15:0] dim_m;
	output wire [15:0] dim_n;
	output reg [5:0] state;
	localparam signed [31:0] LOG2N = $clog2(N);
	localparam signed [31:0] LATENCY = (2 * N) - 1;
	localparam signed [31:0] DRAIN_CYC = LATENCY + 2;
	localparam signed [31:0] DRAIN_W = $clog2(DRAIN_CYC + 1);
	localparam signed [31:0] SET_W = $clog2(N + 1);
	localparam signed [31:0] HOLD_W = $clog2(N + 1);
	reg [15:0] m_q;
	reg [15:0] k_q;
	reg [15:0] n_q;
	reg [15:0] kt;
	reg [15:0] nt;
	reg [15:0] l_kt;
	reg [15:0] l_nt;
	reg l_done;
	reg [15:0] row_cnt;
	reg [DRAIN_W - 1:0] drain_cnt;
	reg [2:0] wl_state;
	reg [SET_W - 1:0] wl_cnt;
	reg shadow_ready;
	reg shadow_settled;
	reg [HOLD_W - 1:0] hold_cnt;
	wire [15:0] kt_max = (k_q >> LOG2N) - 1'b1;
	wire [15:0] nt_max = (n_q >> LOG2N) - 1'b1;
	assign dim_m = m_q;
	assign dim_n = n_q;
	wire last_tile = (kt == kt_max) && (nt == nt_max);
	wire last_row = row_cnt == (m_q - 1'b1);
	wire need_swap = last_row && !last_tile;
	wire l_last = (l_kt == kt_max) && (l_nt == nt_max);
	assign wb_bank_swap = ((((wl_state == 3'b001) && !shadow_ready) && !l_done) && (hold_cnt == {HOLD_W {1'sb0}})) && wb_fill_full;
	assign w_shift_en = wl_state == 3'b010;
	function automatic signed [LOG2N - 1:0] sv2v_cast_A6148_signed;
		input reg signed [LOG2N - 1:0] inp;
		sv2v_cast_A6148_signed = inp;
	endfunction
	assign wb_rd_row = sv2v_cast_A6148_signed(N - 1) - wl_cnt[LOG2N - 1:0];
	assign swap_bcast = state == 6'b000100;
	assign a_stream = (state == 6'b001000) && !(need_swap && !shadow_ready);
	assign swap_row = a_fire && need_swap;
	assign a_tag = {kt == {16 {1'sb0}}, kt == kt_max};
	function automatic signed [SET_W - 1:0] sv2v_cast_DCA8A_signed;
		input reg signed [SET_W - 1:0] inp;
		sv2v_cast_DCA8A_signed = inp;
	endfunction
	function automatic signed [HOLD_W - 1:0] sv2v_cast_CFAF4_signed;
		input reg signed [HOLD_W - 1:0] inp;
		sv2v_cast_CFAF4_signed = inp;
	endfunction
	function automatic signed [DRAIN_W - 1:0] sv2v_cast_AEB9A_signed;
		input reg signed [DRAIN_W - 1:0] inp;
		sv2v_cast_AEB9A_signed = inp;
	endfunction
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			state <= 6'b000001;
			busy <= 1'b0;
			done <= 1'b0;
			m_q <= 1'sb0;
			k_q <= 1'sb0;
			n_q <= 1'sb0;
			kt <= 1'sb0;
			nt <= 1'sb0;
			l_kt <= 1'sb0;
			l_nt <= 1'sb0;
			l_done <= 1'b0;
			row_cnt <= 1'sb0;
			drain_cnt <= 1'sb0;
			wl_state <= 3'b001;
			wl_cnt <= 1'sb0;
			shadow_ready <= 1'b0;
			shadow_settled <= 1'b0;
			hold_cnt <= 1'sb0;
		end
		else if (core_en) begin
			if (hold_cnt != {HOLD_W {1'sb0}})
				hold_cnt <= hold_cnt - 1'b1;
			case (wl_state)
				3'b001:
					if (((!shadow_ready && !l_done) && (hold_cnt == {HOLD_W {1'sb0}})) && wb_fill_full) begin
						wl_cnt <= 1'sb0;
						wl_state <= 3'b010;
					end
				3'b010:
					if (wl_cnt == sv2v_cast_DCA8A_signed(N - 1)) begin
						wl_cnt <= 1'sb0;
						wl_state <= 3'b100;
						shadow_ready <= 1'b1;
						if (l_last)
							l_done <= 1'b1;
						else if (l_kt == kt_max) begin
							l_kt <= 1'sb0;
							l_nt <= l_nt + 1'b1;
						end
						else
							l_kt <= l_kt + 1'b1;
					end
					else
						wl_cnt <= wl_cnt + 1'b1;
				3'b100:
					if (wl_cnt == sv2v_cast_DCA8A_signed(N - 2)) begin
						wl_cnt <= 1'sb0;
						wl_state <= 3'b001;
						shadow_settled <= 1'b1;
					end
					else
						wl_cnt <= wl_cnt + 1'b1;
				default: wl_state <= 3'b001;
			endcase
			case (state)
				6'b000001:
					if (start) begin
						m_q <= cfg_m;
						k_q <= cfg_k;
						n_q <= cfg_n;
						kt <= 1'sb0;
						nt <= 1'sb0;
						l_kt <= 1'sb0;
						l_nt <= 1'sb0;
						l_done <= 1'b0;
						row_cnt <= 1'sb0;
						wl_state <= 3'b001;
						wl_cnt <= 1'sb0;
						shadow_ready <= 1'b0;
						shadow_settled <= 1'b0;
						hold_cnt <= 1'sb0;
						busy <= 1'b1;
						done <= 1'b0;
						state <= 6'b000010;
					end
				6'b000010:
					if (shadow_settled)
						state <= 6'b000100;
				6'b000100: begin
					shadow_ready <= 1'b0;
					shadow_settled <= 1'b0;
					row_cnt <= 1'sb0;
					state <= 6'b001000;
				end
				6'b001000:
					if (a_fire) begin
						if (last_row) begin
							if (last_tile) begin
								drain_cnt <= 1'sb0;
								state <= 6'b010000;
							end
							else begin
								shadow_ready <= 1'b0;
								shadow_settled <= 1'b0;
								row_cnt <= 1'sb0;
								hold_cnt <= sv2v_cast_CFAF4_signed(N - 2);
								if (kt == kt_max) begin
									kt <= 1'sb0;
									nt <= nt + 1'b1;
								end
								else
									kt <= kt + 1'b1;
							end
						end
						else
							row_cnt <= row_cnt + 1'b1;
					end
				6'b010000:
					if (drain_cnt == sv2v_cast_AEB9A_signed(DRAIN_CYC - 1))
						state <= 6'b100000;
					else
						drain_cnt <= drain_cnt + 1'b1;
				6'b100000: begin
					busy <= 1'b0;
					done <= 1'b1;
					state <= 6'b000001;
				end
				default: state <= 6'b000001;
			endcase
		end
endmodule
module requant_unit (
	acc,
	mult,
	shift,
	relu_en,
	q
);
	parameter signed [31:0] DW_ACC = 32;
	input wire signed [DW_ACC - 1:0] acc;
	input wire [23:0] mult;
	input wire [4:0] shift;
	input wire relu_en;
	output wire signed [7:0] q;
	wire signed [63:0] x;
	wire signed [63:0] prod;
	wire signed [63:0] rnd;
	wire signed [63:0] y;
	function automatic signed [63:0] sv2v_cast_64_signed;
		input reg signed [63:0] inp;
		sv2v_cast_64_signed = inp;
	endfunction
	assign x = (relu_en && acc[DW_ACC - 1] ? 64'sd0 : sv2v_cast_64_signed(acc));
	assign prod = x * $signed({40'b0000000000000000000000000000000000000000, mult});
	assign rnd = (shift != 5'd0 ? 64'sd1 << (shift - 5'd1) : 64'sd0);
	assign y = (prod + rnd) >>> shift;
	assign q = (y > 64'sd127 ? 8'sd127 : (y < -64'sd128 ? -8'sd128 : y[7:0]));
endmodule
module gemm_top (
	clk,
	rst_n,
	start,
	cfg_m,
	cfg_k,
	cfg_n,
	cfg_quant_en,
	cfg_mult,
	cfg_shift,
	busy,
	done,
	s_axis_w_tvalid,
	s_axis_w_tready,
	s_axis_w_tdata,
	s_axis_w_tlast,
	s_axis_a_tvalid,
	s_axis_a_tready,
	s_axis_a_tdata,
	s_axis_a_tlast,
	m_axis_c_tvalid,
	m_axis_c_tready,
	m_axis_c_tdata,
	m_axis_c_tlast
);
	parameter signed [31:0] N = 8;
	parameter signed [31:0] M_MAX = 256;
	input wire clk;
	input wire rst_n;
	input wire start;
	localparam signed [31:0] gemm_pkg_DIM_W = 16;
	input wire [15:0] cfg_m;
	input wire [15:0] cfg_k;
	input wire [15:0] cfg_n;
	input wire cfg_quant_en;
	input wire [23:0] cfg_mult;
	input wire [4:0] cfg_shift;
	output wire busy;
	output wire done;
	input wire s_axis_w_tvalid;
	output wire s_axis_w_tready;
	localparam signed [31:0] gemm_pkg_DW_IN = 8;
	input wire [(N * gemm_pkg_DW_IN) - 1:0] s_axis_w_tdata;
	input wire s_axis_w_tlast;
	input wire s_axis_a_tvalid;
	output wire s_axis_a_tready;
	input wire [(N * gemm_pkg_DW_IN) - 1:0] s_axis_a_tdata;
	input wire s_axis_a_tlast;
	output wire m_axis_c_tvalid;
	input wire m_axis_c_tready;
	localparam signed [31:0] gemm_pkg_DW_ACC = 32;
	output wire [(N * gemm_pkg_DW_ACC) - 1:0] m_axis_c_tdata;
	output wire m_axis_c_tlast;
	localparam signed [31:0] LOG2N = $clog2(N);
	localparam signed [31:0] ADDR_W = $clog2(M_MAX);
	wire core_en;
	wire wb_fill_full;
	wire wb_bank_swap;
	wire wb_bank_swap_gated;
	wire [LOG2N - 1:0] wb_rd_row;
	wire w_shift_en;
	wire swap_bcast;
	wire swap_row;
	wire a_stream;
	wire a_fire;
	wire [1:0] a_tag;
	wire [15:0] dim_m;
	wire [15:0] dim_n;
	wire [5:0] state;
	gemm_ctrl #(
		.N(N),
		.M_MAX(M_MAX)
	) u_ctrl(
		.clk(clk),
		.rst_n(rst_n),
		.core_en(core_en),
		.start(start),
		.cfg_m(cfg_m),
		.cfg_k(cfg_k),
		.cfg_n(cfg_n),
		.busy(busy),
		.done(done),
		.wb_fill_full(wb_fill_full),
		.wb_bank_swap(wb_bank_swap),
		.wb_rd_row(wb_rd_row),
		.w_shift_en(w_shift_en),
		.swap_bcast(swap_bcast),
		.swap_row(swap_row),
		.a_stream(a_stream),
		.a_fire(a_fire),
		.a_tag(a_tag),
		.dim_m(dim_m),
		.dim_n(dim_n),
		.state(state)
	);
	wire in_starved;
	wire out_blocked;
	wire oq_can_accept;
	assign in_starved = a_stream && !s_axis_a_tvalid;
	wire acc_out_valid;
	assign out_blocked = acc_out_valid && !oq_can_accept;
	assign core_en = !in_starved && !out_blocked;
	assign s_axis_a_tready = a_stream && !out_blocked;
	assign a_fire = s_axis_a_tvalid && s_axis_a_tready;
	wire [(N * gemm_pkg_DW_IN) - 1:0] wb_col_data;
	wire [(N * gemm_pkg_DW_IN) - 1:0] wb_w_row;
	assign wb_col_data = s_axis_w_tdata;
	assign wb_bank_swap_gated = wb_bank_swap && core_en;
	weight_buffer #(
		.N(N),
		.DW_IN(gemm_pkg_DW_IN)
	) u_wbuf(
		.clk(clk),
		.rst_n(rst_n),
		.col_data(wb_col_data),
		.col_valid(s_axis_w_tvalid),
		.col_ready(s_axis_w_tready),
		.bank_swap(wb_bank_swap_gated),
		.fill_full(wb_fill_full),
		.rd_row(wb_rd_row),
		.w_row(wb_w_row)
	);
	wire [(N * gemm_pkg_DW_IN) - 1:0] arr_a_row;
	wire [(N * gemm_pkg_DW_ACC) - 1:0] arr_c_row;
	wire arr_c_valid;
	wire [1:0] arr_c_tag;
	assign arr_a_row = s_axis_a_tdata;
	systolic_array #(
		.N(N),
		.DW_IN(gemm_pkg_DW_IN),
		.DW_ACC(gemm_pkg_DW_ACC),
		.TAG_W(2)
	) u_array(
		.clk(clk),
		.rst_n(rst_n),
		.en(core_en),
		.a_row(arr_a_row),
		.a_valid(a_fire),
		.swap_row(swap_row),
		.a_tag(a_tag),
		.w_top(wb_w_row),
		.w_shift_en(w_shift_en),
		.swap_bcast(swap_bcast),
		.c_row(arr_c_row),
		.c_valid(arr_c_valid),
		.c_tag(arr_c_tag)
	);
	reg [15:0] acc_row;
	always @(posedge clk or negedge rst_n)
		if (!rst_n)
			acc_row <= 1'sb0;
		else if (core_en && arr_c_valid)
			acc_row <= (acc_row == (dim_m - 1'b1) ? {16 {1'sb0}} : acc_row + 1'b1);
	wire [ADDR_W - 1:0] acc_out_addr;
	wire [(N * gemm_pkg_DW_ACC) - 1:0] acc_out_data;
	accum_ram #(
		.N(N),
		.DW_ACC(gemm_pkg_DW_ACC),
		.M_MAX(M_MAX)
	) u_acc(
		.clk(clk),
		.rst_n(rst_n),
		.en(core_en),
		.in_valid(arr_c_valid),
		.in_addr(acc_row[ADDR_W - 1:0]),
		.in_data(arr_c_row),
		.in_first(arr_c_tag[1]),
		.in_last(arr_c_tag[0]),
		.out_valid(acc_out_valid),
		.out_addr(acc_out_addr),
		.out_data(acc_out_data)
	);
	reg oq_valid;
	reg oq_last;
	reg [(N * gemm_pkg_DW_ACC) - 1:0] oq_data;
	wire oq_load;
	assign oq_can_accept = !oq_valid || m_axis_c_tready;
	assign oq_load = acc_out_valid && core_en;
	wire [(N * 8) - 1:0] q_lane;
	wire [(N * gemm_pkg_DW_ACC) - 1:0] out_mux;
	genvar _gv_j_4;
	generate
		for (_gv_j_4 = 0; _gv_j_4 < N; _gv_j_4 = _gv_j_4 + 1) begin : g_requant
			localparam j = _gv_j_4;
			requant_unit #(.DW_ACC(gemm_pkg_DW_ACC)) u_rq(
				.acc(acc_out_data[j * gemm_pkg_DW_ACC+:gemm_pkg_DW_ACC]),
				.mult(cfg_mult),
				.shift(cfg_shift),
				.relu_en(1'b1),
				.q(q_lane[j * 8+:8])
			);
		end
	endgenerate
	assign out_mux = (cfg_quant_en ? {{(N * gemm_pkg_DW_ACC) - (N * 8) {1'b0}}, q_lane} : acc_out_data);
	reg [15:0] out_row;
	reg [15:0] out_nt;
	wire [15:0] nt_max = (dim_n >> LOG2N) - 1'b1;
	wire out_done = (out_row == (dim_m - 1'b1)) && (out_nt == nt_max);
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			out_row <= 1'sb0;
			out_nt <= 1'sb0;
		end
		else if (start) begin
			out_row <= 1'sb0;
			out_nt <= 1'sb0;
		end
		else if (oq_load) begin
			if (out_row == (dim_m - 1'b1)) begin
				out_row <= 1'sb0;
				out_nt <= out_nt + 1'b1;
			end
			else
				out_row <= out_row + 1'b1;
		end
	always @(posedge clk or negedge rst_n)
		if (!rst_n) begin
			oq_valid <= 1'b0;
			oq_data <= 1'sb0;
			oq_last <= 1'b0;
		end
		else if (oq_load) begin
			oq_valid <= 1'b1;
			oq_data <= out_mux;
			oq_last <= out_done;
		end
		else if (m_axis_c_tready)
			oq_valid <= 1'b0;
	assign m_axis_c_tvalid = oq_valid;
	assign m_axis_c_tdata = oq_data;
	assign m_axis_c_tlast = oq_last;
	wire unused = &{1'b0, s_axis_w_tlast, s_axis_a_tlast, acc_out_addr, state};
endmodule
