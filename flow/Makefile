# Phase 4 flow prep.
#
# The RTL parses in mainline yosys directly (no sv2v/slang preprocessing):
# lane buses are flat vectors and package references are fully qualified,
# because yosys rejects multidimensional packed arrays and wildcard package
# imports. `make audit` is the gate that keeps it that way.
#
#   make audit     yosys elaboration + memory-inference check on rtl/

ROOT := $(abspath $(CURDIR)/..)

# gemm_pkg first; order of the rest is stable.
SRCS := $(ROOT)/rtl/gemm_pkg.sv \
        $(ROOT)/rtl/pe.sv \
        $(ROOT)/rtl/pe_array.sv \
        $(ROOT)/rtl/skew_buffer.sv \
        $(ROOT)/rtl/systolic_array.sv \
        $(ROOT)/rtl/weight_buffer.sv \
        $(ROOT)/rtl/accum_ram.sv \
        $(ROOT)/rtl/gemm_ctrl.sv \
        $(ROOT)/rtl/requant_unit.sv \
        $(ROOT)/rtl/gemm_top.sv

.PHONY: audit

# Elaborate at the tape-out parameterization and confirm (a) yosys still
# parses the RTL and (b) the accumulation RAM still infers as one memory
# (it maps to DFFs later, but a demotion HERE means an RTL change broke the
# synchronous-RMW pattern). The weight buffer's demotion to registers is
# expected and correct — it is inherently multiport.
audit:
	yosys -p "read_verilog -sv $(SRCS); \
	  hierarchy -top gemm_top -chparam N 8 -chparam M_MAX 32; \
	  proc; opt -fast; memory -nomap; stat" > /tmp/gemm_audit.log 2>&1 \
	  || { cat /tmp/gemm_audit.log; exit 1; }
	@grep -q '\$$mem_v2' /tmp/gemm_audit.log \
	  && echo "audit OK: yosys parses rtl/, accum RAM inferred as memory" \
	  || { echo "audit FAIL: no \$$mem_v2 — RAM demoted to registers"; exit 1; }
