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
set nonclk [lsearch -inline -all -not -exact [all_inputs] [get_ports clk]]
set_input_delay  [expr {0.3 * $period}] -clock clk $nonclk
set_output_delay [expr {0.3 * $period}] -clock clk [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 $nonclk
set_load 0.05 [all_outputs]

# ---- floorplan -------------------------------------------------------------
initialize_floorplan -utilization $util -aspect_ratio 1.0 -core_space 2 \
    -site unithd
source $::env(SITE_TRACKS)
place_pins -hor_layers met3 -ver_layers met2

# ---- placement -------------------------------------------------------------
global_placement -density [expr {($util + 5) / 100.0}]
estimate_parasitics -placement
repair_design
set_placement_padding -global -left 1 -right 1
detailed_placement

# ---- clock tree ------------------------------------------------------------
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_4 \
    -buf_list {sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8} \
    -sink_clustering_enable
set_propagated_clock [all_clocks]
detailed_placement

# ---- global route + final numbers -----------------------------------------
set_routing_layers -signal met1-met5 -clock met3-met5
global_route -congestion_iterations 30
estimate_parasitics -global_routing

tee -file $out/timing.rpt {report_checks -path_delay max -fields {slew cap input_pins} -format full_clock_expanded -digits 3}
tee -file $out/wns.rpt    {report_worst_slack -max}
tee -file $out/tns.rpt    {report_tns}
tee -file $out/hold.rpt   {report_worst_slack -min}
tee -file $out/power.rpt  {report_power}
tee -file $out/area.rpt   {report_design_area}
tee -file $out/clock.rpt  {report_clock_skew}

exit
