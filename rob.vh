`ifndef __rob_hdr__
`define __rob_hdr__

`include "machine.vh"


typedef struct packed {
   logic       faulted;
   logic       is_ii;
   logic       is_wmiss;   /* a WMISS (core.sv): a window miss, not a trap */
   logic       is_fpe;   /* FP exception (FPE, cause 15): denorm/enabled IEEE flag */
   logic       fp_set_flags; /* completed on FP port 2 (arith/cmp/cvt): update FCSR Cause/Flags at retire */
   logic       overflow;
   logic       trap;
   logic       is_bad_addr;
   mmu_fault_t mmu;
   logic       is_bus_err;   /* the memory response came back bad: DBE (cause 7) */
   logic       is_ret;
   logic       is_call;
   logic       is_irq;
   logic       is_store;
   logic       valid_dst;
   logic       valid_hilo_dst;
   logic       valid_fp_dst;   /* dst is an FP physical reg (free into the FP free list at retire) */
   logic       valid_fcr_dst;  /* dst is an FCR (FP cond-code) physical reg; pdst/old_pdst hold the FCR ptr */
   logic       has_delay_slot;
   logic       has_nullifying_delay_slot;
   logic       in_delay_slot;
   logic       dcti;   /* a CTI in another CTI's delay slot: retires as a mispredict (core.sv) */
   logic       valid_flags_dst;   /* SPARC: writes icc (icc_pdst, the icc rename) */
   logic       valid_dst2;        /* SPARC ldd: pdst2 is rd+1 (arch ldst+1) */
   logic [(`LG_PRF_ENTRIES-1):0] ldst;   /* int: the flat windowed arch index */

   /* Renamed srcA pointer + its architectural name, captured at ALLOC.  With pdst
    * below this makes the retire trace self-checking for renaming: a consumer whose
    * srcA_ptr does not match the producer's pdst was pointed at the wrong physical
    * register (RAT bug), as opposed to reading the right register and getting stale
    * data (delivery/bypass bug).  The captured jr faults cannot distinguish those
    * two without this. */
   logic [(`LG_PRF_ENTRIES-1):0] srcA_ptr;
   logic [(`LG_PRF_ENTRIES-1):0] srcA_arch;
   logic [(`LG_PRF_ENTRIES-1):0] pdst;
   logic [(`LG_PRF_ENTRIES-1):0] old_pdst;
   logic [(`LG_ICC_PRF_ENTRIES-1):0] icc_pdst;       /* the icc version written */
   logic [(`LG_ICC_PRF_ENTRIES-1):0] old_icc_pdst;   /* the icc RAT's previous version */
   logic [(`LG_PRF_ENTRIES-1):0] pdst2;
   logic [(`LG_PRF_ENTRIES-1):0] old_pdst2;
   /* SPARC Y (the HILO rename), its own fields: a multiply writes rd AND Y */
   logic [(`LG_HILO_PRF_ENTRIES-1):0] hilo_pdst;
   logic [(`LG_HILO_PRF_ENTRIES-1):0] old_hilo_pdst;
   logic [(`M_WIDTH-1):0] 	 pc;
   logic [(`M_WIDTH-1):0] 	 target_pc;
   logic 			 is_br;
   logic 			 is_indirect;
   logic 			 take_br;
   logic			 is_cache;   /* MIPS CACHE op (serializing flush) */
   cache_act_t		 cache_act;  /* what the CACHE op does at retire (machine.vh) */
   logic [(`MEM_WIDTH-1):0]	 data;
   logic [8:0]			 opcode;
   logic [`LG_BPU_TBL_SZ-1:0] 	 bpu_idx;
   /* PREDICTED direction, kept alongside the RESOLVED take_br so a capture can
    * separate "predictor said taken" from "branch resolved taken".  The
    * 2026-08-29 captures showed a bnez that took wrongly with faulted=0, i.e.
    * NO mispredict was signalled -- prediction and resolution agreed, and both
    * were wrong.  Without this bit we cannot tell which one drove that. */
   logic 			 br_pred;
   logic                         oldest_first;

   /* Low 8 bits of the free-running cycle counter, stamped when the uop COMPLETES
    * (for a load: when its memory response lands).  Deliberately OUTSIDE the
    * ENABLE_CYCLE_ACCOUNTING guard -- the 64-bit fetch/alloc/complete cycles below
    * are Verilator-only, so silicon had no way to order a producer against its
    * consumer.  Comparing this stamp on a load against the stamp on the branch that
    * consumes it is what distinguishes "consumer issued before the data returned"
    * from "consumer read the right value". */
   logic [7:0] exec_cycle;
   logic [1:0] fwd_sel;   /* operand-mux select at execute; see complete_t */
   logic [1:0] fwd_selB;  /* srcB operand-mux select at execute */
   logic [31:0] srcB_val; /* srcB operand value at execute (branches: the $zero-side compare input) */
   logic hi_nzA;  /* |t_srcA[63:32] at execute -- the compare is 64b, the ring data field 32b */
   logic hi_nzB;  /* |t_srcB[63:32] */
   logic [`LG_ROB_ENTRIES-1:0] wr_echo; /* rob_ptr of the completion that wrote this slot's fields --
                                         * a misdirected field-write stamps a ptr != the slot index */
   logic       post_restart;  /* 1 = first uop allocated after a machine-clear/restart (RAT->ACTIVE) */
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] 	    fetch_cycle;
   logic [63:0] 	    alloc_cycle;
   logic [63:0] 	    complete_cycle;
`endif
   
} rob_entry_t;

/* The ROB is stored as two structures indexed by the same rob_ptr (rv64core's
 * split): fields written only at ALLOC live in mrob_entry_t (one write port per
 * even/odd bank, no reset, so they can map to LUTRAM); fields written after
 * alloc live in crob_entry_t (multi-ported flops).  rob_entry_t stays the merged
 * view every reader uses (core.sv rob_to_mrob/rob_to_crob/rob_merge). */
typedef struct packed {
   logic is_ret;
   logic is_call;
   logic is_irq;
   logic is_store;
   logic valid_dst;
   logic valid_hilo_dst;
   logic valid_fp_dst;
   logic valid_fcr_dst;
   logic has_delay_slot;
   logic has_nullifying_delay_slot;
   logic in_delay_slot;
   logic dcti;
   logic valid_flags_dst;
   logic valid_dst2;
   logic [(`LG_PRF_ENTRIES-1):0] ldst;
   logic [(`LG_PRF_ENTRIES-1):0] srcA_ptr;
   logic [(`LG_PRF_ENTRIES-1):0] srcA_arch;
   logic [(`LG_PRF_ENTRIES-1):0] pdst;
   logic [(`LG_PRF_ENTRIES-1):0] old_pdst;
   logic [(`LG_ICC_PRF_ENTRIES-1):0] icc_pdst;
   logic [(`LG_ICC_PRF_ENTRIES-1):0] old_icc_pdst;
   logic [(`LG_PRF_ENTRIES-1):0] pdst2;
   logic [(`LG_PRF_ENTRIES-1):0] old_pdst2;
   logic [(`LG_HILO_PRF_ENTRIES-1):0] hilo_pdst;
   logic [(`LG_HILO_PRF_ENTRIES-1):0] old_hilo_pdst;
   logic [(`M_WIDTH-1):0] pc;
   logic is_br;
   logic is_indirect;
   logic is_cache;
   cache_act_t cache_act;
   logic [8:0] opcode;
   logic [`LG_BPU_TBL_SZ-1:0] bpu_idx;
   logic br_pred;
   logic oldest_first;
   logic post_restart;
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] fetch_cycle;
   logic [63:0] alloc_cycle;
`endif
} mrob_entry_t;

typedef struct packed {
   logic faulted;
   logic is_ii;
   logic is_wmiss;   /* a WMISS (core.sv): a window miss, not a trap */
   logic is_fpe;
   logic fp_set_flags;
   logic overflow;
   logic trap;
   logic is_bad_addr;
   mmu_fault_t mmu;
   logic is_bus_err;
   logic [(`M_WIDTH-1):0] target_pc;
   logic take_br;
   logic [(`ROB_DATA_WIDTH-1):0] data;   /* machine.vh: M_WIDTH outside sim */
   logic [7:0] exec_cycle;
   logic [1:0] fwd_sel;
   logic [1:0] fwd_selB;
   logic [31:0] srcB_val;
   logic hi_nzA;
   logic hi_nzB;
   logic [`LG_ROB_ENTRIES-1:0] wr_echo;
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] complete_cycle;
`endif
} crob_entry_t;

typedef struct packed {
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic 		       complete;
   logic 		       faulted;
   logic [`M_WIDTH-1:0]        restart_pc;
   logic 		       take_br;
   logic 		       is_ii;
   logic		       overflow;
   logic		       trap;
   logic [5:0]		       fp_flags;  /* {denorm(E), V,Z,O,U,I} of a completing FP op (port 2) */
   logic [(`MEM_WIDTH-1):0]    data;
   /* Which source the operand mux actually used for srcA at execute:
    *   bit1 = r_fwd_int_srcA (forwarded ALU result)
    *   bit0 = r_fwd_mem_srcA (forwarded load data)
    *   00   = read from the register file (w_srcA)
    * The 2026-09-02 captures prove two readers of one physreg disagreed but NOT
    * which source delivered the wrong value; every hypothesis (stale PRF read,
    * wrong forward flag, r_mem_result skewed by the next response) fits the
    * evidence equally.  These two bits discriminate. */
   logic [1:0] 		       fwd_sel;
   logic [1:0] 		       fwd_selB;
   logic [31:0] 	       srcB_val;
   logic 		       hi_nzA;
   logic 		       hi_nzB;
} complete_t;

typedef struct packed {
   logic [31:0] data;
   logic [(`M_WIDTH-1):0] pc;
   logic [(`M_WIDTH-1):0] pred_target;
   logic 		  pred;
   logic [`LG_BPU_TBL_SZ-1:0] bpu_idx;
   logic		    misaligned;
   logic		    bad_va;       /* i-side AdEL: mipsseg bad_perms (access-level / VA out-of-range) */
   logic		    tlb_miss;     /* instruction_access_exception (mmu has the FSR fields) */
   mmu_fault_t		    mmu;
   logic		    is_branch;
`ifdef ENABLE_CYCLE_ACCOUNTING
   logic [63:0] 	    fetch_cycle;
`endif
} insn_fetch_t;

/* LSU block codes: why a simple load could not complete on its port-2 pass.
 * It parks in its LSU entry until its wake condition, then re-issues.
 *   bit 2 clear: cache-owned -- the MQ entry fetches the line / waits out the
 *                store, then the l1d sends a wakeup with the lsu_idx.
 *   bit 2 set:   LSU-owned -- an older store still in the LSU overlaps the load
 *                (blk_st = which ones); the LSU wakes it itself. */
typedef enum logic [2:0] {
   BLK_NONE = 3'd0,
   BLK_MISS = 3'd1,         /* tag miss: the miss queue reloads the line */
   BLK_ST_CONFLICT = 3'd2,  /* same set + byte overlap with a store in the l1d MQ */
   BLK_SB_CONFLICT = 3'd4,  /* overlaps older LSU store(s), cannot forward: wait for them to drain */
   BLK_SB_DATA = 3'd5,      /* would forward, but the youngest overlapping store has no data yet */
   BLK_UNCACHEABLE = 3'd6,  /* uncached (segment or TLB C) and not yet non-speculative:
			     * re-issue once at the ROB head (or its committable delay slot) */
   BLK_TLB = 3'd7           /* dtlb miss: re-issue once the walk is done (tlb_busy drops) */
} blk_code_t;

/* exec LSU -> l1d store-buffer view.  The LSU owns the stores (allocation, age,
 * retirement, drain); the l1d holds each store's translated PA / mask / data at
 * its LSU slot, where a load's PA is known, and compares loads against it. */
typedef struct packed {
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] live;     /* slot holds a plain store */
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] epoch;    /* toggles at each slot allocation */
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] data_ok;  /* store data has landed in the l1d */
   /* matrix[j*N+k] = slot k is older than slot j (the LSU age matrix) */
   logic [(1<<(2*`LG_MEM_SCHED_ENTRIES))-1:0] matrix;
   logic 				   retired_pending; /* a retired store has not drained */
   logic 				   data_valid;      /* store data write */
   logic [`LG_MEM_SCHED_ENTRIES-1:0] 	   data_idx;
   logic [63:0] 			   data;
} lsu_sb_t;

typedef struct packed {
   logic [(`REQ_ADDR_WIDTH-1):0] addr;   /* the VA, then (l1d) the PA */
   logic 	is_store;
   logic	is_atomic;
   mem_op_t op;
   logic 	bad_addr;   
   logic	mapped;     /* SRMMU-translated ASI (0x8-0xb) */
   logic	cached;
   logic [7:0]	asi;
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic [`LG_PRF_ENTRIES-1:0] dst_ptr;
   logic 		       dst_valid;
   logic [`LG_PRF_ENTRIES-1:0] dst2_ptr;   /* SPARC ldd: rd+1 takes the low word */
   logic 		       dst2_valid;
   logic 		       fp_dst;   /* result writes the FP PRF (vs int) — for moves/FP loads */
   /* FR=0 lwc1 merge: write only the fp_hi-selected 32b half of the load result,
    * preserving the other half (fp_pres = the old 32b half read at issue). */
   logic 		       fp_merge;
   logic 		       fp_hi;
   logic [31:0]		       fp_pres;
   logic [(`MEM_WIDTH-1):0]    data;
   logic [(`M_WIDTH-1):0]      pc;   /* un-guarded for synth: store-tracer PC watchpoint (be birth catch) */
   /* simple load (LW/LWU/LB/LBU/LH/LHU/LD/LWC1/LDC1): its LSU entry stays until
    * the data returns, so the l1d may block it instead of replaying it */
   logic 		       lsu_hold;
   logic [`LG_MEM_SCHED_ENTRIES-1:0] lsu_idx;
   /* plain store drain: write the store held at lsu_idx (PA/data from the l1d
    * store buffer); the store has retired, so rob_ptr is stale -- never use it */
   logic 		       commit;
   /* restart color (rv64core restart_id, 1 bit): flips at every restart; a
    * request/response of the other color belongs to a flushed era and is dropped
    * (commits are never dead and are exempt) */
   logic 		       restart_id;
   /* SC/SCD commit: the reservation held at its address pass (write only if set) */
   /* load: plain stores older than it at issue, with their slot epochs */
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] lsu_older_st;
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] lsu_older_ep;
`ifdef VERILATOR
   logic [63:0] 	       uuid;
`endif
} mem_req_t;

typedef struct packed {
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic [`LG_PRF_ENTRIES-1:0] src_ptr;
   logic 		       fp;     /* store data comes from the FP PRF (swc1/sdc1) */
   logic 		       fp_hi;  /* FR=0 swc1: store the HIGH 32b half (odd reg) */
} dq_t;

