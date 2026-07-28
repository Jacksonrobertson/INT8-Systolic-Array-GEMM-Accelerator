# Constraints for gemm_top (Phase 4). Starting point — revisit I/O budgets
# once the first clean run shows where slack actually is.

set clk_period $::env(CLOCK_PERIOD)
create_clock -name clk -period $clk_period [get_ports clk]

set_clock_uncertainty [expr {0.05 * $clk_period}] [get_clocks clk]
set_clock_transition 0.15 [get_clocks clk]

# Streaming I/O: assume an external registered producer/consumer with ~30% of
# the period spent off-chip. tready paths are combinational through the DUT
# (tready may depend on tvalid, SPEC 6.1), so input->output feedthrough on the
# handshake nets is real and must be timed, not falsely pathed.
set in_delay  [expr {0.3 * $clk_period}]
set out_delay [expr {0.3 * $clk_period}]

set_input_delay  $in_delay  -clock clk [all_inputs -no_clocks]
set_output_delay $out_delay -clock clk [all_outputs]

# Configuration inputs are stable during a run (sampled at start); constrain
# them loosely rather than falsely pathing them so a slow cfg_mult into the
# combinational requant unit still surfaces as the real path it is.
set_input_delay [expr {0.1 * $clk_period}] -clock clk \
    [get_ports {cfg_m* cfg_k* cfg_n* cfg_quant_en cfg_mult* cfg_shift*}]

set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 [all_inputs -no_clocks]
set_load 0.05 [all_outputs]
