# Verilator simulation for the INT8 systolic GEMM accelerator.
#
#   make            build and run every tb/*_tb.sv
#   make pe_tb      build and run one testbench
#   make lint       lint the RTL only
#   make pe_tb WAVES=1   also dump sim/build/pe_tb.vcd
#   make clean
#
# Requires Verilator 5.x (uses --binary --timing to run SystemVerilog
# testbenches directly, no C++ harness).

ROOT      := $(abspath $(CURDIR)/..)
RTL       := $(ROOT)/rtl
TB        := $(ROOT)/tb
BUILD     := $(CURDIR)/build
VERILATOR ?= verilator

# gemm_pkg must compile first; the rest in stable order.
PKG      := $(RTL)/gemm_pkg.sv
RTL_SRCS := $(PKG) $(filter-out $(PKG),$(sort $(wildcard $(RTL)/*.sv)))
# Testbenches that need a parameter override and/or a +CASE argument get their
# own target below and are kept out of the generic list.
PARAM_TBS := systolic_array_tb gemm_top_tb requant_unit_tb
TESTS     := $(filter-out $(PARAM_TBS),$(basename $(notdir $(wildcard $(TB)/*_tb.sv))))

VFLAGS := --binary --timing -Wall -Wno-DECLFILENAME --assert +define+SIM_ASSERT \
          -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
ifeq ($(WAVES),1)
VFLAGS += --trace
endif

# Vectors are found relative to the repo root; testbenches take the path as a
# plusarg so the binary is runnable from anywhere.
RUNFLAGS := +VECTORS=$(ROOT)/vectors

.PHONY: all lint clean array top requant $(TESTS)

all: $(TESTS) requant array top

# Array-level tests: built once per array dimension, then run over every
# vectors/array_* case of that dimension.
ARRAY_N    := 4 8
ARRAY_RUNS := array_4x4_m4:4 array_4x4_m8:4 array_8x8_m16:8

# `set -e` so a failing case aborts the target instead of being reported as a
# pass by the last command in the loop.
array:
	@mkdir -p $(BUILD)
	@set -e; \
	for n in $(ARRAY_N); do \
	  $(VERILATOR) $(VFLAGS) --Mdir $(BUILD)/sa_n$$n -o sa_n$$n \
	      --top-module systolic_array_tb -GN=$$n \
	      $(CURDIR)/tb_waivers.vlt $(RTL_SRCS) $(TB)/systolic_array_tb.sv \
	      > $(BUILD)/sa_n$$n.log 2>&1 \
	    || { echo "=== systolic_array_tb N=$$n: BUILD FAILED ==="; \
	         cat $(BUILD)/sa_n$$n.log; exit 1; }; \
	done; \
	for run in $(ARRAY_RUNS); do \
	  c=$${run%%:*}; n=$${run##*:}; \
	  ( cd $(BUILD) && ./sa_n$$n/sa_n$$n +CASE=$(ROOT)/vectors/$$c ); \
	done

# Requantization output stage vs the golden model's requantize().
requant:
	@mkdir -p $(BUILD)
	@$(VERILATOR) $(VFLAGS) --Mdir $(BUILD)/requant_unit_tb -o requant_unit_tb \
	    --top-module requant_unit_tb \
	    $(CURDIR)/tb_waivers.vlt $(RTL_SRCS) $(TB)/requant_unit_tb.sv \
	    > $(BUILD)/requant_unit_tb.log 2>&1 \
	  || { echo "=== requant_unit_tb: BUILD FAILED ==="; \
	       cat $(BUILD)/requant_unit_tb.log; exit 1; }
	@cd $(BUILD) && ./requant_unit_tb/requant_unit_tb \
	    +CASES=$(ROOT)/vectors/requant/cases.txt

# End-to-end tests over the golden-model vectors. STALL=<pct> injects random
# stream gaps and backpressure; 0 (the default) runs them at full rate.
TOP_N    := 4 8
TOP_RUNS := smoke_4x4:4 tall_4x4:4 multi_tile_4x4:4 tight_4x4:4 \
            smoke_8x8:8 large_8x8:8 tight_8x8:8
STALL    ?= 0
QUANT    ?= 0

top:
	@mkdir -p $(BUILD)
	@set -e; \
	for n in $(TOP_N); do \
	  $(VERILATOR) $(VFLAGS) --Mdir $(BUILD)/gt_n$$n -o gt_n$$n \
	      --top-module gemm_top_tb -GN=$$n \
	      $(CURDIR)/tb_waivers.vlt $(RTL_SRCS) $(TB)/gemm_top_tb.sv \
	      > $(BUILD)/gt_n$$n.log 2>&1 \
	    || { echo "=== gemm_top_tb N=$$n: BUILD FAILED ==="; \
	         cat $(BUILD)/gt_n$$n.log; exit 1; }; \
	done; \
	for run in $(TOP_RUNS); do \
	  c=$${run%%:*}; n=$${run##*:}; \
	  ( cd $(BUILD) && ./gt_n$$n/gt_n$$n +CASE=$(ROOT)/vectors/$$c +STALL=$(STALL) +QUANT=$(QUANT) ); \
	done

# One rule per test: rebuild then run. These designs compile in seconds, so
# there is no incremental-build bookkeeping to get wrong.
#
# Compile output goes to a log and is only surfaced on failure; the test's own
# stdout is always shown.
$(TESTS): %: $(RTL_SRCS) $(TB)/%.sv
	@mkdir -p $(BUILD)
	@$(VERILATOR) $(VFLAGS) --Mdir $(BUILD)/$@ -o $@ --top-module $@ \
	    $(CURDIR)/tb_waivers.vlt $(RTL_SRCS) $(TB)/$@.sv > $(BUILD)/$@.log 2>&1 \
	  || { echo "=== $@: BUILD FAILED ==="; cat $(BUILD)/$@.log; exit 1; }
	@cd $(BUILD) && ./$@/$@ $(RUNFLAGS)

# MULTITOP is expected: this lints the RTL as a library, so every module that
# nothing else instantiates yet is a legal top.
lint:
	@$(VERILATOR) --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
	    -Wno-MULTITOP $(RTL_SRCS)

clean:
	@rm -rf $(BUILD)