typedef struct packed {
   logic [(`MEM_WIDTH-1):0] data;
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
} mem_data_t;

typedef struct packed {
   logic [(`MEM_WIDTH-1):0] data;
   logic [`LG_ROB_ENTRIES-1:0] rob_ptr;
   logic [`LG_PRF_ENTRIES-1:0] dst_ptr;
   logic 		       dst_valid;
   logic [`LG_PRF_ENTRIES-1:0] dst2_ptr;   /* SPARC ldd: rd+1 (rd gets data[63:32], rd+1 data[31:0]) */
   logic 		       dst2_valid;
   logic 		       fp_dst;   /* result writes the FP PRF (vs int) */
   logic 		       fp_merge; /* FR=0 lwc1: merge into the fp_hi half, preserve fp_pres */
   logic 		       fp_hi;
   logic [31:0]		       fp_pres;
   logic 		       bad_addr;
   logic 		       bus_err;    /* the bus answered with an error (MC): DBE */
   mmu_fault_t		       mmu;        /* SRMMU fault (data = the VA) */
   logic 		       lsu_hold;   /* echo of mem_req_t.lsu_hold */
   logic [`LG_MEM_SCHED_ENTRIES-1:0] lsu_idx;
   blk_code_t		       blk;        /* valid with core_mem_blk_valid */
   logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] blk_st;  /* BLK_SB_*: the overlapping store slots */
   logic 		       restart_id; /* echo of the request's color */
} mem_rsp_t;


/* SRMMU table-walk result (mmu.sv -> the L1 TLBs).  level: 0 = a context-table
 * PTE (4 GB), 1 = 16 MB, 2 = 256 KB, 3 = 4 KB.  On a fault, ft is the fault type
 * (FT_* below) and level is where the walk stopped. */
typedef struct packed {
   logic	fault;
   logic [2:0]	ft;
   logic [1:0]	level;
   logic [23:0] ppn;    /* PTE[31:8] = PA[35:12] */
   logic	c;      /* cacheable */
   logic	m;      /* modified */
   logic [2:0]	acc;
} page_walk_rsp_t;

/* SRMMU fault types (fault status register FT) */
localparam logic [2:0] FT_NONE        = 3'd0;
localparam logic [2:0] FT_INVALID     = 3'd1;
localparam logic [2:0] FT_PROTECTION  = 3'd2;
localparam logic [2:0] FT_PRIVILEGE   = 3'd3;
localparam logic [2:0] FT_TRANSLATION = 3'd4;
localparam logic [2:0] FT_BUS_ERROR   = 3'd5;   /* access bus error (a data_access_error) */

`endif
