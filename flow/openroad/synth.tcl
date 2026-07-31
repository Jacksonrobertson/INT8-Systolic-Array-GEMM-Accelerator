# Yosys synthesis to sky130_fd_sc_hd for the Phase 4 PPA study.
#
# Driven by environment variables (see run.sh):
#   LIB        liberty file (tt corner)
#   PERIOD_PS  ABC timing target in picoseconds
#   GEMM_N     array size          (default 8)
#   M_MAX      accumulation depth  (default 32 -- the tape-out config)
#   OUT        output directory
#
# Hierarchy is preserved (yosys `synth` does not flatten without -flatten), so
# `stat -liberty` reports per-module area -- the MACs-vs-buffers breakdown the
# writeup needs -- and instance prefixes survive into P&R.

yosys -import

set rtl  $::env(RTL_DIR)
set out  $::env(OUT)
set n    [expr {[info exists ::env(GEMM_N)] ? $::env(GEMM_N) : 8}]
set mmax [expr {[info exists ::env(M_MAX)]  ? $::env(M_MAX)  : 32}]

read_verilog -sv $rtl/gemm_pkg.sv $rtl/pe.sv $rtl/pe_array.sv \
    $rtl/skew_buffer.sv $rtl/systolic_array.sv $rtl/weight_buffer.sv \
    $rtl/accum_ram.sv $rtl/gemm_ctrl.sv $rtl/requant_unit.sv $rtl/gemm_top.sv

hierarchy -top gemm_top -chparam N $n -chparam M_MAX $mmax
synth -top gemm_top

dfflibmap -liberty $::env(LIB)
abc -D $::env(PERIOD_PS) -liberty $::env(LIB)
opt_clean -purge

# setundef: sky130 cells have no explicit x-handling; tie undriven bits low.
setundef -zero
splitnets -ports
hilomap -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO

tee -o $out/synth_stat.rpt stat -liberty $::env(LIB)
write_verilog -noattr -noexpr -nohex -nodec $out/gemm_top.synth.v
