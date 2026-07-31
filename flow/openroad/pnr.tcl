# OpenROAD place-and-route study flow for gemm_top on sky130hd (Phase 4).
#
# Study-level flow: floorplan -> global place -> repair -> detailed place ->
# CTS -> global route, with parasitic estimation and STA at each stage. It
# deliberately stops short of PDN + detailed routing + DRC/LVS signoff --
# those need the full OpenLane/ORFS harness; the numbers here are for the
# architecture-level PPA sweep (fmax trend, area, critical path identity),
# which global-route parasitics estimate well.
#
# Environment: LIB, TLEF, LEF, NETLIST, PERIOD_NS, UTIL, OUT.

set lib     $::env(LIB)
set period  $::env(PERIOD_NS)
set out     $::env(OUT)
set util    [expr {[info exists ::env(UTIL)] ? $::env(UTIL) : 40}]

read_liberty $lib
read_lef $::env(TLEF)
read_lef $::env(LEF)
read_verilog $::env(NETLIST)
link_design gemm_top

# ---- constraints (mirrors flow/openlane/constraints.sdc) -------------------
create_clock -name clk -period $period [get_ports clk]
set_clock_uncertainty [expr {0.05 * $period}] [get_clocks clk]
set nonclk {}
foreach p [all_inputs] {
  set name [get_property $p name]
  if {$name ne "clk" && $name ne "rst_n"} { lappend nonclk $p }
}
set_input_delay  [expr {0.3 * $period}] -clock clk $nonclk
set_output_delay [expr {0.3 * $period}] -clock clk [all_outputs]
# Configuration is quasi-static (sampled at start, stable during a run):
# loose 10% budget, mirroring flow/openlane/constraints.sdc, so cfg fanout
# does not masquerade as the critical path.
set_input_delay [expr {0.1 * $period}] -clock clk [get_ports {cfg_*}]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 $nonclk
set_load 0.05 [all_outputs]
# Async reset: assumed externally synchronized; recovery is not the study's
# subject and would otherwise dominate every report as a fake critical path.
set_false_path -from [get_ports rst_n]

# ---- floorplan -------------------------------------------------------------
initialize_floorplan -utilization $util -aspect_ratio 1.0 -core_space 2 \
    -site unithd
source $::env(SITE_TRACKS)
place_pins -hor_layers met3 -ver_layers met2

# ---- placement -------------------------------------------------------------
# No placement padding: post-CTS hold repair inserts delay buffers, and
# padded rows at this density leave detailed placement nowhere to legalize
# them (DPL-0036).
global_placement -density [expr {($util + 5) / 100.0}]
estimate_parasitics -placement
repair_design
detailed_placement

# ---- clock tree ------------------------------------------------------------
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_4 \
    -buf_list {sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8} \
    -sink_clustering_enable
set_propagated_clock [all_clocks]
detailed_placement

# ---- post-CTS timing repair ------------------------------------------------
estimate_parasitics -placement
repair_timing -setup
repair_timing -hold
detailed_placement

# ---- global route + final numbers -----------------------------------------
set_routing_layers -signal met1-met5 -clock met3-met5
global_route -congestion_iterations 30
estimate_parasitics -global_routing

# All output lands in pnr.log (run.sh redirects); summarize.py parses the
# marked sections. OpenROAD's non-STA commands do not support `>` redirection.
puts "==REPORT timing=="
report_checks -path_delay max -fields {slew cap input_pins} \
    -format full_clock_expanded -digits 3
puts "==REPORT wns=="
report_worst_slack -max
puts "==REPORT tns=="
report_tns
puts "==REPORT hold=="
report_worst_slack -min
puts "==REPORT power=="
report_power
puts "==REPORT area=="
report_design_area
puts "==REPORT clock_skew=="
report_clock_skew
puts "==REPORT end=="

exit
