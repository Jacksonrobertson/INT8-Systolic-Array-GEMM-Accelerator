# Phase 4 flow prep.
#
# Mainline yosys (what OpenLane runs) cannot parse this project's
# SystemVerilog — multidimensional packed array ports (logic [N-1:0][W-1:0])
# fail in its frontend — so the RTL is converted to Verilog-2005 with sv2v
# first and OpenLane consumes the converted file. Verified: sv2v v0.0.12
# output elaborates in yosys 0.33 and lints clean in Verilator 5.020.
#
#   make sv2v      regenerate openlane/gemm_top.sv2v.v from rtl/
#   make audit     yosys elaboration + memory-inference check on the output
#
# sv2v: https://github.com/zachjs/sv2v (static binary releases). Re-run
# `make sv2v` after ANY rtl/ change; CI should diff the checked-in copy.

ROOT := $(abspath $(CURDIR)/..)
SV2V ?= sv2v

# gemm_pkg first; order of the rest is stable for reproducible output.
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

OUT := $(CURDIR)/openlane/gemm_top.sv2v.v

.PHONY: sv2v audit clean

sv2v: $(OUT)

$(OUT): $(SRCS)
	$(SV2V) $(SRCS) > $@
	@echo "wrote $@ ($$(wc -l < $@) lines)"

# Elaborate at the tape-out parameterization and confirm the accumulation RAM
# still infers as one memory (it maps to DFFs later, but a demotion HERE means
# an RTL change broke the synchronous-RMW pattern).
audit: $(OUT)
	yosys -p "read_verilog $(OUT); \
	  hierarchy -top gemm_top -chparam N 8 -chparam M_MAX 32; \
	  proc; opt -fast; memory -nomap; stat" > /tmp/gemm_audit.log 2>&1 \
	  || { cat /tmp/gemm_audit.log; exit 1; }
	@grep -q '\$$mem_v2' /tmp/gemm_audit.log \
	  && echo "audit OK: accum RAM inferred as memory" \
	  || { echo "audit FAIL: no \$$mem_v2 — RAM demoted to registers"; exit 1; }

clean:
	rm -f $(OUT)
