UNAME_S = $(shell uname -s)

# the sun4m devices (copied from ss10sim: keep in sync)
DEV_OBJ = sun4m.o esp.o scsi.o lance.o tcx.o cg14.o

OBJ = top.o verilated.o verilated_vcd_c.o loadelf.o interpret.o $(DEV_OBJ) disassemble.o helper.o sparse_mem.o ckpt.o

SV_SRC = core_l1d_l1i.sv core.sv free_fifo.sv mmu.sv tlb.sv exec.sv decode_sparc.sv mul.sv fpu.sv fpu_add.sv fpu_mul.sv fpu_compare.sv fpu_f2i.sv fpu_i2f.sv fpu_f2f.sv fp_regfile.sv find_first_set.sv uni_divider.sv l1d.sv l1i.sv machine.vh rob.vh uop.vh fp_compare.vh ram1r1w.sv ram2r1w.sv popcount.sv count_leading_zeros.sv fair_sched.sv ppa32.sv rf4r2w.sv reg_ram1rw.sv l2.sv predecode.sv

ifeq ($(UNAME_S),Linux)
	CXX = clang++-16 -flto
	MAKE = make
	VERILATOR_SRC = /home/dsheffie/local/share/verilator/include/verilated.cpp
	VERILATOR_VCD = /home/dsheffie/local/share/verilator/include/verilated_vcd_c.cpp
	VERILATOR_INC = /home/dsheffie/local/share/verilator/include
	VERILATOR_DPI_INC = /home/dsheffie/local/share/verilator/include/vltstd/
	VERILATOR = /home/dsheffie/local/bin/verilator
	EXTRA_LD = -lcapstone -lboost_program_options  -lboost_serialization
endif

ifeq ($(UNAME_S),FreeBSD)
	CXX = CC -march=native
	VERILATOR_SRC = /opt/local/share/verilator/include/verilated.cpp
	VERILATOR_INC = /opt/local/share/verilator/include
	VERILATOR_VCD = /opt/local/share/verilator/include/verilated_vcd_c.cpp
        EXTRA_LD = -L/usr/local/lib -lcapstone -lboost_program_options  -lboost_serialization
	MAKE = gmake
endif

ifeq ($(UNAME_S),Darwin)
	CXX = clang++ -I/opt/local/include -flto
	VERILATOR_SRC = /Users/dsheffie/local/share/verilator/include/verilated.cpp
	VERILATOR_INC = /Users/dsheffie/local/share/verilator/include
	VERILATOR_VCD = /Users/dsheffie/local/share/verilator/include/verilated_vcd_c.cpp
	VERILATOR_DPI_INC = /Users/dsheffie/local/share/verilator/include/vltstd/
	VERILATOR = /Users/dsheffie/local/bin/verilator
	EXTRA_LD = -L/opt/local/lib -lboost_program_options-mt -lboost_serialization-mt -lcapstone
endif


OPT = -O3 -g -std=c++14 #-fomit-frame-pointer
CXXFLAGS = -std=c++11 -g  $(OPT) -I$(VERILATOR_INC) -I$(VERILATOR_DPI_INC) #-DLINUX_SYSCALL_EMULATION=1
LIBS =  $(EXTRA_LD) -lpthread

# keep the C++ ISS/checker in step with machine.vh's CPU-model and MIPS IV knobs
# (ENABLE_R10000 implies ENABLE_MIPS4; interpret.hh derives N_TLB_ENTRIES from it)
ifneq ($(shell grep -c '^`define ENABLE_R10000' machine.vh),0)
CXXFLAGS += -DENABLE_R10000 -DENABLE_MIPS4
else ifneq ($(shell grep -c '^`define ENABLE_MIPS4' machine.vh),0)
CXXFLAGS += -DENABLE_MIPS4
endif
# those flags come from a grep, not an #include, and they change state_t's layout: every
# C++ object that uses state_t must rebuild when machine.vh does
$(filter-out verilated.o verilated_vcd_c.o,$(OBJ)): machine.vh

# STORE_CHECK=1: the co-sim store check (l1d.sv wr_log vs the ISS's store stream, top.cc)
ifeq ($(STORE_CHECK),1)
CXXFLAGS += -DSTORE_CHECK
VFLAGS_EXTRA += +define+ENABLE_STORE_CHECK
endif

DEP = $(OBJ:.o=.d)

EXE = ooo_core

.PHONY : all clean

all: $(EXE)

$(EXE) : $(OBJ) obj_dir/Vcore_l1d_l1i__ALL.a
	$(CXX) $(CXXFLAGS) $(OBJ) obj_dir/*.o $(LIBS) -o $(EXE)

top.o: top.cc obj_dir/Vcore_l1d_l1i__ALL.a
	$(CXX) -MMD $(CXXFLAGS) -Iobj_dir -c $< 

verilated.o: $(VERILATOR_SRC)
	$(CXX) -MMD $(CXXFLAGS) -c $< 

verilated_vcd_c.o: $(VERILATOR_VCD)
	$(CXX) -MMD $(CXXFLAGS) -c $< 

%.o: %.cc
	$(CXX) -MMD $(CXXFLAGS) -c $< 

obj_dir/Vcore_l1d_l1i__ALL.a : $(SV_SRC)
	$(VERILATOR) -cc core_l1d_l1i.sv +define+PIPETRACE +define+ENABLE_TLB_MIRROR $(VFLAGS_EXTRA)
	$(MAKE) OPT_FAST="-O3 -flto" -C obj_dir -f Vcore_l1d_l1i.mk

gen_html : gen_html.cc pipeline_record.hh
	$(CXX) -MMD $(CXXFLAGS) gen_html.cc $(LIBS) -o gen_html

-include $(DEP)



clean:
	rm -rf $(EXE) $(OBJ) $(DEP) obj_dir obj_dec decode_test tb_decode_sparc.o tb_decode_sparc.d

# standalone SPARC V8 ISS (no verilator)
ISS_OBJ = iss_main.o interpret.o $(DEV_OBJ) disassemble.o loadelf.o helper.o sparse_mem.o
sparc_iss : $(ISS_OBJ)
	$(CXX) -o $@ $(ISS_OBJ) $(LIBS)
-include $(ISS_OBJ:.o=.d)

# decode_sparc.sv unit test against the ISS (sparc_tests/tb_decode_sparc.cc)
DEC_OBJ = tb_decode_sparc.o verilated.o interpret.o $(DEV_OBJ) disassemble.o helper.o sparse_mem.o
obj_dec/Vtb_decode_sparc__ALL.a : sparc_tests/tb_decode_sparc.sv decode_sparc.sv machine.vh uop.vh rob.vh
	$(VERILATOR) -cc sparc_tests/tb_decode_sparc.sv decode_sparc.sv -I. --top-module tb_decode_sparc --Mdir obj_dec
	$(MAKE) OPT_FAST="-O2" -C obj_dec -f Vtb_decode_sparc.mk
tb_decode_sparc.o : sparc_tests/tb_decode_sparc.cc obj_dec/Vtb_decode_sparc__ALL.a
	$(CXX) -MMD $(CXXFLAGS) -I. -Iobj_dec -c $< -o $@
decode_test : $(DEC_OBJ) obj_dec/Vtb_decode_sparc__ALL.a
	$(CXX) $(CXXFLAGS) $(DEC_OBJ) obj_dec/*.o $(LIBS) -o $@
-include tb_decode_sparc.d
