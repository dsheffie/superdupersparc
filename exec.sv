`include "uop.vh"
`include "rob.vh"

`ifdef VERILATOR
import "DPI-C" function void report_exec(input int int_valid, 
					 input int int_blocked,
					 input int mem_valid, 
					 input int mem_blocked,
					 input int fp_valid, 
					 input int fp_blocked,
					 input int iq_full,
					 input int mq_full,
					 input int fq_full,
					 input int blocked_by_store,
					 input int int_ready
					 );
`endif

module exec(clk, 
	    ldd_lo_done,
	    ldd_lo_rob,
	    sparc_psr,
	    sparc_wim,
	    sparc_tbr,
	    reset,
	    core_fcsr_we,
	    core_fcsr_cause6,
	    core_fcsr_flags5,
	    core_fsr_trap,
	    core_fsr_ftt,
	    core_fsr_cexc5,
`ifdef VERILATOR
	    clear_cnt,
`endif
	    divide_ready,
	    ds_done,
	    restart_complete,
	    head_of_rob_ptr_valid,
	    head_of_rob_ptr,
	    dbg_exec_snap,
	    next_head_of_rob_ptr,
	    head_of_rob_ds_committable,
	    uq_wait,
	    mq_wait,
	    fp_uq_wait,
	    dbg_memop_idx,
	    dbg_memop_pc,
	    uq_full,
	    uq_next_full,
	    uq_uop,
	    uq_uop_two,
	    uq_push,
	    uq_push_two,
	    complete_bundle_1,
	    complete_valid_1,
	    complete_bundle_2,
	    complete_valid_2,
	    mem_req,
	    mem_req_valid, 
	    mem_req_ack,
	    //tell rob store data has been read
	    core_store_data_ptr,
	    core_store_data_ptr_valid,
	    mem_rsp_dst_ptr_in,
	    mem_rsp_dst2_ptr,
	    mem_rsp_dst2_valid,
	    mem_rsp_dst_valid_in,
	    mem_rsp_fp_dst_in,
	    mem_rsp_fp_merge,
	    mem_rsp_fp_hi,
	    mem_rsp_fp_pres,
	    mem_rsp_rob_ptr,
	    mem_rsp_faulted,
	    mem_rsp_load_data,
	    mem_rsp_valid,
	    mem_rsp_lsu_hold,
	    mem_rsp_lsu_idx,
	    mem_blk_valid,
	    mem_blk_code,
	    mem_blk_st,
	    mem_wake_valid,
	    mem_tlb_busy,
	    lsu_st_pending,
	    mem_st_done_valid,
	    mem_st_done_idx,
	    lsu_sb,
	    restart_color,
	    mem_color_pending,
	    retired_rob_ptr_valid,
	    retired_rob_ptr_two_valid,
	    retired_rob_ptr,
	    retired_rob_ptr_two
	    );
   input logic clk;
   input logic reset;
   /* SPARC committed state for rdpsr/rdwim/rdtbr (core.sv): the PSR with its icc
    * and CWP fields zero -- icc comes from the flags register, CWP from the uop */
   input logic [31:0] sparc_psr;
   input logic [31:0] sparc_wim;
   input logic [31:0] sparc_tbr;
   /* SPARC ldd: its parked rd+1 was written; completes the ldd's ROB entry */
   output logic ldd_lo_done;
   output logic [`LG_ROB_ENTRIES-1:0] ldd_lo_rob;
       
   /* FSR update from retire: a retiring FPop sets cexc (its exceptions), ORs
    * them into aexc and clears ftt */
   input logic		      core_fcsr_we;
   input logic [5:0]	      core_fcsr_cause6;  /* {E,V,Z,O,U,I} this op raised */
   input logic [4:0]	      core_fcsr_flags5;  /* {V,Z,O,U,I} to OR into aexc */
   /* ... and from an fp_exception: ftt (1 IEEE_754_exception, 2 unfinished_FPop,
    * 3 unimplemented_FPop); an IEEE trap also sets cexc, aexc is untouched */
   input logic		      core_fsr_trap;
   input logic [2:0]	      core_fsr_ftt;
   input logic [4:0]	      core_fsr_cexc5;    /* {V,Z,O,U,I} */

   




   
   
`ifdef VERILATOR
   input logic [31:0] clear_cnt;
`endif
   output logic       divide_ready;
   input logic ds_done;
   input logic restart_complete;
   input logic head_of_rob_ptr_valid;
   input logic [`LG_ROB_ENTRIES-1:0] head_of_rob_ptr;
   output logic [319:0] dbg_exec_snap;   /* STALL_SNAP: head/scheduler/LSU/PRF state for the AXI debug port */
   input logic [`LG_ROB_ENTRIES-1:0] next_head_of_rob_ptr;
   input logic			     head_of_rob_ds_committable;
      
   localparam N_ROB_ENTRIES = (1<<`LG_ROB_ENTRIES);   
   output logic [N_ROB_ENTRIES-1:0]  uq_wait;
   output logic [N_ROB_ENTRIES-1:0]  mq_wait;
   output logic [N_ROB_ENTRIES-1:0]  fp_uq_wait;
   /* DEBUG: ROB-indexed PC of the last memory op scheduled into each ROB slot.
    * Written at the one-mem-op-per-cycle schedule point (t_pop_mem_uq); survives
    * squash (only overwritten when the slot is reused).  Snarfed by rob index to
    * identify a memory op that stranded its L1D r_rob_inflight bit but never
    * retired (the applu FP-wedge orphan). */
   input logic [`LG_ROB_ENTRIES-1:0] dbg_memop_idx;
   output logic [31:0] 		     dbg_memop_pc;
   
   output logic 			     uq_full;
   output logic 			     uq_next_full;
   
   input 				     uop_t uq_uop;
   input 				     uop_t uq_uop_two;
   
   input logic 				     uq_push;
   input logic 				     uq_push_two;
   
   output 	complete_t complete_bundle_1;
   output logic complete_valid_1;
   output 	complete_t complete_bundle_2;
   output logic complete_valid_2;


   output 	mem_req_t mem_req;
   output 	logic mem_req_valid;
   input logic 	      mem_req_ack;

   
   output logic [`LG_ROB_ENTRIES-1:0] core_store_data_ptr;
   output logic 		      core_store_data_ptr_valid;
   
   
   input logic [`LG_PRF_ENTRIES-1:0] mem_rsp_dst_ptr_in;
   input logic [`LG_PRF_ENTRIES-1:0] mem_rsp_dst2_ptr;   /* SPARC ldd: rd+1 */
   input logic 			     mem_rsp_dst2_valid;
   input logic 			     mem_rsp_dst_valid_in;
   input logic 			     mem_rsp_fp_dst_in;
   input logic 			     mem_rsp_fp_merge;   /* FR=0 lwc1 merge */
   input logic 			     mem_rsp_fp_hi;
   input logic [31:0]		     mem_rsp_fp_pres;
   input logic [`MEM_WIDTH-1:0]	     mem_rsp_load_data;
   input logic [`LG_ROB_ENTRIES-1:0] mem_rsp_rob_ptr;
   input logic 			     mem_rsp_faulted;   /* the access trapped (ldfsr writes nothing) */
   /* LSU: a completing simple load frees its entry (mem_rsp_valid & lsu_hold);
    * a block parks it with a code; a wakeup makes it issuable again */
   input logic 			     mem_rsp_valid;
   input logic 			     mem_rsp_lsu_hold;
   input logic [`LG_MEM_SCHED_ENTRIES-1:0] mem_rsp_lsu_idx;
   input logic 			     mem_blk_valid;
   input 			     blk_code_t mem_blk_code;
   input logic [(1<<`LG_MEM_SCHED_ENTRIES)-1:0] mem_blk_st;
   input logic 			     mem_wake_valid;
   input logic 			     mem_tlb_busy;   /* a dtlb walk is pending (BLK_TLB release) */
   /* the LSU holds a store (unretired, or retired and not yet written by the
    * l1d): a SPARC flush waits for none before it invalidates the L1I line */
   output logic 			     lsu_st_pending;
   input logic 			     mem_st_done_valid;
   input logic [`LG_MEM_SCHED_ENTRIES-1:0] mem_st_done_idx;
   output 			     lsu_sb_t lsu_sb;
   /* restart color: flips at every restart; stamped into each memory request */
   output logic 		     restart_color;
   /* a request of color c is between issue and the l1d (AGU stage / request FIFO) */
   output logic [1:0] 		     mem_color_pending;
   /* retirement: a plain store in the LSU becomes committable */
   input logic 			     retired_rob_ptr_valid;
   input logic 			     retired_rob_ptr_two_valid;
   input logic [`LG_ROB_ENTRIES-1:0] retired_rob_ptr;
   input logic [`LG_ROB_ENTRIES-1:0] retired_rob_ptr_two;

   /* int-domain mem writeback: an FP mem result (mem_rsp_fp_dst) writes the FP
    * PRF, not the int PRF.  int/FP physical reg numbers OVERLAP, so int-domain
    * wakeup/bypass must gate on this -- else an FP load whose FP pdst happens to
    * equal an int op's source pdst would falsely forward FP data into the int op. */
   /* PRODUCER-SIDE $zero GUARD (mem).  rf4r2w refuses to WRITE physreg 0
    * (wrptr0 != 'd0, the r0/SSNOP fix) but nothing refused to BYPASS onto it: a
    * producer with dst==0 was blocked from the register file yet would still
    * forward its result to every consumer reading $zero.  That asymmetry is the
    * hazard; the decode-side work only removed some of the readers.  Qualifying
    * the single valid signal here covers every mem forward and wakeup compare at
    * once.  Per the decode audit this is currently redundant (all 13 integer
    * loads plus SC/SCD/MFC1/DMFC1 set dst_valid=(rt!='d0)), which is the point --
    * it makes the invariant STRUCTURAL instead of resting on ~68 per-arm guards,
    * two of which were already found missing this month. */
   /* SPARC ldd: one 64-bit response on the single writeback path.  rd takes the
    * word at the address (the high half, big-endian) at once; rd+1 (the low half)
    * is parked and written through the same PRF port on the next cycle with no
    * load response.  The parked write is presented as a load response
    * (mem_rsp_dst_* below), so the wakeups and forwards treat it like one.  The
    * LSU has at most one ldd past issue at a time, so one parked entry suffices,
    * and the ldd completes in the ROB only once rd+1 is written (ldd_lo_done):
    * before that its rd+1 register could be freed and reused under the late
    * write. */
   logic r_park_valid;
   logic [`LG_PRF_ENTRIES-1:0] r_park_ptr;
   logic [31:0] r_park_data;
   logic [`LG_ROB_ENTRIES-1:0] r_park_rob;
   wire w_park_in = mem_rsp_valid & mem_rsp_dst_valid_in & mem_rsp_dst2_valid & ~mem_rsp_fp_dst_in;
   wire w_park_go = r_park_valid & !mem_rsp_dst_valid_in;
   always_ff@(posedge clk)
     begin
	if(reset | t_flash_clear)
	  begin
	     r_park_valid <= 1'b0;
	  end
	else if(w_park_in)
	  begin
	     r_park_valid <= 1'b1;
	  end
	else if(w_park_go)
	  begin
	     r_park_valid <= 1'b0;
	  end
	if(w_park_in)
	  begin
	     r_park_ptr <= mem_rsp_dst2_ptr;
	     r_park_data <= mem_rsp_load_data[31:0];
	     r_park_rob <= mem_rsp_rob_ptr;
	  end
     end // always_ff@ (posedge clk)
   assign ldd_lo_done = w_park_go;
   assign ldd_lo_rob = r_park_rob;

   /* the effective load response: the real one, or the parked rd+1 */
   wire [`LG_PRF_ENTRIES-1:0] mem_rsp_dst_ptr = w_park_go ? r_park_ptr : mem_rsp_dst_ptr_in;
   wire mem_rsp_dst_valid = mem_rsp_dst_valid_in | w_park_go;
   wire mem_rsp_fp_dst = mem_rsp_fp_dst_in & !w_park_go;
   wire w_mem_rsp_int_valid = mem_rsp_dst_valid & ~mem_rsp_fp_dst &
			      (mem_rsp_dst_ptr != 'd0);
   wire [`M_WIDTH-1:0] w_mem_rsp_int_data = w_park_go ? r_park_data :
					    mem_rsp_dst2_valid ? mem_rsp_load_data[63:32] :
					    mem_rsp_load_data[`M_WIDTH-1:0];
   


   
   
   localparam N_INT_SCHED_ENTRIES = 1<<`LG_INT_SCHED_ENTRIES;
   localparam logic [N_INT_SCHED_ENTRIES-1:0] INT_SCHED_USABLE = {N_INT_SCHED_ENTRIES{1'b1}} >> (N_INT_SCHED_ENTRIES - `INT_SCHED_ENTRIES);
   
   localparam N_MQ_ENTRIES = (1<<`LG_MQ_ENTRIES);
   localparam N_INT_PRF_ENTRIES = (1<<`LG_PRF_ENTRIES);
   localparam N_HILO_PRF_ENTRIES = (1<<`LG_HILO_PRF_ENTRIES);
   
   localparam N_UQ_ENTRIES = (1<<`LG_UQ_ENTRIES);
   localparam N_MEM_UQ_ENTRIES = (1<<`LG_MEM_UQ_ENTRIES);
   localparam N_MEM_DQ_ENTRIES = (1<<`LG_MEM_DQ_ENTRIES);
   
   logic [31:0] r_hilo_prf[N_HILO_PRF_ENTRIES-1:0];   /* SPARC Y */
      
   logic [N_INT_PRF_ENTRIES-1:0]  r_prf_inflight, n_prf_inflight;
   logic [N_HILO_PRF_ENTRIES-1:0] r_hilo_inflight, n_hilo_inflight;

   /* FP register file: clustered/banked rf4r2w-style (fp_regfile, instanced below).
    * All four read ports are SYNCHRONOUS (registered inside the module): rd0/rd1 =
    * fpu operand reads (consumed one cycle later in the FP read stage); rd2 = mfc1
    * source (srcB); rd3 = FP store data (dq).  No flat r_fp_prf flop array anymore. */
   logic [`FP_WIDTH-1:0] 	  w_fp_rawA, w_fp_rawB;     // fpu reads  (rd0/rd1): whole pairs
   logic [`FP_WIDTH-1:0] 	  w_fp_srcA, w_fp_srcB;     // the operands: a single's half, low-justified
   logic [`FP_WIDTH-1:0] 	  w_fp_srcC;                // the old pair of a single dst (rd4)
   logic [`FP_WIDTH-1:0] 	  r_fp_rd_srcB, r_fp_rd_dq; // mem reads (rd2/rd3)
   logic [N_INT_PRF_ENTRIES-1:0]  r_fp_prf_inflight, n_fp_prf_inflight;

   logic 			  t_wr_int_prf;
   logic 			  t_wr_fcsr;
   /* the SPARC FSR, all but fcc (bits 11:10, renamed in r_fcr_prf[1:0]): RD 31:30,
    * TEM 27:23, NS 22, ver 19:17, ftt 16:14, qne 13, aexc 9:5, cexc 4:0.  The FPU's
    * flags are {V,Z,O,U,I}; the FSR's {NV,OF,UF,DZ,NX} (sparc_exc). */
   logic [31:0]			  r_fcsr, n_fcsr;
   logic 			  t_ldfsr_wr;
   localparam [31:0] FSR_LD_MASK = 32'hcfc003ff;   /* ldfsr: RD TEM NS aexc cexc */
   function automatic logic [4:0] sparc_exc(input logic [4:0] f);
      begin
	 sparc_exc = {f[4], f[2], f[1], f[3], f[0]};
      end
   endfunction
   wire [1:0] w_fsr_rd = r_fcsr[31:30];
   /* TEM in the FPU's flag order */
   wire [4:0] w_fsr_tem = {r_fcsr[27], r_fcsr[24], r_fcsr[26], r_fcsr[25], r_fcsr[23]};
   wire [31:0] w_fsr = r_fcsr | {20'd0, r_fcr_prf[r_sd_fcr][1:0], 10'd0};
   
   logic 	t_wr_hilo;
   logic	t_overflow;
   logic	t_trap;
   
   logic 	t_take_br;
   logic 	t_mispred_br;
   logic 	t_alu_valid;
      
   
   mem_req_t r_mem_q[N_MQ_ENTRIES-1:0];
   logic [`LG_MQ_ENTRIES:0] r_mq_head_ptr, n_mq_head_ptr;
   logic [`LG_MQ_ENTRIES:0] r_mq_tail_ptr, n_mq_tail_ptr;
   logic [`LG_MQ_ENTRIES:0] r_mq_next_tail_ptr, n_mq_next_tail_ptr;
   mem_req_t t_mem_tail, t_mem_head;
   logic 		    mem_q_full,mem_q_next_full, mem_q_empty;


   
   

   
   

   logic 	t_pop_uq,t_pop_mem_uq;
   logic 	r_mem_ready;
   
   
   localparam E_BITS = `M_WIDTH-16;
   localparam HI_EBITS = `M_WIDTH-32;
   
   logic [`M_WIDTH-1:0] t_simm, t_mem_simm;
   logic [`M_WIDTH-1:0] t_result;

   
   logic [31:0] t_hilo_result;
   
   logic [`M_WIDTH-1:0] t_pc, t_pc4, t_pc8;
   logic [27:0] t_jaddr;
   logic 	t_srcs_rdy;

   
   wire [`M_WIDTH-1:0] w_srcA, w_srcB;
   wire [`M_WIDTH-1:0] w_mem_srcA, w_mem_srcB;
   wire [`M_WIDTH-1:0] w_mem_srcC;   /* ENABLE_MIPS4: indexed FP load/store index (rf port 4) */
   
   logic 	r_fwd_int_srcA, r_fwd_int_srcB;
   logic 	r_fwd_mem_srcA, r_fwd_mem_srcB;

   logic t_fwd_int_mem_srcA,t_fwd_mem_mem_srcA;
   logic r_fwd_int_mem_srcA,r_fwd_mem_mem_srcA;
   logic t_fwd_int_mem_srcC,t_fwd_mem_mem_srcC;
   logic r_fwd_int_mem_srcC,r_fwd_mem_mem_srcC;
   
   /* Dedicated forward-DATA registers, one per forward flag, captured in the
    * SAME if() that sets the flag.  ROOT-CAUSE FIX for the 2026-09-02/03 stale
    * forward (4 silicon ring captures, fwd_sel field): the flags are one-shot
    * but the old free-running result registers (since removed) were overwritten EVERY
    * cycle, so any consumer that executes later than pick+1 forwards a LATER
    * producer's value.  Capture 20260903_120637 shows it exactly: two load
    * responses one cycle apart, the bnez forwarded from MEM and received the
    * SECOND load's data (the ra value, non-zero) while its own producer had
    * written 0 -- so the never-taken __free_hook branch was taken and jr t9
    * jumped to 0.  REG_L1D_RSP moved the timing and the fault survived, which
    * proves the defect is this flag/data lifetime mismatch and not the L1D
    * response path.  With the data captured beside its flag the pair cannot
    * desynchronise, whatever the pick-to-execute delay. */
   logic [`M_WIDTH-1:0]     r_fwd_srcA_data, r_fwd_srcB_data;
   logic [`M_WIDTH-1:0]     r_fwd_mem_srcA_data;
   logic [`M_WIDTH-1:0]     r_fwd_mem_srcC_data;
   logic [31:0] r_fwd_hilo_data;
   logic [31:0] r_src_hilo;
   logic 	r_fwd_hilo_int, r_fwd_hilo_mul, r_fwd_hilo_div;
      
   logic [`M_WIDTH-1:0] t_srcA, t_srcB;
   logic [`M_WIDTH-1:0] t_mem_srcA;
   logic [`M_WIDTH-1:0] t_mem_srcC;
   
   
   logic [31:0] t_src_hilo;
   logic [`M_WIDTH-1:0] t_cpr0_srcA;
   
   
   logic 	t_unimp_op;
   logic 	t_fault;
   

   logic 	t_start_mul;
   logic 	t_mul_complete;
   logic [`LG_PRF_ENTRIES-1:0] w_mul_dst;
   logic 	w_mul_dst_val, w_mul_cc;
   logic 	t_iwb, t_iwb_flags;
   logic [`LG_PRF_ENTRIES-1:0] t_iwb_dst;
   logic [`M_WIDTH-1:0] t_iwb_data;
   logic [3:0] 	t_iwb_icc;
   logic [31:0] w_s_op2;	/* SPARC operand 2 (the datapath below) */
   logic [127:0] w_div_y;	/* uni_divider: {remainder, quotient} */
   logic [(`M_WIDTH*2)-1:0] t_mul_result;
   
   logic 	t_hilo_prf_ptr_val_out;
   logic [`LG_ROB_ENTRIES-1:0] t_rob_ptr_out;

   
   logic [`LG_HILO_PRF_ENTRIES-1:0] t_hilo_prf_ptr_out;
   
   logic [`MAX_LAT:0] r_wb_bitvec, n_wb_bitvec;

   /* divider */
   logic 	t_div_ready, t_signed_div, t_start_div;
   logic [`LG_ROB_ENTRIES-1:0] t_div_rob_ptr_out;
   logic [`LG_HILO_PRF_ENTRIES-1:0] t_div_hilo_prf_ptr_out;
   /* unified divider, FP side (uni_divider.sv).
    * t_fdiv_pop = an FP div/sqrt pops from fp_uq THIS cycle (it starts NEXT cycle) */
   logic 			    t_fdiv_pop, t_fdiv_start, t_fdiv_wb_used;
   logic 			    w_fdiv_ready, w_fdiv_complete, w_fdiv_denorm;
   logic [63:0] 		    w_fdiv_y;
   logic [4:0] 			    w_fdiv_fflags;
   logic [`LG_ROB_ENTRIES-1:0] 	    w_fdiv_rob_ptr;
   logic [`LG_PRF_ENTRIES-1:0] 	    w_fdiv_dst_ptr;
   logic 			    t_div_complete;

   logic [N_ROB_ENTRIES-1:0] 	    r_uq_wait, r_mq_wait, r_fp_uq_wait;
   /* DEBUG mem-op PC shadow, ROB-indexed (see dbg_memop_pc port). */
   logic [31:0] 		    r_memop_pc [N_ROB_ENTRIES-1:0];
   /* non mem uop queue */
   uop_t r_uq[N_UQ_ENTRIES];
   uop_t uq, int_uop;
   /* ENABLE_UQ_DUAL_POP: second uq entry written into a second free entry */
   uop_t uq2;
   logic t_pop_uq2;
   logic 			    r_start_int;
   
   
   
   logic 			    t_uq_read, t_uq_empty, t_uq_full, t_uq_next_full;
   logic [`LG_UQ_ENTRIES:0] 	    r_uq_head_ptr, n_uq_head_ptr;
   logic [`LG_UQ_ENTRIES:0] 	    r_uq_tail_ptr, n_uq_tail_ptr;
   logic [`LG_UQ_ENTRIES:0] 	    r_uq_next_head_ptr, n_uq_next_head_ptr;
   logic [`LG_UQ_ENTRIES:0] 	    r_uq_next_tail_ptr, n_uq_next_tail_ptr;

   /* mem uop queue */
   uop_t r_mem_uq[N_MEM_UQ_ENTRIES];
   uop_t t_mem_uq, mem_uq;
   logic 	      t_mem_uq_read, t_mem_uq_empty, t_mem_uq_full,
		      t_mem_uq_next_full;
   
   logic [`LG_MEM_UQ_ENTRIES:0]  r_mem_uq_head_ptr, n_mem_uq_head_ptr;
   logic [`LG_MEM_UQ_ENTRIES:0]  r_mem_uq_tail_ptr, n_mem_uq_tail_ptr;
   logic [`LG_MEM_UQ_ENTRIES:0] r_mem_uq_next_head_ptr, n_mem_uq_next_head_ptr;
   logic [`LG_MEM_UQ_ENTRIES:0] r_mem_uq_next_tail_ptr, n_mem_uq_next_tail_ptr;

   /* LSU: the memory scheduler (rv64core's age-matrix scheduler, extended to
    * hold loads until answered and stores until written -- see the LSU block) */
   localparam N_MEM_SCHED_ENTRIES = 1<<`LG_MEM_SCHED_ENTRIES;
   localparam logic [N_MEM_SCHED_ENTRIES-1:0] MEM_SCHED_USABLE = {N_MEM_SCHED_ENTRIES{1'b1}} >> (N_MEM_SCHED_ENTRIES - `MEM_SCHED_ENTRIES);
   uop_t r_mem_sched_uops[N_MEM_SCHED_ENTRIES-1:0];
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_valid, n_mem_sched_valid;
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_ld, n_mem_sched_ld;          /* simple load */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_st, n_mem_sched_st;          /* plain store */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_ser, n_mem_sched_ser;        /* CACHE hit op: serializing */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_old1, n_mem_sched_old1;      /* ldstub/swap: a held op that issues only when oldest */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_mg, n_mem_sched_mg;          /* LWL/LWR/LDL/LDR: needs the old rt (captured) before issue */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_mv, n_mem_sched_mv;          /* MFC1/MTC1/DMFC1/DMTC1: register move, no memory ordering */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_issued, n_mem_sched_issued;  /* address pass issued */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_sd_sel, n_mem_sched_sd_sel;  /* store data read issued */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_sd_ok, n_mem_sched_sd_ok;    /* store data in the l1d */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_ret, n_mem_sched_ret;        /* store retired */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_cmt, n_mem_sched_cmt;        /* store commit issued */
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_ep, n_mem_sched_ep;          /* slot epoch (per alloc) */
   blk_code_t r_mem_sched_blk[N_MEM_SCHED_ENTRIES-1:0];
   blk_code_t n_mem_sched_blk[N_MEM_SCHED_ENTRIES-1:0];
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_blk_st[N_MEM_SCHED_ENTRIES-1:0];   /* LSU-owned block: stores waited on */
   logic [N_MEM_SCHED_ENTRIES-1:0] n_mem_sched_blk_st[N_MEM_SCHED_ENTRIES-1:0];
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_ep_snap[N_MEM_SCHED_ENTRIES-1:0];  /* epochs at issue */
   logic [N_MEM_SCHED_ENTRIES-1:0] n_mem_sched_ep_snap[N_MEM_SCHED_ENTRIES-1:0];
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_sched_matrix[N_MEM_SCHED_ENTRIES-1:0];
   logic [N_MEM_SCHED_ENTRIES-1:0] n_mem_sched_matrix[N_MEM_SCHED_ENTRIES-1:0];
   logic [N_MEM_SCHED_ENTRIES-1:0] t_mem_entry_rdy, t_mem_elig, t_mem_strict, t_mem_pending, t_mem_st_live;
   logic [N_MEM_SCHED_ENTRIES-1:0] t_mem_alloc_entry, t_mem_select_entry, t_mem_free_entry;
   logic [N_MEM_SCHED_ENTRIES-1:0] t_mem_sched_mask_valid, t_mem_survive;
   logic [N_MEM_SCHED_ENTRIES-1:0] t_mem_cmt_rdy, t_mem_sd_rdy, t_mem_st_retire, t_blk_release;
   wire [N_MEM_SCHED_ENTRIES-1:0]  w_mem_sched_oldest_ready;
   logic [`LG_MEM_SCHED_ENTRIES:0] t_mem_sched_alloc_ptr, t_mem_sched_select_ptr, t_mem_sched_pick_ptr;
   logic [`LG_MEM_SCHED_ENTRIES:0] t_mem_cmt_ptr, t_mem_sd_ptr;
   uop_t t_picked_mem_uop;
   logic 	t_mem_issue, t_mem_issue_addr, t_mem_issue_cmt;
   logic 	t_mem_uq_generic_load, t_mem_uq_plain_store, t_mem_uq_serial, t_mem_uq_old1, t_mem_uq_merge, t_mem_uq_move, t_mem_uq_atomic, t_mem_uq_mmureg;
   /* the issued op, one stage on (AGU) */
   logic [`LG_MEM_SCHED_ENTRIES-1:0] r_mem_uq_lsu_idx;
   logic 	r_mem_uq_lsu_hold, r_mem_uq_commit, r_mem_uq_color;
   logic 	r_restart_color;
   logic [N_MEM_SCHED_ENTRIES-1:0] r_mem_uq_older_st, r_mem_uq_older_ep;
   /* store data capture */
   logic 	t_sd_go, r_sd_go, r_sd_fp, r_sd_fp_hi, r_sd_zero, r_sd_std;
   logic 	r_sd_fsr;   /* stfsr: the FSR is the data */
   logic [`LG_FCR_PRF_ENTRIES-1:0] r_sd_fcr;   /* its fcc register */
   /* SPARC std reads its two data registers through the one store-data port on
    * consecutive cycles: r_sd_std_ph2 = this cycle reads rd+1 (r_sd_hi holds rd) */
   logic 	r_sd_std_ph2;
   logic [N_MEM_SCHED_ENTRIES-1:0] t_mem_ldd_out;   /* ldds the l1d still owes a response */
   logic [31:0] r_sd_hi;
   logic [`LG_PRF_ENTRIES-1:0] t_sd_src;
   logic [`LG_MEM_SCHED_ENTRIES-1:0] r_sd_idx;
   logic [`LG_ROB_ENTRIES-1:0] r_sd_rob;

   
   logic             t_push_two_mem,  t_push_two_int;
   logic             t_push_one_mem,  t_push_one_int;
   
   logic 			t_flash_clear;
   always_comb
     begin
	t_flash_clear = ds_done;
     end

   always_comb
     begin
	uq_full = t_uq_full || t_mem_uq_full || t_fp_uq_full;
	uq_next_full = t_uq_next_full || t_mem_uq_next_full || t_fp_uq_next_full;
     end
   
   always_ff@(posedge clk)
     begin
	if(reset || t_flash_clear)
	  begin
	     r_uq_head_ptr <= 'd0;
	     r_uq_tail_ptr <= 'd0;
	     r_uq_next_head_ptr <= 'd1;
	     r_uq_next_tail_ptr <= 'd1;	     
	  end
	else
	  begin
	     r_uq_head_ptr <=  n_uq_head_ptr;
	     r_uq_tail_ptr <=  n_uq_tail_ptr;
	     r_uq_next_head_ptr <= n_uq_next_head_ptr;
	     r_uq_next_tail_ptr <= n_uq_next_tail_ptr;	     
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(reset  || t_flash_clear)
	  begin
	     r_mem_uq_head_ptr <= 'd0;
	     r_mem_uq_tail_ptr <= 'd0;
	     r_mem_uq_next_head_ptr <= 'd1;
	     r_mem_uq_next_tail_ptr <= 'd1;
	  end
	else
	  begin
	     r_mem_uq_head_ptr <= n_mem_uq_head_ptr;
	     r_mem_uq_tail_ptr <= n_mem_uq_tail_ptr;
	     r_mem_uq_next_head_ptr <= n_mem_uq_next_head_ptr;
	     r_mem_uq_next_tail_ptr <= n_mem_uq_next_tail_ptr;
	  end
     end // always_ff@ (posedge clk// )
   
   
   


   always_comb
     begin
	n_mem_uq_head_ptr = r_mem_uq_head_ptr;
	n_mem_uq_tail_ptr = r_mem_uq_tail_ptr;
	n_mem_uq_next_head_ptr = r_mem_uq_next_head_ptr;
	n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr;


	
	t_mem_uq_empty = (r_mem_uq_head_ptr == r_mem_uq_tail_ptr);
	t_mem_uq_full = (r_mem_uq_head_ptr != r_mem_uq_tail_ptr) && (r_mem_uq_head_ptr[`LG_MEM_UQ_ENTRIES-1:0] == r_mem_uq_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]);

	t_mem_uq_next_full = (r_mem_uq_head_ptr != r_mem_uq_next_tail_ptr) && 
			     (r_mem_uq_head_ptr[`LG_MEM_UQ_ENTRIES-1:0] == r_mem_uq_next_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]);

		
	t_mem_uq = r_mem_uq[r_mem_uq_head_ptr[`LG_MEM_UQ_ENTRIES-1:0]];


	t_push_two_mem = uq_push && uq_push_two && uq_uop.is_mem && uq_uop_two.is_mem;
	t_push_one_mem = ((uq_push && uq_uop.is_mem) || (uq_push_two && uq_uop_two.is_mem)) && !t_push_two_mem;

	
	/* these need work */
	if(t_push_two_mem)
	  begin
	     n_mem_uq_tail_ptr = r_mem_uq_tail_ptr + 'd2;
	     n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr + 'd2;

	  end
	else if(uq_push_two && uq_uop_two.is_mem || uq_push && uq_uop.is_mem)
	  begin
	     n_mem_uq_tail_ptr = r_mem_uq_tail_ptr + 'd1;
	     n_mem_uq_next_tail_ptr = r_mem_uq_next_tail_ptr + 'd1;
	  end
	
	if(t_pop_mem_uq)
	  begin
	     n_mem_uq_head_ptr = r_mem_uq_head_ptr + 'd1;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	mem_uq <= t_picked_mem_uop;
	r_mem_uq_lsu_idx <= t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0];
	r_mem_uq_lsu_hold <= r_mem_sched_ld[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] |
			     r_mem_sched_st[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] |
			     r_mem_sched_ser[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]];
	r_mem_uq_commit <= t_mem_issue_cmt;
	r_mem_uq_color <= r_restart_color;
	r_mem_uq_older_st <= r_mem_sched_matrix[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] & t_mem_st_live;
	r_mem_uq_older_ep <= r_mem_sched_ep;
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_mq_wait <= 'd0;
	     r_uq_wait <= 'd0;
	     r_fp_uq_wait <= 'd0;
	  end
	else if(restart_complete)
	  begin
	     r_mq_wait <= 'd0;
	     r_uq_wait <= 'd0;
	     r_fp_uq_wait <= 'd0;
	  end
	else
	  begin
	     //mem port
	     if(t_push_two_mem)
	       begin
		  r_mq_wait[uq_uop_two.rob_ptr] <= 1'b1;
		  r_mq_wait[uq_uop.rob_ptr] <= 1'b1;
	       end
	     else if(t_push_one_mem)
	       begin
		  r_mq_wait[uq_uop.is_mem ? uq_uop.rob_ptr : uq_uop_two.rob_ptr] <= 1'b1; 
	       end
	     if(t_mem_issue_addr)
	       begin
		  r_mq_wait[t_picked_mem_uop.rob_ptr] <= 1'b0;
		  r_memop_pc[t_picked_mem_uop.rob_ptr] <= t_picked_mem_uop.pc[31:0];
	       end
	     /* r_mq_wait = "this op is back in the LSU and will not complete if the
	      * machine flushes now" (t_clr_mask drops its ROB inflight bit).  Only an
	      * LSU-owned block puts it back (it is re-picked, which clears the bit); a
	      * cache-owned block (BLK_MISS/BLK_ST_CONFLICT) stays in the l1d and is
	      * ANSWERED, never re-picked, so setting the bit there leaked it to the next
	      * op in the ROB slot -- a multiply then lost its inflight bit at a flush, the
	      * restart did not wait for it, and its completion landed on a new op. */
	     if(mem_rsp_valid)
	       begin
		  r_mq_wait[mem_rsp_rob_ptr] <= 1'b0;
	       end
	     if(mem_blk_valid && mem_blk_code[2])
	       begin
		  r_mq_wait[mem_rsp_rob_ptr] <= 1'b1;
	       end
	     
	     //int port
	     if(t_push_two_int)
	       begin
		  r_uq_wait[uq_uop.rob_ptr] <= 1'b1;
		  r_uq_wait[uq_uop_two.rob_ptr] <= 1'b1;
	       end
	     else if(t_push_one_int)
	       begin
		  r_uq_wait[uq_uop.is_int ? uq_uop.rob_ptr : uq_uop_two.rob_ptr] <= 1'b1; 
	       end
	     
	     if(r_start_int)
	       begin
		  r_uq_wait[int_uop.rob_ptr] <= 1'b0;
	       end

	     //fp port (mirrors mipscore r_fq_wait: track ops sitting in fp_uq so a
	     // fault-drain can flash-clear their r_rob_inflight via t_clr_mask).
	     if(t_push_two_fp)
	       begin
		  r_fp_uq_wait[uq_uop.rob_ptr] <= 1'b1;
		  r_fp_uq_wait[uq_uop_two.rob_ptr] <= 1'b1;
	       end
	     else if(t_push_one_fp)
	       begin
		  r_fp_uq_wait[uq_uop.is_fp ? uq_uop.rob_ptr : uq_uop_two.rob_ptr] <= 1'b1;
	       end
	     if(t_pop_fp_uq)
	       begin
		  r_fp_uq_wait[fp_uq.rob_ptr] <= 1'b0;
	       end

	  end // else: !if(reset)
     end // always_ff@ (posedge clk)

   
   always_ff@(posedge clk)
     begin
	if(t_push_two_mem)
	  begin
	     //$display("cycle %d : pushing mem ops for rob slots %d & %d", r_cycle, uq_uop_two.rob_ptr, uq_uop.rob_ptr);
	     r_mem_uq[r_mem_uq_next_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]] <= uq_uop_two;
	     r_mem_uq[r_mem_uq_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]] <= uq_uop;
	  end
	else if(t_push_one_mem)
	  begin
	     //$display("cycle %d : pushing mem ops for rob slots %d", r_cycle, uq_uop.rob_ptr);
	     r_mem_uq[r_mem_uq_tail_ptr[`LG_MEM_UQ_ENTRIES-1:0]] <= uq_uop.is_mem ? uq_uop : uq_uop_two;
	  end	
     end // always_ff@ (posedge clk)


   
   

   
   always_comb
     begin
	n_uq_head_ptr = r_uq_head_ptr;
	n_uq_tail_ptr = r_uq_tail_ptr;
	n_uq_next_head_ptr = r_uq_next_head_ptr;
	n_uq_next_tail_ptr = r_uq_next_tail_ptr;
	
	
	t_uq_empty = (r_uq_head_ptr == r_uq_tail_ptr);
	t_uq_full = (r_uq_head_ptr != r_uq_tail_ptr) && 
		    (r_uq_head_ptr[`LG_UQ_ENTRIES-1:0] == r_uq_tail_ptr[`LG_UQ_ENTRIES-1:0]);
	
	t_uq_next_full = (r_uq_head_ptr != r_uq_next_tail_ptr) && 
			 (r_uq_head_ptr[`LG_UQ_ENTRIES-1:0] == r_uq_next_tail_ptr[`LG_UQ_ENTRIES-1:0]);

	t_push_two_int = uq_push && uq_push_two && uq_uop.is_int && uq_uop_two.is_int;
	t_push_one_int = ((uq_push && uq_uop.is_int) || (uq_push_two && uq_uop_two.is_int)) && !t_push_two_int;
	
	uq = r_uq[r_uq_head_ptr[`LG_UQ_ENTRIES-1:0]];
	uq2 = r_uq[r_uq_next_head_ptr[`LG_UQ_ENTRIES-1:0]];
	
	if(t_push_two_int)
	  begin	     
	     n_uq_tail_ptr = r_uq_tail_ptr + 'd2;
	     n_uq_next_tail_ptr = r_uq_next_tail_ptr + 'd2;
	  end
	else if(uq_push_two && uq_uop_two.is_int || uq_push && uq_uop.is_int)
	  begin	     
	     n_uq_tail_ptr = r_uq_tail_ptr + 'd1;
	     n_uq_next_tail_ptr = r_uq_next_tail_ptr + 'd1;
	  end

	
	if(t_pop_uq2)
	  begin
	     n_uq_head_ptr = r_uq_head_ptr + 'd2;
	     n_uq_next_head_ptr = r_uq_next_head_ptr + 'd2;
	  end
	else if(t_pop_uq)
	  begin
	     n_uq_head_ptr = r_uq_head_ptr + 'd1;
	     n_uq_next_head_ptr = r_uq_next_head_ptr + 'd1;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(t_push_two_int)
	  begin
	     r_uq[r_uq_tail_ptr[`LG_UQ_ENTRIES-1:0]] <= uq_uop;
	     r_uq[r_uq_next_tail_ptr[`LG_UQ_ENTRIES-1:0]] <= uq_uop_two;	     
	  end
	else if(t_push_one_int)
	  begin
	     r_uq[r_uq_tail_ptr[`LG_UQ_ENTRIES-1:0]] <= uq_uop.is_int ? uq_uop : uq_uop_two;
	  end
	
     end // always_ff@ (posedge clk)
   
   logic [63:0]        r_cycle;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : r_cycle + 'd1;
	
     end

   


   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_wb_bitvec <= 'd0;
	  end
	else
	  begin
	     r_wb_bitvec <= n_wb_bitvec;
	  end
     end // always_ff@ (posedge clk)

   always_comb
     begin
	for(integer i = (`MAX_LAT-1); i > -1; i = i-1)
	  begin
	     n_wb_bitvec[i] = r_wb_bitvec[i+1];	     
	  end
	n_wb_bitvec[`DIV32_LAT] = t_start_div & r_start_int;
	
	if(t_start_mul&r_start_int)
	  begin
	     n_wb_bitvec[`MUL_LAT] = 1'b1;
	  end
     end // always_comb

   
   always_comb
     begin
	/* forwarded operands come from the data captured WITH the flag (see the
	 * r_fwd_*_data declarations), never from the free-running result registers */
	t_srcA = r_fwd_int_srcA ? r_fwd_srcA_data :
		 r_fwd_mem_srcA ? r_fwd_srcA_data :
		 w_srcA;
	
	t_srcB = r_fwd_int_srcB ? r_fwd_srcB_data :
		 r_fwd_mem_srcB ? r_fwd_srcB_data :
		 w_srcB;

	t_mem_srcA = r_fwd_int_mem_srcA ? r_fwd_mem_srcA_data :
		     r_fwd_mem_mem_srcA ? r_fwd_mem_srcA_data :
		     w_mem_srcA;

	t_mem_srcC = r_fwd_int_mem_srcC ? r_fwd_mem_srcC_data :
		     r_fwd_mem_mem_srcC ? r_fwd_mem_srcC_data :
		     w_mem_srcC;

	
	t_src_hilo = r_fwd_hilo_int ? r_fwd_hilo_data :
		     r_fwd_hilo_mul ? r_fwd_hilo_data :
		     r_fwd_hilo_div ? r_fwd_hilo_data :
		     r_src_hilo;
     end // always_comb




   //does this scheduler entry contain a valid uop?
   logic [N_INT_SCHED_ENTRIES-1:0] r_alu_sched_valid;
   logic [`LG_INT_SCHED_ENTRIES:0] t_alu_sched_alloc_ptr;
   logic 			  t_alu_sched_full;
   /* ENABLE_SCHED_BYPASS: uq head issues straight to the ALU this cycle */
   logic 			  t_uq_bypass;
   logic [`LG_INT_SCHED_ENTRIES:0] t_alu_sched_alloc2_ptr;
   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_alloc2_entry;
   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_sched_free2;
   logic t_alu_alloc2_srcA_match,
	 t_alu_alloc2_srcB_match,
	 t_alu_alloc2_hilo_match,
	 t_alu_alloc2_fcr_match;
   
   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_alloc_entry, t_alu_select_entry;

   uop_t r_alu_sched_uops[N_INT_SCHED_ENTRIES-1:0];
   uop_t t_picked_uop;

   
   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_entry_rdy;
   logic [`LG_INT_SCHED_ENTRIES:0]  t_alu_sched_select_ptr;
   
	
   logic [N_INT_SCHED_ENTRIES-1:0] r_alu_srcA_rdy,
				   r_alu_srcB_rdy,
				   r_alu_hilo_rdy,
				   r_alu_fcr_rdy;
   /* srcC (movn/movz rt) ready, or no srcC */
   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_srcC_ok;
`ifdef ENABLE_INT_SRCC
   /* movn/movz: rt is only a condition, "is its physical register zero" -- one
    * flag bit per int physical register, written with every int PRF write (never
    * physreg 0, which rf4r2w does not write either: its flag stays 1), and a
    * third ready bit that wakes on the same producers as srcA/srcB.  A consumer
    * selected on a writeback match executes the next cycle, after the flag write. */
   logic [N_INT_PRF_ENTRIES-1:0]   r_prf_zero;
   logic [3:0] 			   r_prf_icc[N_INT_PRF_ENTRIES-1:0];   /* {N, Z, V, C} */
   logic [3:0] 			   t_icc_out;
   logic [N_INT_SCHED_ENTRIES-1:0] r_alu_srcC_rdy, t_alu_srcC_match;
   logic 			   t_alu_alloc_srcC_match, t_alu_alloc2_srcC_match;
`endif

   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_srcA_match,
				   t_alu_srcB_match,
				   t_alu_hilo_match,
				   t_alu_fcr_match;



   logic t_alu_alloc_srcA_match,
	 t_alu_alloc_srcB_match,
	 t_alu_alloc_hilo_match,
	 t_alu_alloc_fcr_match;
   
   wire [N_INT_SCHED_ENTRIES-1:0] w_alu_sched_oldest_ready;
   
   find_lowest_set_bit#(`LG_INT_SCHED_ENTRIES) ffs_int_sched_alloc( .in(~r_alu_sched_valid & INT_SCHED_USABLE),
							      .y(t_alu_sched_alloc_ptr));

   find_lowest_set_bit#(`LG_INT_SCHED_ENTRIES) ffs_int_sched_alloc2( .in(t_alu_sched_free2),
							       .y(t_alu_sched_alloc2_ptr));

   find_lowest_set_bit#(`LG_INT_SCHED_ENTRIES) ffs_int_sched_select( .in(w_alu_sched_oldest_ready),
								.y(t_alu_sched_select_ptr));

   
   
   always_comb
     begin
	t_alu_alloc_entry = 'd0;
	t_alu_alloc2_entry = 'd0;
	t_alu_select_entry = 'd0;
	if(t_pop_uq && !t_uq_bypass)
	  begin
	     t_alu_alloc_entry[t_alu_sched_alloc_ptr[`LG_INT_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
	if(t_pop_uq2)
	  begin
	     t_alu_alloc2_entry[t_alu_sched_alloc2_ptr[`LG_INT_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
	if(t_alu_entry_rdy != 'd0)
	  begin
	     t_alu_select_entry[t_alu_sched_select_ptr[`LG_INT_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
     end // always_comb




   always_comb
     begin
	t_picked_uop = t_uq_bypass ? uq : r_alu_sched_uops[t_alu_sched_select_ptr[`LG_INT_SCHED_ENTRIES-1:0]];
     end
   
   always_ff@(posedge clk)
     begin
	int_uop <= t_picked_uop;
     end

`ifdef TOPDOWN
   /* per-uop stage stamps (see core.sv TOPDOWN): 1 = enters the ALU scheduler,
    * 2 = ALU execute starts, 3 = memory uop dispatched to address generation */
   import "DPI-C" function void topdown_uop(input int ev, input int rob_ptr);
   always_ff@(negedge clk)
     begin
	if(!reset)
	  begin
	     if(t_pop_uq)
	       begin
		  topdown_uop(1, {{(32-`LG_ROB_ENTRIES){1'b0}}, uq.rob_ptr});
	       end
	     if(t_pop_uq2)
	       begin
		  topdown_uop(1, {{(32-`LG_ROB_ENTRIES){1'b0}}, uq2.rob_ptr});
	       end
	     if(r_start_int)
	       begin
		  topdown_uop(2, {{(32-`LG_ROB_ENTRIES){1'b0}}, int_uop.rob_ptr});
	       end
	     if(t_mem_issue_addr)
	       begin
		  topdown_uop(3, {{(32-`LG_ROB_ENTRIES){1'b0}}, t_picked_mem_uop.rob_ptr});
	       end
	  end
     end // always_ff
`endif

`ifdef PIPETRACE
   /* pipetrace stage events (letters in gen_html.cc), joined by rob index in top.cc */
   import "DPI-C" function void pt_event(input int rob_ptr, input int letter, input longint cycle);
   function int pt_rob(logic [`LG_ROB_ENTRIES-1:0] p);
      return {{(32-`LG_ROB_ENTRIES){1'b0}}, p};
   endfunction
   always_ff@(negedge clk)
     begin
	if(!reset)
	  begin
	     if(r_start_int)
	       begin
		  pt_event(pt_rob(int_uop.rob_ptr), "S", r_cycle);
	       end
	     if(t_pop_mem_uq)
	       begin
		  pt_event(pt_rob(t_mem_uq.rob_ptr), "Q", r_cycle);
	       end
	     if(t_mem_issue_addr)
	       begin
		  pt_event(pt_rob(t_picked_mem_uop.rob_ptr), "S", r_cycle);
	       end
	     if(mem_blk_valid)
	       begin
		  pt_event(pt_rob(mem_rsp_rob_ptr),
			   (mem_blk_code == BLK_MISS) ? "B" :
			   (mem_blk_code == BLK_ST_CONFLICT) ? "X" :
			   (mem_blk_code == BLK_SB_CONFLICT) ? "W" :
			   (mem_blk_code == BLK_UNCACHEABLE) ? "U" : "D", r_cycle);
	       end
	     if(mem_wake_valid && r_mem_sched_valid[mem_rsp_lsu_idx])
	       begin
		  pt_event(pt_rob(r_mem_sched_uops[mem_rsp_lsu_idx].rob_ptr), "K", r_cycle);
	       end
	     for(integer i = 0; i < N_MEM_SCHED_ENTRIES; i = i + 1)
	       begin
		  if(t_blk_release[i] && r_mem_sched_valid[i])
		    begin
		       pt_event(pt_rob(r_mem_sched_uops[i].rob_ptr), "K", r_cycle);
		    end
	       end
	     if(r_sd_go)
	       begin
		  pt_event(pt_rob(r_sd_rob), "Z", r_cycle);
	       end
	  end
     end // always_ff@ (negedge clk)
`endif

   always_ff@(posedge clk)
     begin
	r_start_int <= reset ? 1'b0 : (((t_alu_entry_rdy != 'd0) | t_uq_bypass) & !ds_done);
     end // always_comb

   
   
   always_comb
     begin
	//allocation forwarding
	t_alu_alloc_srcA_match = uq.srcA_valid && (
						   (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == uq.srcA)) ||
						   (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == uq.srcA))
						   );
	t_alu_alloc_srcB_match = uq.srcB_valid && (
						   (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == uq.srcB)) ||
						   (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == uq.srcB))
						   );

	t_alu_alloc_hilo_match = uq.hilo_src_valid && (
						       (t_hilo_prf_ptr_val_out & (t_hilo_prf_ptr_out == uq.hilo_src)) ||
						       (r_start_int && t_wr_hilo && (int_uop.hilo_dst == uq.hilo_src))
						       );
	/* FCR source (BC1x): wakes on the fpu compare writing the same FCR phys reg */
	t_alu_alloc_fcr_match = uq.fcr_src_valid &&
				(w_fpu_fcr_valid & (w_fpu_fcr_ptr == uq.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]));

	t_alu_alloc2_srcA_match = uq2.srcA_valid && (
						     (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == uq2.srcA)) ||
						     (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == uq2.srcA))
						     );
	t_alu_alloc2_srcB_match = uq2.srcB_valid && (
						     (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == uq2.srcB)) ||
						     (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == uq2.srcB))
						     );
	t_alu_alloc2_hilo_match = uq2.hilo_src_valid && (
							 (t_hilo_prf_ptr_val_out & (t_hilo_prf_ptr_out == uq2.hilo_src)) ||
							 (r_start_int && t_wr_hilo && (int_uop.hilo_dst == uq2.hilo_src))
							 );
	t_alu_alloc2_fcr_match = uq2.fcr_src_valid &&
				 (w_fpu_fcr_valid & (w_fpu_fcr_ptr == uq2.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]));
`ifdef ENABLE_INT_SRCC
	t_alu_alloc_srcC_match = uq.srcC_valid && (
						   (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == uq.srcC)) ||
						   (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == uq.srcC))
						   );
	t_alu_alloc2_srcC_match = uq2.srcC_valid && (
						     (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == uq2.srcC)) ||
						     (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == uq2.srcC))
						     );
`endif

     end // always_comb
  

   logic [N_INT_SCHED_ENTRIES-1:0] t_alu_sched_mask_valid;
   logic [N_INT_SCHED_ENTRIES-1:0] r_alu_sched_matrix [N_INT_SCHED_ENTRIES-1:0];

   
   always_comb
     begin
	t_alu_sched_mask_valid = r_alu_sched_valid & (~t_alu_select_entry);
     end

   generate
      for(genvar i = 0; i < N_INT_SCHED_ENTRIES; i=i+1)
	begin
	   assign w_alu_sched_oldest_ready[i] = t_alu_entry_rdy[i] & (~(|(t_alu_entry_rdy & r_alu_sched_matrix[i])));
	   always_ff@(posedge clk)
	     begin
		if(reset || t_flash_clear)
		  begin
		     r_alu_sched_matrix[i] <= 'd0;
		  end
		else if(t_alu_alloc_entry[i])
		  begin
		     r_alu_sched_matrix[i] <= t_alu_sched_mask_valid;
		  end
		else if(t_alu_alloc2_entry[i])
		  begin
		     r_alu_sched_matrix[i] <= t_alu_sched_mask_valid | t_alu_alloc_entry;
		  end
		else if(t_alu_entry_rdy != 'd0)
		  begin
		     r_alu_sched_matrix[i] <= r_alu_sched_matrix[i] & (~t_alu_select_entry);
		  end
	     end
	end // for (genvar i = 0; i < N_INT_SCHED_ENTRIES; i=i+1)
   endgenerate

   //always_ff@(negedge clk)
   //begin
   //if(t_alu_entry_rdy != 'd0)
   //	  $display("w_alu_sched_oldest = %b, w_alu_sched_oldest_ready = %b, t_alu_entry_rdy = %b", 
   //w_alu_sched_oldest, w_alu_sched_oldest_ready, t_alu_entry_rdy);
   //end
   
   generate
      for(genvar i = 0; i < N_INT_SCHED_ENTRIES; i=i+1)
	begin
	   always_comb
	     begin
		t_alu_srcA_match[i] = r_alu_sched_uops[i].srcA_valid && (
									 (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == r_alu_sched_uops[i].srcA)) ||
									 (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == r_alu_sched_uops[i].srcA))
									 );
		t_alu_srcB_match[i] = r_alu_sched_uops[i].srcB_valid && (
									 (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == r_alu_sched_uops[i].srcB)) ||
									 (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == r_alu_sched_uops[i].srcB))
									 );
		
		t_alu_hilo_match[i] = r_alu_sched_uops[i].hilo_src_valid && (
									     (t_hilo_prf_ptr_val_out & (t_hilo_prf_ptr_out == r_alu_sched_uops[i].hilo_src)) ||
									     (r_start_int && t_wr_hilo && (int_uop.hilo_dst == r_alu_sched_uops[i].hilo_src))
									     );
		t_alu_fcr_match[i] = r_alu_sched_uops[i].fcr_src_valid &&
				     (w_fpu_fcr_valid & (w_fpu_fcr_ptr == r_alu_sched_uops[i].hilo_src[`LG_FCR_PRF_ENTRIES-1:0]));
`ifdef ENABLE_INT_SRCC
		t_alu_srcC_match[i] = r_alu_sched_uops[i].srcC_valid && (
									 (w_mem_rsp_int_valid & (mem_rsp_dst_ptr == r_alu_sched_uops[i].srcC)) ||
									 (t_iwb & (t_iwb_dst != 'd0) & (t_iwb_dst == r_alu_sched_uops[i].srcC))
									 );
		t_alu_srcC_ok[i] = t_alu_srcC_match[i] | r_alu_srcC_rdy[i];
`else
		t_alu_srcC_ok[i] = 1'b1;
`endif
	

		//is_mult(r_alu_sched_uops[i].op);
		
		t_alu_entry_rdy[i] = r_alu_sched_valid[i] &&
				     (is_div(r_alu_sched_uops[i].op) ?  (t_div_ready & !t_fdiv_pop & !r_wb_bitvec[1]) :  (is_mult(r_alu_sched_uops[i].op) ?  !r_wb_bitvec[`MUL_LAT+2] : !r_wb_bitvec[1]))
				     ? (
					(t_alu_srcA_match[i] |r_alu_srcA_rdy[i]) &
					(t_alu_srcB_match[i] |r_alu_srcB_rdy[i]) &
					(t_alu_hilo_match[i] |r_alu_hilo_rdy[i]) &
					(t_alu_fcr_match[i] |r_alu_fcr_rdy[i]) &
					t_alu_srcC_ok[i] &
					(!r_alu_sched_uops[i].oldest_first ||
					 (head_of_rob_ptr_valid &&
					  (r_alu_sched_uops[i].rob_ptr == head_of_rob_ptr)) ||
					 /* Fix A sibling: an oldest_first op (e.g. mfc0) that is the
					  * REGULAR delay slot of a complete, faulted branch at the head
					  * is non-speculative (guaranteed to commit), so let it issue
					  * even though the branch -- not it -- is the head.  Without
					  * this, the branch's retire waits for the delay slot to
					  * complete while the delay slot waits to be oldest -> deadlock
					  * (IRIX boot: faulted beqz + mfc0 c0_cause delay slot). */
					 (head_of_rob_ds_committable &&
					  (r_alu_sched_uops[i].rob_ptr == next_head_of_rob_ptr))) ) : 1'b0;
	     end // always_comb
	   
	   always_ff@(posedge clk)
	     begin
		if(reset)
		  begin
		     r_alu_srcA_rdy[i] <= 1'b0;
		     r_alu_srcB_rdy[i] <= 1'b0;
		     r_alu_hilo_rdy[i] <= 1'b0;
		     r_alu_fcr_rdy[i] <= 1'b0;
		  end
		else
		  begin
		     if(t_alu_alloc_entry[i])
		       begin //allocating to this entry
			  r_alu_srcA_rdy[i] <= uq.srcA_valid ? (!r_prf_inflight[uq.srcA] | t_alu_alloc_srcA_match) : 1'b1;
			  r_alu_srcB_rdy[i] <= uq.srcB_valid ? (!r_prf_inflight[uq.srcB] | t_alu_alloc_srcB_match) : 1'b1;
			  r_alu_hilo_rdy[i] <= uq.hilo_src_valid ? (!r_hilo_inflight[uq.hilo_src] | t_alu_alloc_hilo_match) : 1'b1;
			  r_alu_fcr_rdy[i] <= uq.fcr_src_valid ? (!r_fcr_prf_inflight[uq.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]] | t_alu_alloc_fcr_match) : 1'b1;
		       end
		     else if(t_alu_alloc2_entry[i])
		       begin
			  r_alu_srcA_rdy[i] <= uq2.srcA_valid ? (!r_prf_inflight[uq2.srcA] | t_alu_alloc2_srcA_match) : 1'b1;
			  r_alu_srcB_rdy[i] <= uq2.srcB_valid ? (!r_prf_inflight[uq2.srcB] | t_alu_alloc2_srcB_match) : 1'b1;
			  r_alu_hilo_rdy[i] <= uq2.hilo_src_valid ? (!r_hilo_inflight[uq2.hilo_src] | t_alu_alloc2_hilo_match) : 1'b1;
			  r_alu_fcr_rdy[i] <= uq2.fcr_src_valid ? (!r_fcr_prf_inflight[uq2.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]] | t_alu_alloc2_fcr_match) : 1'b1;
		       end
		     else if(t_alu_select_entry[i])
		       begin
			  r_alu_srcA_rdy[i] <= 1'b0;
			  r_alu_srcB_rdy[i] <= 1'b0;
			  r_alu_hilo_rdy[i] <= 1'b0;
			  r_alu_fcr_rdy[i] <= 1'b0;
		       end
		     else if(r_alu_sched_valid[i])
		       begin
			  r_alu_srcA_rdy[i] <= r_alu_srcA_rdy[i] | t_alu_srcA_match[i];
			  r_alu_srcB_rdy[i] <= r_alu_srcB_rdy[i] | t_alu_srcB_match[i];
			  r_alu_hilo_rdy[i] <= r_alu_hilo_rdy[i] | t_alu_hilo_match[i];
			  r_alu_fcr_rdy[i] <= r_alu_fcr_rdy[i] | t_alu_fcr_match[i];
		       end // else: !if(t_pop_uq&&(t_alu_sched_alloc_ptr == i))
		     
		  end // else: !if(reset)
	     end // always_ff@ (posedge clk)
`ifdef ENABLE_INT_SRCC
	   always_ff@(posedge clk)
	     begin
		if(reset)
		  begin
		     r_alu_srcC_rdy[i] <= 1'b0;
		  end
		else if(t_alu_alloc_entry[i])
		  begin
		     r_alu_srcC_rdy[i] <= uq.srcC_valid ? (!r_prf_inflight[uq.srcC] | t_alu_alloc_srcC_match) : 1'b1;
		  end
		else if(t_alu_alloc2_entry[i])
		  begin
		     r_alu_srcC_rdy[i] <= uq2.srcC_valid ? (!r_prf_inflight[uq2.srcC] | t_alu_alloc2_srcC_match) : 1'b1;
		  end
		else if(t_alu_select_entry[i])
		  begin
		     r_alu_srcC_rdy[i] <= 1'b0;
		  end
		else if(r_alu_sched_valid[i])
		  begin
		     r_alu_srcC_rdy[i] <= r_alu_srcC_rdy[i] | t_alu_srcC_match[i];
		  end
	     end // always_ff@ (posedge clk)
`endif
	end // for (genvar i = 0; i < LG_INT_SCHED_ENTRIES; i=i+1)
   endgenerate
   
   
   
   /* second free entry: any free entry other than the first allocation's */
   always_comb
     begin
	t_alu_sched_free2 = ~r_alu_sched_valid & INT_SCHED_USABLE;
	t_alu_sched_free2[t_alu_sched_alloc_ptr[`LG_INT_SCHED_ENTRIES-1:0]] = 1'b0;
     end

   always_comb
     begin
	t_pop_uq = 1'b0;
	t_uq_bypass = 1'b0;
	t_alu_sched_full = (&(r_alu_sched_valid | ~INT_SCHED_USABLE));
`ifdef ENABLE_SCHED_BYPASS
	/* An entry written into the scheduler is not selectable until the next
	 * cycle, so a uq-head uop whose operands are already ready would wait a
	 * cycle for nothing.  When no scheduler entry is ready (so oldest-ready
	 * priority is unaffected), issue the uq head directly.  Readiness is the
	 * same !inflight|alloc-match test used when the uop is written into an
	 * entry; the operand read and the r_fwd_* capture follow t_picked_uop.
	 * div/mult/oldest_first keep the normal path. */
	t_uq_bypass = !(t_flash_clear || t_uq_empty) && (t_alu_entry_rdy == 'd0) &&
		      !is_div(uq.op) && !is_mult(uq.op) && !uq.oldest_first && !r_wb_bitvec[1] &&
		      (uq.srcA_valid ? (!r_prf_inflight[uq.srcA] | t_alu_alloc_srcA_match) : 1'b1) &&
		      (uq.srcB_valid ? (!r_prf_inflight[uq.srcB] | t_alu_alloc_srcB_match) : 1'b1) &&
		      (uq.hilo_src_valid ? (!r_hilo_inflight[uq.hilo_src] | t_alu_alloc_hilo_match) : 1'b1) &&
		      (uq.fcr_src_valid ? (!r_fcr_prf_inflight[uq.hilo_src] | t_alu_alloc_fcr_match) : 1'b1)
`ifdef ENABLE_INT_SRCC
		      && (uq.srcC_valid ? (!r_prf_inflight[uq.srcC] | t_alu_alloc_srcC_match) : 1'b1)
`endif
		      ;
`endif
	t_pop_uq = !(t_flash_clear || t_uq_empty ||t_alu_sched_full) || t_uq_bypass;
	t_pop_uq2 = 1'b0;
`ifdef ENABLE_UQ_DUAL_POP
	/* The uq pops one uop per cycle but allocation pushes up to two, so
	 * back-to-back int pairs queue here.  Pop the second uq entry into a
	 * second free scheduler entry.  Both uops were pushed in earlier cycles,
	 * so their inflight bits already reflect each other (no pair hazard). */
	t_pop_uq2 = t_pop_uq && (r_uq_next_head_ptr != r_uq_tail_ptr) && (t_alu_sched_free2 != 'd0);
`endif
     end
   
   always_ff@(posedge clk)
     begin
	if(reset || t_flash_clear)
	  begin
	     r_alu_sched_valid <= 'd0;
	  end
	else
	  begin
	     if(t_pop_uq && !t_uq_bypass)
	       begin
		  /* USABLE, not 1: unusable entries' valid bits are then a constant 0 */
		  r_alu_sched_valid[t_alu_sched_alloc_ptr[`LG_INT_SCHED_ENTRIES-1:0]] <= INT_SCHED_USABLE[t_alu_sched_alloc_ptr[`LG_INT_SCHED_ENTRIES-1:0]];
		  r_alu_sched_uops[t_alu_sched_alloc_ptr[`LG_INT_SCHED_ENTRIES-1:0]] <= uq;
	       end
	     if(t_pop_uq2)
	       begin
		  r_alu_sched_valid[t_alu_sched_alloc2_ptr[`LG_INT_SCHED_ENTRIES-1:0]] <= INT_SCHED_USABLE[t_alu_sched_alloc2_ptr[`LG_INT_SCHED_ENTRIES-1:0]];
		  r_alu_sched_uops[t_alu_sched_alloc2_ptr[`LG_INT_SCHED_ENTRIES-1:0]] <= uq2;
	       end
	     if(t_alu_entry_rdy != 'd0)
	       begin
		  r_alu_sched_valid[t_alu_sched_select_ptr[`LG_INT_SCHED_ENTRIES-1:0]] <= 1'b0;
	       end
	  end // else: !if(reset)
     end

   mul #(.W(`M_WIDTH)) m(
			 .clk(clk),
			 .reset(reset),
			 .is_signed((int_uop.op == S_SMUL) || (int_uop.op == S_SMULCC)),
			 .go(t_start_mul&r_start_int),
			 .src_A(t_srcA),
			 .src_B(w_s_op2),
			 .rob_ptr_in(int_uop.rob_ptr),
			 .hilo_prf_ptr_in(int_uop.hilo_dst),
			 .dst_ptr_in(int_uop.dst),
			 .dst_val_in(int_uop.dst_valid),
			 .cc_in(int_uop.flags_dst_valid),
			 .y(t_mul_result),
			 .complete(t_mul_complete),
			 .rob_ptr_out(t_rob_ptr_out),
			 .hilo_prf_ptr_val_out(t_hilo_prf_ptr_val_out),
			 .hilo_prf_ptr_out(t_hilo_prf_ptr_out),
			 .dst_ptr_out(w_mul_dst),
			 .dst_val_out(w_mul_dst_val),
			 .cc_out(w_mul_cc)
	 );

   /* ---- SPARC multiply / divide writeback ----
    * umul/smul: rd = the low word (+ icc), Y = the high word (the HILO port),
    * both at the multiplier's completion.  udiv/sdiv: rd = the quotient of
    * {Y, rs1} / operand 2, saturated (+ icc, V = overflow); they do not write Y.
    * One divide is in flight (uni_divider): its rd and saturation rules are held
    * here from its start. */
   logic [`LG_PRF_ENTRIES-1:0] r_div_dst;
   logic 		       r_div_dst_val, r_div_cc, r_div_signed, r_div_min_m1;
   always_ff@(posedge clk)
     begin
	if(t_start_div)
	  begin
	     r_div_dst <= int_uop.dst;
	     r_div_dst_val <= int_uop.dst_valid;
	     r_div_cc <= int_uop.flags_dst_valid;
	     r_div_signed <= t_signed_div;
	     /* INT64_MIN / -1: the only quotient past int64 (interpret.cc) */
	     r_div_min_m1 <= ({t_src_hilo, t_srcA[31:0]} == 64'h8000000000000000) &&
			     (w_s_op2 == 32'hffffffff);
	  end
     end // always_ff@ (posedge clk)
   wire [63:0] w_div_q = w_div_y[63:0];
   wire        w_div_ovf = r_div_signed ? (r_div_min_m1 | (w_div_q[63:31] != {33{w_div_q[63]}})) :
		 (w_div_q[63:32] != 32'd0);
   wire [31:0] w_div_rd = !w_div_ovf ? w_div_q[31:0] :
		 !r_div_signed ? 32'hffffffff :
		 (r_div_min_m1 | !w_div_q[63]) ? 32'h7fffffff :
		 32'h80000000;
   wire        w_mul_wb = t_mul_complete & w_mul_dst_val;
   wire        w_div_wb = t_div_complete & r_div_dst_val;

   /* integer writeback port 0 (and its wakeup / forwarding): the ALU, or a
    * multiply or divide completing.  They are exclusive -- r_wb_bitvec reserves
    * the multiplier's slot, and uni_divider drains only into a free one. */
   always_comb
     begin
	t_iwb = (r_start_int & t_wr_int_prf) | w_mul_wb | w_div_wb;
	t_iwb_dst = w_mul_wb ? w_mul_dst : w_div_wb ? r_div_dst : int_uop.dst;
	t_iwb_data = w_mul_wb ? t_mul_result[`M_WIDTH-1:0] : w_div_wb ? w_div_rd : t_result;
	t_iwb_flags = w_mul_wb ? w_mul_cc : w_div_wb ? r_div_cc : int_uop.flags_dst_valid;
	t_iwb_icc = w_mul_wb ? {t_mul_result[31], (t_mul_result[31:0] == 32'd0), 2'b00} :
		    w_div_wb ? {w_div_rd[31], (w_div_rd == 32'd0), w_div_ovf, 1'b0} :
		    t_icc_out;
     end // always_comb
`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
	if(!reset && ((r_start_int & t_alu_valid & (t_mul_complete | t_div_complete)) ||
		      (t_mul_complete & t_div_complete)))
	  begin
	     $display("[IWB] cyc=%0d writeback collision: alu %b mul %b div %b",
		      r_cycle, r_start_int & t_alu_valid, t_mul_complete, t_div_complete);
	     $stop;
	  end
     end
`endif

   /* CLZ-accelerated divider (ported from rv64core/nu_divider). It finishes
    * early and holds the result until a HILO writeback slot is free; the other
    * two HILO writers are the multiplier (t_hilo_prf_ptr_val_out) and int->HILO
    * ops (r_start_int & t_wr_hilo). The DIV32/64_LAT reservation above is the
    * backstop that guarantees a free slot by the worst-case latency. */
   /* 64 bits wide whatever M_WIDTH is: the FP divides need it, and a SPARC
    * udiv/sdiv divides the 64-bit {Y, rs1} */
   uni_divider #(.LG_W(6))
   d0 (
       .clk(clk),
       .reset(reset),
       /* ds_done: the delay slot (if any) has completed, so an op still in d0 is dead */
       .flush(ds_done),
       /* defer the divide's WB drain for ANY int completion, not just HILO-writing
	* ones: the divide shares the ROB completion port complete_bundle_1 with plain
	* ALU ops (r_start_int & t_alu_valid), and div wins that mux -- so draining in
	* the same cycle an ALU op completes DROPS the ALU op's completion -> its ROB
	* entry never completes -> head wedge.  (& t_wr_hilo missed plain ALU ops; this
	* restores rv64core's `r_start_int | t_mul_complete` guard.) */
       .wb_slot_used(t_hilo_prf_ptr_val_out | r_start_int),
       .is_32b(1'b0),
       /* {Y, rs1} by operand 2, sign- or zero-extended */
       .srcA({t_src_hilo, t_srcA[31:0]}),
       .srcB(t_signed_div ? {{32{w_s_op2[31]}}, w_s_op2} : {32'd0, w_s_op2}),
       .rob_ptr_in(int_uop.rob_ptr),
       .hilo_prf_ptr_in(int_uop.hilo_dst),
       .is_signed_div(t_signed_div),
       .start_div(t_start_div),
       .y(w_div_y),
       .rob_ptr_out(t_div_rob_ptr_out),
       .hilo_prf_ptr_out(t_div_hilo_prf_ptr_out),
       .complete(t_div_complete),
       .ready(t_div_ready),
       .fp_opcode(r_fp_iss_uop.op),
       .fp_start(t_fdiv_start),
`ifdef ENABLE_MIPS4
       /* recip = 1.0 / fs: the constant dividend, fs as the divisor */
       .fp_src_a(((r_fp_iss_uop.op == SP_RECIP) || (r_fp_iss_uop.op == DP_RECIP)) ?
		 ((r_fp_iss_uop.op == DP_RECIP) ? 64'h3ff0000000000000 : 64'h000000003f800000) : w_fp_srcA),
       .fp_src_b(((r_fp_iss_uop.op == SP_RECIP) || (r_fp_iss_uop.op == DP_RECIP)) ? w_fp_srcA : w_fp_srcB),
`else
       .fp_src_a(w_fp_srcA),
       .fp_src_b(w_fp_srcB),
`endif
       .fp_rm(w_fsr_rd),
       .fp_rob_ptr_in(r_fp_iss_uop.rob_ptr),
       .fp_dst_ptr_in(r_fp_iss_uop.dst),
       .fp_wb_slot_used(t_fdiv_wb_used),
       .fp_ready(w_fdiv_ready),
       .fp_complete(w_fdiv_complete),
       .fp_y(w_fdiv_y),
       .fp_fflags(w_fdiv_fflags),
       .fp_denorm(w_fdiv_denorm),
       .fp_rob_ptr_out(w_fdiv_rob_ptr),
       .fp_dst_ptr_out(w_fdiv_dst_ptr)
       );
   
   assign divide_ready = t_div_ready;




   
   always_comb
     begin
	n_mq_head_ptr = r_mq_head_ptr;
	n_mq_tail_ptr = r_mq_tail_ptr;
	n_mq_next_tail_ptr = r_mq_next_tail_ptr;
	
`ifdef ENABLE_L1D_SKID
	/* skid: enqueue a fresh request only if it was NOT bypassed-and-accepted this
	 * cycle; advance head only for requests that actually came from the FIFO. */
	if(r_mem_ready & !(w_skid_bypass & mem_req_ack))
	  begin
	     n_mq_tail_ptr = r_mq_tail_ptr + 'd1;
	     n_mq_next_tail_ptr = r_mq_next_tail_ptr + 'd1;
	  end
	if(mem_req_ack & !w_skid_bypass)
	  begin
	     n_mq_head_ptr = r_mq_head_ptr + 'd1;
	  end
`else
	if(r_mem_ready)
	  begin
	     n_mq_tail_ptr = r_mq_tail_ptr + 'd1;
	     n_mq_next_tail_ptr = r_mq_next_tail_ptr + 'd1;
	  end
	if(mem_req_ack)
	  begin
	     n_mq_head_ptr = r_mq_head_ptr + 'd1;
	  end
`endif
	
	t_mem_head = r_mem_q[r_mq_head_ptr[`LG_MQ_ENTRIES-1:0]];
	
	mem_q_empty = (r_mq_head_ptr == r_mq_tail_ptr);
	
	mem_q_full = (r_mq_head_ptr != r_mq_tail_ptr) &&
		     (r_mq_head_ptr[`LG_MQ_ENTRIES-1:0] == r_mq_tail_ptr[`LG_MQ_ENTRIES-1:0]);

	mem_q_next_full = (r_mq_head_ptr != r_mq_next_tail_ptr) &&
			  (r_mq_head_ptr[`LG_MQ_ENTRIES-1:0] == r_mq_next_tail_ptr[`LG_MQ_ENTRIES-1:0]);
	
     end // always_comb
   
   always_ff@(posedge clk)
     begin
`ifdef ENABLE_L1D_SKID
	if(r_mem_ready & !(w_skid_bypass & mem_req_ack))
	  begin
	     r_mem_q[r_mq_tail_ptr[`LG_MQ_ENTRIES-1:0]] <= t_mem_tail;
	  end
`else
	if(r_mem_ready)
	  begin
	     r_mem_q[r_mq_tail_ptr[`LG_MQ_ENTRIES-1:0]] <= t_mem_tail;
	  end
`endif
     end


   
   

   
`ifdef ENABLE_L1D_SKID
   /* bypass the FIFO when it is empty and a fresh AGU'd request is ready this
    * cycle: drive t_mem_tail straight to the L1D (which accepts combinationally
    * and registers into r_req2), saving the enqueue->dequeue cycle. */
   wire w_skid_bypass = (r_mq_head_ptr == r_mq_tail_ptr) & r_mem_ready;
   assign mem_req       = w_skid_bypass ? t_mem_tail : t_mem_head;
   assign mem_req_valid = !mem_q_empty | r_mem_ready;
`else
   assign mem_req = t_mem_head;
   assign mem_req_valid = !mem_q_empty;
`endif
   assign uq_wait = r_uq_wait;
   assign mq_wait = r_mq_wait;
   assign dbg_memop_pc = r_memop_pc[dbg_memop_idx];
   assign fp_uq_wait = r_fp_uq_wait;
   
   
   always_ff@(posedge clk)
     begin
	r_mq_head_ptr <= reset ? 'd0 : n_mq_head_ptr;
	r_mq_tail_ptr <= reset ? 'd0 : n_mq_tail_ptr;
	r_mq_next_tail_ptr <= reset ? 'd1 : n_mq_next_tail_ptr;
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_prf_inflight <= 'd0;
	     r_hilo_inflight <= 'd0;
	     r_fp_prf_inflight <= 'd0;
	  end
	else
	  begin
	     r_prf_inflight <= ds_done ? 'd0 : n_prf_inflight;
	     r_hilo_inflight <= ds_done ? 'd0 : n_hilo_inflight;
	     r_fp_prf_inflight <= ds_done ? 'd0 : n_fp_prf_inflight;
	  end
     end // always_ff@ (posedge clk)

   /* FP register file -- clustered/banked (Henry Wong scheme), like the int PRF.
    * Bank by physical-ptr MSB: bank 0 (fpu-arith results, write port 0) / bank 1
    * (mem-pipe FP results = loads + mtc1, write port 1).  The free-list allocates
    * fp dsts into the bank matching their producing write port (core.sv), so the
    * MSB is meaningful.  4 synchronous read ports: rd0/rd1 = fpu operands (address
    * = combinational FP-UQ head; consumed a cycle later in the FP read stage),
    * rd2/rd3 = mem-pipe reads (mfc1 source / FP store data), aligned with mem_uq /
    * mem_dq exactly as before.  read-before-write on a same-cycle collision is a
    * non-issue: inflight pop-gating never lets a source be read the cycle it is
    * written. */
   fp_regfile #(.WIDTH(`FP_WIDTH), .LG_DEPTH(`LG_PRF_ENTRIES))
   fpprf (.clk(clk),
	  .reset(reset),
	  .rdptr0(fp_uq.srcA),
	  .rdptr1(fp_uq.srcB),
	  .rdptr2(t_picked_mem_uop.srcB),
	  .rdptr3(t_sd_src),
	  .rdptr4(fp_uq.srcC),
	  /* bank0 write port shared by fpu-arith result and single-cycle convert
	   * (mutually exclusive by r_fp_wb_bitvec) */
	  .wrptr0(w_fp_wb0_ptr),
	  .wrptr1(mem_rsp_dst_ptr),
	  .wen0(w_fdiv_complete | w_fpu_result_valid | r_cvt_valid),
	  .wen1(mem_rsp_dst_valid & mem_rsp_fp_dst),
	  .wr0(w_fp_wb0_data),
	  /* FR=0 lwc1 merge: splice the loaded 32 into the fp_hi half, keep fp_pres. */
	  .wr1(mem_rsp_fp_merge
	       ? (mem_rsp_fp_hi ? {mem_rsp_load_data[31:0], mem_rsp_fp_pres}
				: {mem_rsp_fp_pres, mem_rsp_load_data[31:0]})
	       : mem_rsp_load_data),
	  .rd0(w_fp_rawA),
	  .rd1(w_fp_rawB),
	  .rd2(r_fp_rd_srcB),
	  .rd3(r_fp_rd_dq),
	  .rd4(w_fp_srcC)
	  );

   
   always_comb
     begin
	n_prf_inflight = r_prf_inflight;
	n_fp_prf_inflight = r_fp_prf_inflight;


	if(uq_push && uq_uop.dst_valid)
	  begin
	     n_prf_inflight[uq_uop.dst] = 1'b1;
	  end
	if(uq_push && uq_uop.dst2_valid)
	  begin
	     n_prf_inflight[uq_uop.dst2] = 1'b1;
	  end
	if(uq_push_two && uq_uop_two.dst_valid)
	  begin
	     n_prf_inflight[uq_uop_two.dst] = 1'b1;
	  end
	/* FP dst allocation marks the FP physical reg inflight */
	if(uq_push && uq_uop.fp_dst_valid)
	  n_fp_prf_inflight[uq_uop.dst] = 1'b1;
	if(uq_push_two && uq_uop_two.fp_dst_valid)
	  n_fp_prf_inflight[uq_uop_two.dst] = 1'b1;

	if(mem_rsp_dst_valid)
	  begin
	     if(mem_rsp_fp_dst)
	       n_fp_prf_inflight[mem_rsp_dst_ptr] = 1'b0;
	     else
	       n_prf_inflight[mem_rsp_dst_ptr] = 1'b0;
	  end

	/* the unified divider's FP result clears its FP-dst inflight bit */
	if(w_fdiv_complete)
	  n_fp_prf_inflight[w_fdiv_dst_ptr] = 1'b0;
	/* FP arithmetic result clears the FP-dst inflight bit */
	if(w_fpu_result_valid)
	  n_fp_prf_inflight[w_fpu_dst_ptr] = 1'b0;
	/* single-cycle convert result clears its FP-dst inflight bit */
	if(r_cvt_valid)
	  n_fp_prf_inflight[r_cvt_dst] = 1'b0;
	if(t_iwb)
	  begin
	     n_prf_inflight[t_iwb_dst] = 1'b0;
	  end
     end // always_comb

   // =================================================================
   // FP execution pipe (mirrors mipscore: in-order FP UQ -> fpu -> port 2)
   // =================================================================
   localparam N_FP_UQ_ENTRIES   = (1<<`LG_FP_UQ_ENTRIES);
   localparam N_FCR_PRF_ENTRIES = (1<<`LG_FCR_PRF_ENTRIES);

   /* FP issue queue: a normal circular queue, issued strictly in-order (no
    * scheduler) -- exactly like mipscore.  Sources wake on r_fp_prf_inflight /
    * r_fcr_prf_inflight; the fpu is fixed-latency so FP completes 1/cycle on its
    * own ROB port (complete_bundle_2) with no shared writeback-bitvec. */
   uop_t r_fp_uq[N_FP_UQ_ENTRIES];
   uop_t fp_uq;
   logic t_fp_uq_empty, t_fp_uq_full, t_fp_uq_next_full;
   logic [`LG_FP_UQ_ENTRIES:0] r_fp_uq_head_ptr, n_fp_uq_head_ptr;
   logic [`LG_FP_UQ_ENTRIES:0] r_fp_uq_tail_ptr, n_fp_uq_tail_ptr;
   logic [`LG_FP_UQ_ENTRIES:0] r_fp_uq_next_tail_ptr, n_fp_uq_next_tail_ptr;
   logic t_push_one_fp, t_push_two_fp, t_pop_fp_uq;

   /* renamed FCR (FP condition-code byte) physical register file */
   logic [7:0] r_fcr_prf[N_FCR_PRF_ENTRIES-1:0];
   /* FP condition codes live ONLY here.  r_fcsr holds bits 23 and 31:25 at zero
    * and CFC1 ORs the renamed vector back in, so the two cannot drift apart --
    * which is how `ctc1 $t,$31; bc1t' came to read a stale condition code. */
   localparam [31:0] FCC_MASK = {7'h7f, 1'b0, 1'b1, 23'd0};
   function automatic logic [31:0] fcc_expand(input logic [7:0] cc);
      begin
	 fcc_expand = {cc[7:1], 1'b0, cc[0], 23'd0};
      end
   endfunction
   logic [N_FCR_PRF_ENTRIES-1:0] r_fcr_prf_inflight, n_fcr_prf_inflight;

   /* fpu outputs */
   wire [63:0] w_fpu_result;
   wire [4:0]  w_fpu_fflags;
   wire        w_fpu_denorm;
   wire        w_fpu_result_valid, w_fpu_fcr_valid;
   wire [`LG_PRF_ENTRIES-1:0]     w_fpu_dst_ptr;
   wire [`LG_FCR_PRF_ENTRIES-1:0] w_fpu_fcr_ptr;
   wire [`LG_ROB_ENTRIES-1:0]     w_fpu_rob_ptr;

   /* single-cycle FP convert (fpu_f2i / fpu_i2f) -- shares the bank0 write port +
    * complete_bundle_2 with the multi-cycle fpu, arbitrated by r_fp_wb_bitvec.
    * Latency from pop: convert = 2 (read stage + 1), fpu = FPU_LAT+1; reserve each
    * op's writeback slot at pop, gate the head on the matching slot. */
`ifdef ENABLE_MIPS4
   /* madd/msub/nmadd/nmsub: a mul pass then an add pass in fpu0 -> 2*FPU_LAT+1 from pop.
    * Its add pass re-enters fpu0's head FPU_LAT cycles after its own start, so that
    * start slot is reserved too (r_fp_st_bitvec, same dist conventions: an fpu op
    * popped now starts at dist 1, a madd's add pass at dist FPU_LAT+1). */
   localparam FP_WB_BITS = 2*`FPU_LAT + 2;
   localparam FP_ST_BITS = `FPU_LAT + 2;
   logic [FP_ST_BITS-1:0] r_fp_st_bitvec, n_fp_st_bitvec;
`else
   localparam FP_WB_BITS = `FPU_LAT + 2;
`endif
   logic [FP_WB_BITS-1:0] r_fp_wb_bitvec, n_fp_wb_bitvec;
   wire [63:0] w_f2i_out, w_i2f_out, w_f2f_out;
   wire [4:0]  w_f2i_fflags, w_i2f_fflags, w_f2f_fflags;
   wire        w_f2f_denorm;
   logic        r_cvt_valid;
   logic [`LG_PRF_ENTRIES-1:0] r_cvt_dst;
   logic [`LG_ROB_ENTRIES-1:0] r_cvt_rob;
   logic [63:0] r_cvt_result;
   logic [4:0]  r_cvt_fflags;
   logic        r_cvt_denorm;   /* CVT.S.D narrow underflow / denorm operand -> E-trap */
   /* head-op (fp_uq) and issue-op (r_fp_iss_uop) convert classification */
   wire w_head_is_cvt = (fp_uq.op == TRUNC_W_S) || (fp_uq.op == TRUNC_W_D) ||
			(fp_uq.op == CVT_S_W)   || (fp_uq.op == CVT_D_W)   ||
			(fp_uq.op == CVT_S_D)   || (fp_uq.op == CVT_D_S)   ||
			(fp_uq.op == CVT_W_S)   || (fp_uq.op == CVT_W_D)   ||
			(fp_uq.op == CVT_L_S)   || (fp_uq.op == CVT_L_D)   ||
			(fp_uq.op == CVT_S_L)   || (fp_uq.op == CVT_D_L);
   wire w_iss_is_f2f  = (r_fp_iss_uop.op == CVT_S_D)   || (r_fp_iss_uop.op == CVT_D_S);
   wire w_iss_is_f2i  = (r_fp_iss_uop.op == TRUNC_W_S) || (r_fp_iss_uop.op == TRUNC_W_D) ||
			(r_fp_iss_uop.op == CVT_W_S)   || (r_fp_iss_uop.op == CVT_W_D)   ||
			(r_fp_iss_uop.op == CVT_L_S)   || (r_fp_iss_uop.op == CVT_L_D);
   wire w_iss_is_i2f  = (r_fp_iss_uop.op == CVT_S_W)   || (r_fp_iss_uop.op == CVT_D_W)   ||
			(r_fp_iss_uop.op == CVT_S_L)   || (r_fp_iss_uop.op == CVT_D_L);
   wire w_iss_is_cvt  = w_iss_is_f2i | w_iss_is_i2f | w_iss_is_f2f;
   /* abs/neg/mov: single-cycle bit-twiddle, ride the same single-cycle path as
    * converts (bank0 writeback, complete at pop+2 via r_fp_wb_bitvec). */
   wire w_head_is_signop = (fp_uq.op == SP_ABS) || (fp_uq.op == DP_ABS) ||
			   (fp_uq.op == SP_NEG) || (fp_uq.op == DP_NEG) ||
			   (fp_uq.op == SP_MOV) || (fp_uq.op == DP_MOV);
   wire w_iss_is_signop  = (r_fp_iss_uop.op == SP_ABS) || (r_fp_iss_uop.op == DP_ABS) ||
			   (r_fp_iss_uop.op == SP_NEG) || (r_fp_iss_uop.op == DP_NEG) ||
			   (r_fp_iss_uop.op == SP_MOV) || (r_fp_iss_uop.op == DP_MOV);
`ifdef ENABLE_MIPS4
   wire w_head_is_fcmov = (fp_uq.op == FP_CMOV);
   wire w_iss_is_fcmov  = (r_fp_iss_uop.op == FP_CMOV);
`else
   wire w_head_is_fcmov = 1'b0;
   wire w_iss_is_fcmov  = 1'b0;
`endif
   /* convert, signop and the FP conditional moves are single-cycle (bitvec dist 2,
    * fpu bypassed) */
   wire w_head_is_sc = w_head_is_cvt | w_head_is_signop | w_head_is_fcmov;
`ifdef ENABLE_MIPS4
   /* recip/rsqrt run on the divider too (uni_divider: 1.0 / fs, and its two-pass rsqrt) */
   wire w_head_is_ds = (fp_uq.op == SP_DIV) || (fp_uq.op == DP_DIV) ||
		       (fp_uq.op == SP_SQRT) || (fp_uq.op == DP_SQRT) ||
		       (fp_uq.op == SP_RECIP) || (fp_uq.op == DP_RECIP) ||
		       (fp_uq.op == SP_RSQRT) || (fp_uq.op == DP_RSQRT);
   wire w_iss_is_ds  = (r_fp_iss_uop.op == SP_DIV) || (r_fp_iss_uop.op == DP_DIV) ||
		       (r_fp_iss_uop.op == SP_SQRT) || (r_fp_iss_uop.op == DP_SQRT) ||
		       (r_fp_iss_uop.op == SP_RECIP) || (r_fp_iss_uop.op == DP_RECIP) ||
		       (r_fp_iss_uop.op == SP_RSQRT) || (r_fp_iss_uop.op == DP_RSQRT);
   wire w_head_is_madd = (fp_uq.op == SP_MADD) || (fp_uq.op == DP_MADD) ||
			 (fp_uq.op == SP_MSUB) || (fp_uq.op == DP_MSUB) ||
			 (fp_uq.op == SP_NMADD) || (fp_uq.op == DP_NMADD) ||
			 (fp_uq.op == SP_NMSUB) || (fp_uq.op == DP_NMSUB);
`else
   wire w_head_is_ds = (fp_uq.op == SP_DIV) || (fp_uq.op == DP_DIV) ||
		       (fp_uq.op == SP_SQRT) || (fp_uq.op == DP_SQRT);
   wire w_iss_is_ds  = (r_fp_iss_uop.op == SP_DIV) || (r_fp_iss_uop.op == DP_DIV) ||
		       (r_fp_iss_uop.op == SP_SQRT) || (r_fp_iss_uop.op == DP_SQRT);
   wire w_head_is_madd = 1'b0;
`endif
   /* writeback distance from pop: convert 2, fpu FPU_LAT+1, madd 2*FPU_LAT+1 */
   localparam LG_FP_WB = $clog2(FP_WB_BITS);
   wire [LG_FP_WB-1:0] w_head_wb_dist = w_head_is_sc ? LG_FP_WB'(2) :
				       w_head_is_madd ? LG_FP_WB'(2*`FPU_LAT+1) : LG_FP_WB'(`FPU_LAT+1);
   wire w_iss_is_sc  = w_iss_is_cvt  | w_iss_is_signop | w_iss_is_fcmov;
   /* abs.* clears the sign, neg.* flips it, mov.* copies; single zero-extends low 32 */
   wire w_signop_dbl = (r_fp_iss_uop.op == DP_ABS) || (r_fp_iss_uop.op == DP_NEG) || (r_fp_iss_uop.op == DP_MOV);
   wire w_signop_abs = (r_fp_iss_uop.op == SP_ABS) || (r_fp_iss_uop.op == DP_ABS);
   wire w_signop_neg = (r_fp_iss_uop.op == SP_NEG) || (r_fp_iss_uop.op == DP_NEG);
   wire [63:0] w_signop_out = w_signop_dbl ?
       (w_signop_abs ? {1'b0,           w_fp_srcA[62:0]} :
        w_signop_neg ? {~w_fp_srcA[63], w_fp_srcA[62:0]} : w_fp_srcA) :
       {32'd0, (w_signop_abs ? {1'b0,           w_fp_srcA[30:0]} :
                w_signop_neg ? {~w_fp_srcA[31], w_fp_srcA[30:0]} : w_fp_srcA[31:0])};

   logic t_fpu_srcA_rdy, t_fpu_srcB_rdy, t_fpu_fcr_rdy, t_fpu_srcs_rdy;
   /* registered FP read/issue stage: the cycle after a head pops, the fp_regfile
    * presents its operands (w_fp_srcA/B) and these carry the issued uop's metadata,
    * so the fpu sees registered operands + metadata together (synchronous RF read
    * costs +1 FP issue latency; inflight gating keeps it correct, no bypass). */
   uop_t       r_fp_iss_uop;
   logic       r_fp_iss_valid;
   logic [7:0] r_fp_iss_fcr;

   /* SPARC FP registers are 64-bit pairs (decode_sparc.sv fidx): d[2k] is the
    * whole pair, f[2k] its high word, f[2k+1] its low word.  An operand's part
    * (decode's fsel, jmp_imm[2:1] for srcA, [4:3] for srcB) is picked here; a
    * single goes to the units low-justified, as they expect. */
   function automatic logic [63:0] fp_part(input logic [63:0] pair, input logic [1:0] sel);
      begin
	 fp_part = (sel == 2'd1) ? {32'd0, pair[31:0]} :
		   (sel == 2'd2) ? {32'd0, pair[63:32]} : pair;
      end
   endfunction // fp_part
   assign w_fp_srcA = fp_part(w_fp_rawA, r_fp_iss_uop.jmp_imm[2:1]);
   assign w_fp_srcB = fp_part(w_fp_rawB, r_fp_iss_uop.jmp_imm[4:3]);

   /* A single destination writes half its pair: at issue, keep the other half of
    * the old pair (srcC) by the destination register; the bank0 writeback (fpu,
    * divider or the single-cycle path, any latency) merges the result into it. */
   logic [N_INT_PRF_ENTRIES-1:0] r_fp_mrg_v;
   logic [N_INT_PRF_ENTRIES-1:0] r_fp_mrg_hi;
   logic [31:0] 	     r_fp_mrg_keep[N_INT_PRF_ENTRIES-1:0];
   always_ff@(posedge clk)
     begin
	if(r_fp_iss_valid)
	  begin
	     r_fp_mrg_v[r_fp_iss_uop.dst] <= r_fp_iss_uop.jmp_imm[5];
	     r_fp_mrg_hi[r_fp_iss_uop.dst] <= r_fp_iss_uop.jmp_imm[0];
	     r_fp_mrg_keep[r_fp_iss_uop.dst] <= r_fp_iss_uop.jmp_imm[0] ? w_fp_srcC[31:0] : w_fp_srcC[63:32];
	  end
     end // always_ff@ (posedge clk)
   wire [`LG_PRF_ENTRIES-1:0] w_fp_wb0_ptr = w_fdiv_complete ? w_fdiv_dst_ptr : w_fpu_result_valid ? w_fpu_dst_ptr : r_cvt_dst;
   wire [63:0] w_fp_wb0_res = w_fdiv_complete ? w_fdiv_y : w_fpu_result_valid ? w_fpu_result : r_cvt_result;
   wire [63:0] w_fp_wb0_data = !r_fp_mrg_v[w_fp_wb0_ptr] ? w_fp_wb0_res :
			       r_fp_mrg_hi[w_fp_wb0_ptr] ? {w_fp_wb0_res[31:0], r_fp_mrg_keep[w_fp_wb0_ptr]} :
			       {r_fp_mrg_keep[w_fp_wb0_ptr], w_fp_wb0_res[31:0]};

   // ---- FP UQ pointers / full-empty / push-pop bookkeeping ----
   always_comb
     begin
	n_fp_uq_head_ptr = r_fp_uq_head_ptr;
	n_fp_uq_tail_ptr = r_fp_uq_tail_ptr;
	n_fp_uq_next_tail_ptr = r_fp_uq_next_tail_ptr;
	t_fp_uq_empty = (r_fp_uq_head_ptr == r_fp_uq_tail_ptr);
	t_fp_uq_full = (r_fp_uq_head_ptr != r_fp_uq_tail_ptr) &&
		       (r_fp_uq_head_ptr[`LG_FP_UQ_ENTRIES-1:0] == r_fp_uq_tail_ptr[`LG_FP_UQ_ENTRIES-1:0]);
	t_fp_uq_next_full = (r_fp_uq_head_ptr != r_fp_uq_next_tail_ptr) &&
			    (r_fp_uq_head_ptr[`LG_FP_UQ_ENTRIES-1:0] == r_fp_uq_next_tail_ptr[`LG_FP_UQ_ENTRIES-1:0]);
	fp_uq = r_fp_uq[r_fp_uq_head_ptr[`LG_FP_UQ_ENTRIES-1:0]];

	t_push_two_fp = uq_push && uq_push_two && uq_uop.is_fp && uq_uop_two.is_fp;
	t_push_one_fp = ((uq_push && uq_uop.is_fp) || (uq_push_two && uq_uop_two.is_fp)) && !t_push_two_fp;

	if(t_push_two_fp)
	  begin
	     n_fp_uq_tail_ptr = r_fp_uq_tail_ptr + 'd2;
	     n_fp_uq_next_tail_ptr = r_fp_uq_next_tail_ptr + 'd2;
	  end
	else if((uq_push_two && uq_uop_two.is_fp) || (uq_push && uq_uop.is_fp))
	  begin
	     n_fp_uq_tail_ptr = r_fp_uq_tail_ptr + 'd1;
	     n_fp_uq_next_tail_ptr = r_fp_uq_next_tail_ptr + 'd1;
	  end
	if(t_pop_fp_uq)
	  n_fp_uq_head_ptr = r_fp_uq_head_ptr + 'd1;
     end

   always_ff@(posedge clk)
     begin
	if(reset || t_flash_clear)
	  begin
	     r_fp_uq_head_ptr <= 'd0;
	     r_fp_uq_tail_ptr <= 'd0;
	     r_fp_uq_next_tail_ptr <= 'd1;
	  end
	else
	  begin
	     r_fp_uq_head_ptr <= n_fp_uq_head_ptr;
	     r_fp_uq_tail_ptr <= n_fp_uq_tail_ptr;
	     r_fp_uq_next_tail_ptr <= n_fp_uq_next_tail_ptr;
	  end
     end
   always_ff@(posedge clk)
     begin
	if(t_push_two_fp)
	  begin
	     r_fp_uq[r_fp_uq_tail_ptr[`LG_FP_UQ_ENTRIES-1:0]] <= uq_uop;
	     r_fp_uq[r_fp_uq_next_tail_ptr[`LG_FP_UQ_ENTRIES-1:0]] <= uq_uop_two;
	  end
	else if(t_push_one_fp)
	  r_fp_uq[r_fp_uq_tail_ptr[`LG_FP_UQ_ENTRIES-1:0]] <= uq_uop.is_fp ? uq_uop : uq_uop_two;
     end

   // ---- in-order issue: wake on source inflight bits, pop when ready ----
   always_comb
     begin
	t_fpu_srcA_rdy = fp_uq.fp_srcA_valid ? !r_fp_prf_inflight[fp_uq.srcA] : 1'b1;
	t_fpu_srcB_rdy = fp_uq.fp_srcB_valid ? !r_fp_prf_inflight[fp_uq.srcB] : 1'b1;
	t_fpu_fcr_rdy  = fp_uq.fcr_src_valid ? !r_fcr_prf_inflight[fp_uq.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]] : 1'b1;
	t_fpu_srcs_rdy = t_fpu_srcA_rdy && t_fpu_srcB_rdy && t_fpu_fcr_rdy;
	/* a single destination's old pair (and madd's fr) */
	if(fp_uq.fp_srcC_valid && r_fp_prf_inflight[fp_uq.srcC])
	  begin
	     t_fpu_srcs_rdy = 1'b0;
	  end
`ifdef ENABLE_MIPS4
	/* movz/movn.fmt: GPR rt (srcC) must be written, so its zero flag is valid */
	if(fp_uq.srcC_valid && r_prf_inflight[fp_uq.srcC])
	  begin
	     t_fpu_srcs_rdy = 1'b0;
	  end
`endif
	/* writeback slot for the head op (convert=2, fpu arith/compare=FPU_LAT+1 from pop)
	 * must be free, else stall a cycle (mixed-latency shared FP writeback port). */
	/* div.s/div.d/sqrt.s/sqrt.d run on the unified divider (d0), not fpu0.
	 * Variable latency, one op in flight, shared with the INTEGER divides: the
	 * head pops only when d0 is free (w_fdiv_ready), starts from the issue stage
	 * the next cycle, and drains into the FP writeback port / complete_bundle_2
	 * in the first cycle neither fpu0 nor the convert path is using them -- so it
	 * takes no r_fp_wb_bitvec reservation. */
	t_pop_fp_uq = !t_fp_uq_empty && !t_flash_clear && t_fpu_srcs_rdy &&
		      (w_head_is_ds ? w_fdiv_ready
				    : !r_fp_wb_bitvec[w_head_wb_dist]);
`ifdef ENABLE_MIPS4
	/* an fpu op (not convert/signop/cmov, not divider) starts fpu0 next cycle: not in
	 * the slot a madd's add pass has reserved */
	if(!w_head_is_sc && !w_head_is_ds && r_fp_st_bitvec[1])
	  begin
	     t_pop_fp_uq = 1'b0;
	  end
`endif
	t_fdiv_pop     = t_pop_fp_uq & w_head_is_ds;
	t_fdiv_start   = r_fp_iss_valid & w_iss_is_ds;
	t_fdiv_wb_used = w_fpu_result_valid | w_fpu_fcr_valid | r_cvt_valid;
     end

   /* FP writeback reservation: shift down each cycle; on pop, reserve dist-1 (next-cycle
    * frame). gate above reads [dist]. arith/compare fpu dist=FPU_LAT+1, convert dist=2. */
   always_comb
     begin
	integer i;
	for(i = 0; i < FP_WB_BITS-1; i = i + 1)
	  n_fp_wb_bitvec[i] = r_fp_wb_bitvec[i+1];
	n_fp_wb_bitvec[FP_WB_BITS-1] = 1'b0;
	if(t_pop_fp_uq)
	  n_fp_wb_bitvec[w_head_wb_dist - LG_FP_WB'(1)] = 1'b1;
     end
`ifdef ENABLE_MIPS4
   always_comb
     begin
	integer i;
	for(i = 0; i < FP_ST_BITS-1; i = i + 1)
	  begin
	     n_fp_st_bitvec[i] = r_fp_st_bitvec[i+1];
	  end
	n_fp_st_bitvec[FP_ST_BITS-1] = 1'b0;
	if(t_pop_fp_uq && w_head_is_madd)
	  begin
	     n_fp_st_bitvec[`FPU_LAT] = 1'b1;
	  end
     end
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_fp_st_bitvec <= 'd0;
	  end
	else
	  begin
	     r_fp_st_bitvec <= n_fp_st_bitvec;
	  end
     end
`endif
   always_ff@(posedge clk)
     begin
	/* NOT flushed on t_flash_clear: an FP op already in the pipeline (popped from
	 * fp_uq) must run to completion so it clears its r_rob_inflight bit -- otherwise
	 * EXCEPTION_DRAIN (which waits for r_rob_inflight==0 with flash_clear held high
	 * the whole drain) deadlocks.  Matches mipscore (fq_wait drops the *waiting* ops;
	 * the in-flight pipe drains naturally).  fpu0's internal pipe likewise only resets. */
	if(reset)
	  r_fp_wb_bitvec <= 'd0;
	else
	  r_fp_wb_bitvec <= n_fp_wb_bitvec;
     end

   /* FP read/issue stage register: aligns with the fp_regfile rd0/rd1 latency.
    * NOT flushed on t_flash_clear -- a just-popped op must reach fpu0 and complete
    * so its r_rob_inflight clears (see r_fp_wb_bitvec note).  t_pop_fp_uq is gated by
    * !t_flash_clear, so no NEW op enters; this only lets the one caught op proceed. */
   always_ff@(posedge clk)
     begin
	if(reset)
	  r_fp_iss_valid <= 1'b0;
	else
	  r_fp_iss_valid <= t_pop_fp_uq;
     end
   always_ff@(posedge clk)
     begin
	r_fp_iss_uop <= fp_uq;
	r_fp_iss_fcr <= r_fcr_prf[fp_uq.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]];
     end
`ifdef ENABLE_MIPS4
   /* movz/movn.fmt condition: rt's zero flag, read with the FCC at issue */
   logic r_fp_iss_zero;
   always_ff@(posedge clk)
     begin
	r_fp_iss_zero <= r_prf_zero[fp_uq.srcC];
     end
   /* whole 64-bit register either way (the old fd is srcB): .s keeps fd's upper half */
   wire w_fcmov_cond = (r_fp_iss_uop.imm[5:4] == 2'd0) ? (r_fp_iss_fcr[r_fp_iss_uop.imm[2:0]] == r_fp_iss_uop.imm[3]) :
		       (r_fp_iss_uop.imm[5:4] == 2'd2) ? !r_fp_iss_zero : r_fp_iss_zero;
   wire [63:0] w_fcmov_out = w_fcmov_cond ? w_fp_srcA : w_fp_srcB;
`else
   wire [63:0] w_fcmov_out = 64'd0;
`endif

   fpu #(.LG_PRF_WIDTH(`LG_PRF_ENTRIES),
	 .LG_ROB_WIDTH(`LG_ROB_ENTRIES),
	 .LG_FCR_WIDTH(`LG_FCR_PRF_ENTRIES),
	 .FPU_LAT(`FPU_LAT))
   fpu0(
	.clk(clk),
	.reset(reset),
	.pc(64'(r_fp_iss_uop.pc)),
	.opcode(r_fp_iss_uop.op),
	.start(r_fp_iss_valid & ~w_iss_is_sc & ~w_iss_is_ds),   /* converts + sign-ops bypass the fpu (single-cycle path); div/sqrt -> d0 */
	.src_a(w_fp_srcA),
	.src_b(w_fp_srcB),
`ifdef ENABLE_MIPS4
	.src_c(w_fp_srcC),          /* madd fr */
`else
	.src_c({`FP_WIDTH{1'b0}}),
`endif
	.src_fcr(r_fp_iss_fcr),
	.rm(w_fsr_rd),   /* FCSR.RM; CTC1 serializes so this is stable per FP op */
	.rob_ptr_in(r_fp_iss_uop.rob_ptr),
	.dst_ptr_in(r_fp_iss_uop.dst),
	.fcr_ptr_in(r_fp_iss_uop.hilo_dst[`LG_FCR_PRF_ENTRIES-1:0]),
	.fcr_sel(r_fp_iss_uop.imm[2:0]),
	.cmp_cond(r_fp_iss_uop.imm[6:3]),   /* C.cond predicate */
	.val(w_fpu_result_valid),
	.cmp_val(w_fpu_fcr_valid),
	.y(w_fpu_result),
	.fflags(w_fpu_fflags),
	.denorm(w_fpu_denorm),
	.rob_ptr_out(w_fpu_rob_ptr),
	.dst_ptr_out(w_fpu_dst_ptr),
	.fcr_ptr_out(w_fpu_fcr_ptr)
	);

   /* single-cycle FP convert: combinational on the issue-stage operand (w_fp_srcA),
    * result registered one cycle -> writes bank0 / completes at pop+2.  TRUNC.W = RZ;
    * CVT.S.W/CVT.D.W use FCSR.RM.  fmt: source-double for f2i, dest-double for i2f. */
   /* TRUNC.W -> RZ; ROUND/CEIL/FLOOR.W -> fixed rm in imm[1:0]; CVT.W -> FCSR.RM
    * (imm[2]).  fmt = source-double (TRUNC_W_D / CVT_W_D). */
   wire w_f2i_src_d = (r_fp_iss_uop.op == TRUNC_W_D) || (r_fp_iss_uop.op == CVT_W_D) ||
		      (r_fp_iss_uop.op == CVT_L_D);
   wire w_f2i_dst_l = (r_fp_iss_uop.op == CVT_L_S) || (r_fp_iss_uop.op == CVT_L_D);
   wire [1:0] w_f2i_rm = ((r_fp_iss_uop.op == TRUNC_W_S) || (r_fp_iss_uop.op == TRUNC_W_D)) ? 2'b01
			 : r_fp_iss_uop.imm[2] ? w_fsr_rd
			 : r_fp_iss_uop.imm[1:0];
   fpu_f2i f2i0(.in(w_fp_srcA),
		.fmt(w_f2i_src_d),
		.dst_long(w_f2i_dst_l),
		.rm(w_f2i_rm),
		.out(w_f2i_out), .fflags(w_f2i_fflags));
   fpu_i2f i2f0(.in(w_fp_srcA),
		.src_long((r_fp_iss_uop.op == CVT_S_L) || (r_fp_iss_uop.op == CVT_D_L)),
		.fmt((r_fp_iss_uop.op == CVT_D_W) || (r_fp_iss_uop.op == CVT_D_L)),
		.rm(w_fsr_rd),
		.out(w_i2f_out), .fflags(w_i2f_fflags));
   /* FP<->FP convert: CVT.D.S widens (to_double=1, exact); CVT.S.D narrows (rounds
    * per FCSR.RM, E-trap via denorm on underflow / denorm operand). */
   fpu_f2f f2f0(.in(w_fp_srcA),
		.to_double(r_fp_iss_uop.op == CVT_D_S),
		.rm(w_fsr_rd),
		.out(w_f2f_out), .denorm(w_f2f_denorm), .fflags(w_f2f_fflags));
   always_ff@(posedge clk)
     begin
	/* NOT flushed on t_flash_clear: the single-cycle convert in flight must complete
	 * so its r_rob_inflight clears (see r_fp_wb_bitvec note). */
	if(reset)
	  r_cvt_valid <= 1'b0;
	else
	  r_cvt_valid <= r_fp_iss_valid & w_iss_is_sc;
     end
   always_ff@(posedge clk)
     begin
	r_cvt_result <= w_iss_is_fcmov  ? w_fcmov_out :
			w_iss_is_signop ? w_signop_out :
			w_iss_is_f2f    ? w_f2f_out :
			w_iss_is_f2i    ? w_f2i_out : w_i2f_out;
	r_cvt_fflags <= (w_iss_is_signop | w_iss_is_fcmov) ? 5'd0 :
			w_iss_is_f2f    ? w_f2f_fflags :
			w_iss_is_f2i    ? w_f2i_fflags : w_i2f_fflags;
	r_cvt_denorm <= w_iss_is_f2f ? w_f2f_denorm : 1'b0;
	r_cvt_dst    <= r_fp_iss_uop.dst;
	r_cvt_rob    <= r_fp_iss_uop.rob_ptr;
     end

   /* FP exception: the single FP completion this cycle (fpu OR convert -- bitvec
    * mutually-exclusive) carries {denorm, fflags}.  An op FAULTS (R4000 FPE,
    * ExcCode 15) iff denorm (Unimplemented E, always) OR an enabled IEEE flag
    * (fflags & FCSR.Enable[11:7]).  Routed via complete_bundle_2.faulted -> the
    * ROB is_fpe bit -> ARCH_FAULT.  (convert raises no denorm.) */
   wire [4:0] w_fp_cmpl_fflags = w_fdiv_complete ? w_fdiv_fflags : (w_fpu_result_valid | w_fpu_fcr_valid) ? w_fpu_fflags : r_cvt_fflags;
   wire       w_fp_cmpl_denorm = w_fdiv_complete ? w_fdiv_denorm : (w_fpu_result_valid | w_fpu_fcr_valid) ? w_fpu_denorm : r_cvt_denorm;
   wire       w_fp_fault = w_fp_cmpl_denorm | (|(w_fp_cmpl_fflags & w_fsr_tem));

   // ---- FCR PRF: inflight tracking + write ----
   always_comb
     begin
	n_fcr_prf_inflight = r_fcr_prf_inflight;
	if(uq_push && uq_uop.fcr_dst_valid)
	  n_fcr_prf_inflight[uq_uop.hilo_dst[`LG_FCR_PRF_ENTRIES-1:0]] = 1'b1;
	if(uq_push_two && uq_uop_two.fcr_dst_valid)
	  n_fcr_prf_inflight[uq_uop_two.hilo_dst[`LG_FCR_PRF_ENTRIES-1:0]] = 1'b1;
	if(w_fpu_fcr_valid)
	  n_fcr_prf_inflight[w_fpu_fcr_ptr] = 1'b0;
	/* CTC1 produces an FCR value from the INT pipe and must clear its own
	 * inflight bit, or every later FCR reader waits for an FP completion
	 * that never comes. */
	if(r_start_int & t_wr_fcsr)
	  n_fcr_prf_inflight[int_uop.hilo_dst[`LG_FCR_PRF_ENTRIES-1:0]] = 1'b0;
	if(t_ldfsr_wr)
	  n_fcr_prf_inflight[r_ldfsr_fcr] = 1'b0;
     end
   always_ff@(posedge clk)
     begin
	if(reset || t_flash_clear)
	  r_fcr_prf_inflight <= 'd0;
	else
	  r_fcr_prf_inflight <= ds_done ? 'd0 : n_fcr_prf_inflight;
     end
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(integer i = 0; i < N_FCR_PRF_ENTRIES; i = i + 1)
	       r_fcr_prf[i] <= 8'd0;
	  end
	else if(w_fpu_fcr_valid)
	  r_fcr_prf[w_fpu_fcr_ptr] <= w_fpu_result[7:0];
	else if(r_start_int & t_wr_fcsr)
	  r_fcr_prf[int_uop.hilo_dst[`LG_FCR_PRF_ENTRIES-1:0]] <= {t_srcA[31:25], t_srcA[23]};
	else if(t_ldfsr_wr)
	  r_fcr_prf[r_ldfsr_fcr] <= {6'd0, mem_rsp_load_data[11:10]};
     end

   // ---- FP completion -> ROB port 2 ----
   always_ff@(posedge clk)
     begin
	if(reset)
	  complete_valid_2 <= 1'b0;
	else
	  /* NOT gated by !ds_done: an in-flight FP op must be allowed to COMPLETE during
	   * EXCEPTION_DRAIN (ds_done held high the whole drain) so it clears its
	   * r_rob_inflight bit -- otherwise the drain's r_rob_inflight==0 exit never fires
	   * and the machine deadlocks.  Matches mipscore (FP complete has no ds_done gate). */
	  complete_valid_2 <= (w_fpu_result_valid || w_fpu_fcr_valid || r_cvt_valid || w_fdiv_complete);
     end
   always_ff@(posedge clk)
     begin
	/* port-2 source mux: fpu arith/compare, else the single-cycle convert.
	 * r_fp_wb_bitvec guarantees these never assert in the same cycle. */
	complete_bundle_2.rob_ptr <= w_fdiv_complete ? w_fdiv_rob_ptr : (w_fpu_result_valid || w_fpu_fcr_valid) ? w_fpu_rob_ptr : r_cvt_rob;
	complete_bundle_2.complete <= 1'b1;
	complete_bundle_2.faulted <= w_fp_fault;   /* FP exception (denorm/enabled IEEE) -> is_fpe -> ExcCode 15 */
	complete_bundle_2.restart_pc <= 'd0;
	complete_bundle_2.is_ii <= 1'b0;
	complete_bundle_2.take_br <= 1'b0;
	complete_bundle_2.overflow <= 1'b0;
	complete_bundle_2.trap <= 1'b0;
	complete_bundle_2.fp_flags <= {w_fp_cmpl_denorm, w_fp_cmpl_fflags};
	complete_bundle_2.data <= w_fdiv_complete ? w_fdiv_y : (w_fpu_result_valid || w_fpu_fcr_valid) ? w_fpu_result : r_cvt_result;
	complete_bundle_2.fwd_sel <= 2'b00;   /* FP/convert port: no int srcA mux */
	complete_bundle_2.fwd_selB <= 2'b00;
	complete_bundle_2.srcB_val <= 32'd0;
	complete_bundle_2.hi_nzA <= 1'b0;
	complete_bundle_2.hi_nzB <= 1'b0;
     end

   always_comb
     begin
	n_hilo_inflight = r_hilo_inflight;
	if(uq_push && uq_uop.hilo_dst_valid)
	  begin
	     n_hilo_inflight[uq_uop.hilo_dst] = 1'b1;
	  end
	
	if(uq_push_two && uq_uop_two.hilo_dst_valid)
	  begin
	     n_hilo_inflight[uq_uop_two.hilo_dst] = 1'b1;
	  end
	
	if(t_hilo_prf_ptr_val_out)
	  begin
	     n_hilo_inflight[t_hilo_prf_ptr_out] = 1'b0;
	  end
	if(r_start_int && t_wr_hilo)
	  begin
	     n_hilo_inflight[int_uop.hilo_dst] = 1'b0;
	  end

     end // always_comb

   

   
`ifdef VERILATOR
   logic t_blocked_by_store;
   always_comb
     begin
	t_blocked_by_store = t_mem_uq_empty ? 1'b0 : !t_pop_mem_uq  & is_store(mem_uq.op) & 
			     !r_prf_inflight[mem_uq.srcA] &
			     !mem_q_full;
     end
   always_ff@(negedge clk)
     begin
	report_exec(t_uq_empty ? 32'd0 : 32'd1,
		    t_pop_uq ? 32'd1 : 32'd0,
		    t_mem_uq_empty ? 32'd0 : 32'd1,
		    t_pop_mem_uq ? 32'd1 : 32'd0,
		    32'd1,
		    32'd0,
		    t_uq_full ? 32'd1 : 32'd0,
		    t_mem_uq_full ? 32'd1 : 32'd0,
		    32'd0,
		    t_blocked_by_store ? 32'd1 : 32'd0,
		    {{(32-N_INT_SCHED_ENTRIES){1'b0}}, t_alu_entry_rdy}
		    );
     end
`endif //  `ifdef VERILATOR

   /* ---- SPARC integer datapath (the S_* ops, uop.vh) ---- */
   /* operand 2: rs2, or the sign-extended immediate in {jmp_imm[15:0], imm} */
   assign w_s_op2 = int_uop.srcB_valid ? t_srcB[31:0] : {int_uop.jmp_imm[15:0], int_uop.imm};
   /* the incoming icc: srcC is the flags register (flags_src_valid) */
   wire [3:0]  w_s_icc = r_prf_icc[int_uop.srcC];
   wire        w_s_cin = int_uop.flags_src_valid & w_s_icc[0] &
			 ((int_uop.op == S_ADDX) | (int_uop.op == S_ADDXCC) |
			  (int_uop.op == S_SUBX) | (int_uop.op == S_SUBXCC));
   wire [32:0] w_s_add = {1'b0, t_srcA[31:0]} + {1'b0, w_s_op2} + {32'd0, w_s_cin};
   wire [32:0] w_s_sub = {1'b0, t_srcA[31:0]} - {1'b0, w_s_op2} - {32'd0, w_s_cin};
   wire        w_s_add_v = (t_srcA[31] == w_s_op2[31]) & (w_s_add[31] != t_srcA[31]);
   wire        w_s_sub_v = (t_srcA[31] != w_s_op2[31]) & (w_s_sub[31] != t_srcA[31]);
   wire        w_s_tag = (t_srcA[1:0] != 2'd0) | (w_s_op2[1:0] != 2'd0);
   /* mulscc: {N ^ V, rs1 >> 1} + (Y[0] ? operand 2 : 0) */
   wire [31:0] w_s_ms_a = {w_s_icc[3] ^ w_s_icc[1], t_srcA[31:1]};
   wire [31:0] w_s_ms_b = t_src_hilo[0] ? w_s_op2 : 32'd0;
   wire [32:0] w_s_ms = {1'b0, w_s_ms_a} + {1'b0, w_s_ms_b};
   wire        w_s_ms_v = (w_s_ms_a[31] == w_s_ms_b[31]) & (w_s_ms[31] != w_s_ms_a[31]);
   wire [31:0] w_s_logic = ((int_uop.op == S_AND) | (int_uop.op == S_ANDCC)) ? (t_srcA[31:0] & w_s_op2) :
			   ((int_uop.op == S_ANDN) | (int_uop.op == S_ANDNCC)) ? (t_srcA[31:0] & ~w_s_op2) :
			   ((int_uop.op == S_OR) | (int_uop.op == S_ORCC)) ? (t_srcA[31:0] | w_s_op2) :
			   ((int_uop.op == S_ORN) | (int_uop.op == S_ORNCC)) ? (t_srcA[31:0] | ~w_s_op2) :
			   ((int_uop.op == S_XOR) | (int_uop.op == S_XORCC)) ? (t_srcA[31:0] ^ w_s_op2) :
			   (t_srcA[31:0] ^ ~w_s_op2);
   wire [31:0] w_s_branch_target = int_uop.pc[31:0] + {int_uop.jmp_imm[15:0], int_uop.imm};
   wire [31:0] w_s_pc8 = int_uop.pc[31:0] + 32'd8;

   /* Bicc / Ticc condition on {N, Z, V, C} (interpret.cc eval_icc) */
   function automatic logic eval_icc(input logic [3:0] c, input logic [3:0] icc);
      logic r;
      begin
	 r = (c[2:0] == 3'd1) ? icc[2] :
	     (c[2:0] == 3'd2) ? (icc[2] | (icc[3] ^ icc[1])) :
	     (c[2:0] == 3'd3) ? (icc[3] ^ icc[1]) :
	     (c[2:0] == 3'd4) ? (icc[0] | icc[2]) :
	     (c[2:0] == 3'd5) ? icc[0] :
	     (c[2:0] == 3'd6) ? icc[3] :
	     (c[2:0] == 3'd7) ? icc[1] :
	     1'b0;
	 eval_icc = c[3] ? !r : r;
      end
   endfunction // eval_icc

   /* FBfcc: c's taken set over fcc (0 =, 1 <, 2 >, 3 unordered), as a mask */
   function automatic logic eval_fcc(input logic [3:0] c, input logic [1:0] fcc);
      logic [3:0] m;
      begin
	 case(c)
	   4'd1: m = 4'b1110;   /* fbne   */
	   4'd2: m = 4'b0110;   /* fblg   */
	   4'd3: m = 4'b1010;   /* fbul   */
	   4'd4: m = 4'b0010;   /* fbl    */
	   4'd5: m = 4'b1100;   /* fbug   */
	   4'd6: m = 4'b0100;   /* fbg    */
	   4'd7: m = 4'b1000;   /* fbu    */
	   4'd8: m = 4'b1111;   /* fba    */
	   4'd9: m = 4'b0001;   /* fbe    */
	   4'd10: m = 4'b1001;  /* fbue   */
	   4'd11: m = 4'b0101;  /* fbge   */
	   4'd12: m = 4'b1101;  /* fbuge  */
	   4'd13: m = 4'b0011;  /* fble   */
	   4'd14: m = 4'b1011;  /* fbule  */
	   4'd15: m = 4'b0111;  /* fbo    */
	   default: m = 4'b0000; /* fbn  */
	 endcase // case (c)
	 eval_fcc = m[fcc];
      end
   endfunction // eval_fcc

   
   always_comb
     begin
	t_pc = int_uop.pc + zero_extend32(32'd4);  /* default restart = pc+4 */
	t_pc4 = int_uop.pc + zero_extend32(32'd4);
	t_pc8 = int_uop.pc + zero_extend32(32'd8);
	t_result = zero_extend32(32'd0);
	t_unimp_op = 1'b0;
	t_fault = 1'b0;
	t_simm = {{E_BITS{int_uop.imm[15]}},int_uop.imm};
	t_wr_int_prf = 1'b0;
	t_wr_fcsr = 1'b0;
	t_take_br = 1'b0;
	t_mispred_br = 1'b0;
	t_jaddr = {int_uop.jmp_imm[9:0],int_uop.imm,2'd0};
	t_alu_valid = 1'b0;
	t_hilo_result = 'd0;
	t_wr_hilo = 1'b0;
	t_start_mul = 1'b0;
	t_signed_div = 1'b0;
	t_start_div = 1'b0;	
	t_overflow = 1'b0;
	t_trap = 1'b0;
	t_icc_out = 4'd0;
	
	case(int_uop.op)
	  /* Overflow-check forms: raise the trap, write NOTHING.  Deliberately no
	   * t_result and no t_wr_int_prf -- that is the whole point, see uop.vh. */
`ifdef ENABLE_MIPS4
	  MOVCI:
	    begin
	       /* movt (imm[0]=1) / movf (imm[0]=0): the FCC bit BC1x reads */
	       t_result = (r_fcr_prf[int_uop.hilo_src][int_uop.srcC[2:0]] == int_uop.imm[0]) ? t_srcA : t_srcB;
	       t_wr_int_prf = 1'b1;
	       t_alu_valid = 1'b1;
	    end // case: MOVCI
`endif
	  /* Zero-compare branches: the compare is against a LITERAL zero, so these
	   * never read $zero through the PRF or the forwarding network.  Direction
	   * and target maths are copied verbatim from BEQ/BNE above so semantics
	   * cannot drift; only the operand source differs. */
	  BC1T:
	    begin
	       t_take_br = r_fcr_prf[int_uop.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]][int_uop.srcC[2:0]];
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BC1F:
	    begin
	       t_take_br = ~r_fcr_prf[int_uop.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]][int_uop.srcC[2:0]];
	       t_mispred_br = int_uop.br_pred != t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BC1TL:
	    begin
	       t_take_br = r_fcr_prf[int_uop.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]][int_uop.srcC[2:0]];
	       t_mispred_br = int_uop.br_pred != t_take_br || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  BC1FL:
	    begin
	       t_take_br = ~r_fcr_prf[int_uop.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]][int_uop.srcC[2:0]];
	       t_mispred_br = int_uop.br_pred != t_take_br || !t_take_br;
	       t_pc = t_take_br ? (t_pc4 + {t_simm[`M_WIDTH-3:0], 2'd0}) : t_pc8;
	       t_alu_valid = 1'b1;
	    end
	  // J:
	  //   begin
	  //      t_take_br = 1'b1;
	  //      t_mispred_br = int_uop.br_pred != t_take_br;
	  //      t_pc = {t_pc4[`M_WIDTH-1:28],t_jaddr};
	  //      t_alu_valid = 1'b1;
	  //      t_srcs_rdy = 1'b1;	       
	  //   end
	  CFC1:
	    begin
	       /* fs in srcA[4:0]: FCR0=FIR (read-only R4000 id), FCR31=FCSR */
	       t_result = (int_uop.srcA[4:0] == 5'd0) ?
			  sign_extend32(`FIR_VALUE) : /* FIR (machine.vh) */
			  sign_extend32(r_fcsr | fcc_expand(r_fcr_prf[int_uop.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]]));
	       t_alu_valid = 1'b1;
	       t_wr_int_prf = 1'b1;
	    end
	  CTC1:
	    begin
	       /* only FCR31 (FCSR) is writable; fs in dst */
	       t_wr_fcsr = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  /* traps: B operand is the register (srcB) or, for the immediate forms
	   * (srcB_valid=0), the sign-extended immediate. */
	  /* zero-compare traps: compare against a LITERAL 0, no $zero read */
	  II:
	    begin
	       t_unimp_op = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  XFLUSH, XPG_WBINV, XPG_INV:
	    begin
	       /* injected ARM flush: nothing to compute (the core holds the page) */
	       t_alu_valid = 1'b1;
	    end
	  /* ---- SPARC V8 ---- */
	  S_TADDCCTV:
	    begin
	       /* tag_overflow (tt 0x0a) instead of any write */
	       t_trap = w_s_add_v | w_s_tag;
	       t_fault = t_trap;
	       t_result = t_trap ? `M_WIDTH'(8'h0a) : `M_WIDTH'(w_s_add[31:0]);
	       t_icc_out = {w_s_add[31], (w_s_add[31:0] == 32'd0), 1'b0, w_s_add[32]};
	       t_wr_int_prf = int_uop.dst_valid & !t_trap;
	       t_alu_valid = 1'b1;
	    end
	  S_TSUBCCTV:
	    begin
	       t_trap = w_s_sub_v | w_s_tag;
	       t_fault = t_trap;
	       t_result = t_trap ? `M_WIDTH'(8'h0a) : `M_WIDTH'(w_s_sub[31:0]);
	       t_icc_out = {w_s_sub[31], (w_s_sub[31:0] == 32'd0), 1'b0, w_s_sub[32]};
	       t_wr_int_prf = int_uop.dst_valid & !t_trap;
	       t_alu_valid = 1'b1;
	    end
	  S_UMUL, S_SMUL, S_UMULCC, S_SMULCC:
	    begin
	       /* rd (+ icc) and Y at the multiplier's completion (t_iwb, the HILO port) */
	       t_start_mul = r_start_int&!ds_done;
	    end
	  S_UDIV, S_SDIV, S_UDIVCC, S_SDIVCC:
	    begin
	       /* {Y, rs1} / operand 2 in uni_divider, rd (+ icc) at its completion;
		* a zero divisor is division_by_zero (tt 0x2a) instead */
	       t_trap = (w_s_op2 == 32'd0);
	       t_fault = t_trap;
	       t_result = `M_WIDTH'(8'h2a);
	       t_alu_valid = t_trap;
	       t_signed_div = (int_uop.op == S_SDIV) | (int_uop.op == S_SDIVCC);
	       t_start_div = r_start_int & !ds_done & !t_trap;
	    end
	  S_MULSCC:
	    begin
	       t_result = `M_WIDTH'(w_s_ms[31:0]);
	       t_icc_out = {w_s_ms[31], (w_s_ms[31:0] == 32'd0), w_s_ms_v, w_s_ms[32]};
	       t_wr_int_prf = int_uop.dst_valid;
	       t_hilo_result = {t_srcA[0], t_src_hilo[31:1]};
	       t_wr_hilo = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  S_TICC:
	    begin
	       /* trap_instruction: tt 0x80 + ((rs1 + op2) & 0x7f), the trap type in
		* the result (core.sv ARCH_FAULT reads it from the ROB) */
	       t_trap = (int_uop.cond == 4'd8) | eval_icc(int_uop.cond, w_s_icc);
	       t_fault = t_trap;
	       t_result = `M_WIDTH'({1'b1, w_s_add[6:0]});
	       t_alu_valid = 1'b1;
	    end
	  S_ADD, S_ADDX, S_ADDCC, S_ADDXCC, S_TADDCC:
	    begin
	       t_result = `M_WIDTH'(w_s_add[31:0]);
	       t_icc_out = {w_s_add[31], (w_s_add[31:0] == 32'd0),
			    (int_uop.op == S_TADDCC) ? (w_s_add_v | w_s_tag) : w_s_add_v, w_s_add[32]};
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_SUB, S_SUBX, S_SUBCC, S_SUBXCC, S_TSUBCC:
	    begin
	       t_result = `M_WIDTH'(w_s_sub[31:0]);
	       t_icc_out = {w_s_sub[31], (w_s_sub[31:0] == 32'd0),
			    (int_uop.op == S_TSUBCC) ? (w_s_sub_v | w_s_tag) : w_s_sub_v, w_s_sub[32]};
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_AND, S_ANDCC, S_ANDN, S_ANDNCC, S_OR, S_ORCC, S_ORN, S_ORNCC,
	  S_XOR, S_XORCC, S_XNOR, S_XNORCC:
	    begin
	       t_result = `M_WIDTH'(w_s_logic);
	       t_icc_out = {w_s_logic[31], (w_s_logic == 32'd0), 2'b00};
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_SLL:
	    begin
	       t_result = `M_WIDTH'(t_srcA[31:0] << w_s_op2[4:0]);
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_SRL:
	    begin
	       t_result = `M_WIDTH'(t_srcA[31:0] >> w_s_op2[4:0]);
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_SRA:
	    begin
	       t_result = `M_WIDTH'($signed(t_srcA[31:0]) >>> w_s_op2[4:0]);
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_SETHI, TRAP_L1, TRAP_L2:
	    begin
	       t_result = `M_WIDTH'({int_uop.jmp_imm[15:0], int_uop.imm});
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_SAVE, S_RESTORE:
	    begin
	       /* rs1 + operand 2 in the old window, into rd in the new one (decode
		* already named rd in the new window and checked WIM) */
	       t_result = `M_WIDTH'(w_s_add[31:0]);
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_BICC:
	    begin
	       /* cond ba with no slot (ba,a) and bn,a (decode: ba to pc+8) are jumps;
		* a=1 conditionals annul a not-taken slot, as MIPS branch-likely does */
	       t_take_br = (int_uop.cond == 4'd8) | eval_icc(int_uop.cond, w_s_icc);
	       t_mispred_br = (int_uop.br_pred != t_take_br) |
			      (int_uop.has_nullifying_delay_slot & !t_take_br);
	       t_pc = `M_WIDTH'(t_take_br ? w_s_branch_target : w_s_pc8);
	       t_alu_valid = 1'b1;
	    end
	  S_FBFCC:
	    begin
	       /* as S_BICC, on fcc (the renamed FCR register's [1:0]) */
	       t_take_br = eval_fcc(int_uop.cond, r_fcr_prf[int_uop.hilo_src[`LG_FCR_PRF_ENTRIES-1:0]][1:0]);
	       t_mispred_br = (int_uop.br_pred != t_take_br) |
			      (int_uop.has_nullifying_delay_slot & !t_take_br);
	       t_pc = `M_WIDTH'(t_take_br ? w_s_branch_target : w_s_pc8);
	       t_alu_valid = 1'b1;
	    end
	  S_CALL:
	    begin
	       t_take_br = 1'b1;
	       t_mispred_br = (int_uop.br_pred != 1'b1);
	       t_pc = `M_WIDTH'(w_s_branch_target);
	       t_result = int_uop.pc;
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_JMPL:
	    begin
	       t_take_br = 1'b1;
	       t_pc = `M_WIDTH'(w_s_add[31:0]);
	       /* a misaligned target: mem_address_not_aligned (tt 0x07), rd unwritten */
	       t_trap = (w_s_add[1:0] != 2'd0);
	       t_fault = t_trap;
	       t_mispred_br = (t_pc != int_uop.pred_target);
	       t_result = t_trap ? `M_WIDTH'(8'h07) : int_uop.pc;
	       t_wr_int_prf = int_uop.dst_valid & !t_trap;
	       t_alu_valid = 1'b1;
	    end
	  S_RDY:
	    begin
	       t_result = t_src_hilo;   /* Y (the HILO rename) */
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_WRY:
	    begin
	       t_hilo_result = t_srcA[31:0] ^ w_s_op2;
	       t_wr_hilo = 1'b1;
	       t_alu_valid = 1'b1;
	    end
	  S_RDPSR:
	    begin
	       t_result = `M_WIDTH'(sparc_psr | {8'd0, w_s_icc, 15'd0, int_uop.imm[4:0]});
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_RDWIM:
	    begin
	       t_result = `M_WIDTH'(sparc_wim);
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_RDTBR:
	    begin
	       t_result = `M_WIDTH'(sparc_tbr);
	       t_wr_int_prf = int_uop.dst_valid;
	       t_alu_valid = 1'b1;
	    end
	  S_WRPSR, S_WRWIM, S_WRTBR:
	    begin
	       /* rs1 xor operand 2; the core applies it at retire (from the ROB's
		* data).  WRPSR's icc also lands in its flags register. */
	       t_result = `M_WIDTH'(t_srcA[31:0] ^ w_s_op2);
	       t_icc_out = t_result[23:20];
	       /* WRPSR with CWP >= NWINDOWS: illegal_instruction (tt 0x02) */
	       t_trap = (int_uop.op == S_WRPSR) & (t_result[4:0] >= `NWINDOWS);
	       t_fault = t_trap;
	       if(t_trap)
		 begin
		    t_result = `M_WIDTH'(8'h02);
		 end
	       t_wr_int_prf = int_uop.dst_valid & !t_trap;
	       t_alu_valid = 1'b1;
	    end
	  S_FLUSH:
	    begin
	       /* the EA, for the retire-time L1I line invalidate (core.sv) */
	       t_result = `M_WIDTH'(w_s_add[31:0]);
	       t_alu_valid = 1'b1;
	    end
	  S_RETT:
	    begin
	       /* serializing: the core restarts at the target (behind its jmpl, into
		* the delay slot -- core.sv restart_npc); a misaligned target is
		* mem_address_not_aligned */
	       t_take_br = 1'b1;
	       t_pc = `M_WIDTH'(w_s_add[31:0]);
	       t_trap = (w_s_add[1:0] != 2'd0);
	       t_fault = t_trap;
	       t_result = `M_WIDTH'(8'h07);
	       t_alu_valid = 1'b1;
	    end
	  default:
	    begin
	       /* not implemented: illegal_instruction (tt 0x02) */
	       t_unimp_op = 1'b1;
	       t_result = `M_WIDTH'(8'h02);
	       t_alu_valid = 1'b1;
	    end
	endcase // case (int_uop.op)

	
     end // always_comb


   /* base + offset, where the offset is the index GPR for the ENABLE_MIPS4 indexed FP
    * loads/stores (decode_mips.sv COP1X: index in srcC, imm 0) and the sign-extended
    * immediate otherwise.  A 2:1 select on a registered bit in front of a two-input add:
    * a three-input (carry-save) add here cost ~2.7 ns in front of the DTLB match
    * (henry 5aa9462e, WNS +5.016 -> +2.309 at 50 MHz).  index = $0 -> srcC_valid = 0 ->
    * imm, which is 0 for these ops. */
`ifdef ENABLE_INT_SRCC
   wire [`M_WIDTH-1:0] w_mem_off = mem_uq.srcC_valid ? t_mem_srcC : {{E_BITS{mem_uq.imm[15]}},mem_uq.imm};
`else
   wire [`M_WIDTH-1:0] w_mem_off = {{E_BITS{mem_uq.imm[15]}},mem_uq.imm};
`endif
   wire [`M_WIDTH-1:0] w_agu = t_mem_srcA + w_mem_off;


   /* mfc1's FP source is the registered FP read r_fp_rd_srcB (aligned with mem_uq).
    * mfc1 (FP src -> address/mem-pop) gates the address pop on its FP source; FP stores
    * read the FP PRF through the store-data queue instead, so they don't gate here. */


   always_comb
     begin
	/* uq -> scheduler whenever a slot is free (rv64core) */
	t_pop_mem_uq = (!t_mem_uq_empty) && ((&(r_mem_sched_valid | ~MEM_SCHED_USABLE)) == 1'b0) && !t_flash_clear;

     end


   /* ---------------- LSU ----------------
    * Entry classes (by op at allocation):
    *   simple load (r_mem_sched_ld): held from issue until its data returns; a
    *     block parks it (code in r_mem_sched_blk) until its wake condition.
    *   plain store (r_mem_sched_st): address pass at issue (translate + fault +
    *     ROB ack; PA/mask land in the l1d store buffer), data captured separately
    *     when its source is ready, held until it retires, then committed oldest
    *     store first and freed when the l1d has written it.
    *   strict (everything else: LL/SC, SWL/SWR/SDL/SDR, LWL/LWR/LDL/LDR, CACHE,
    *     TLBP, GPR<->FPR moves): issues only when every older entry is gone and
    *     leaves at issue (today's l1d paths) -- except CACHE hit ops
    *     (r_mem_sched_ser), which are fully serializing: they also hold their
    *     entry (and so everything younger) until the l1d answers that the line
    *     op is done; the l1d admits them only at the ROB head.
    * Ordering: an entry may issue only when no older entry is "pending" (a strict
    * op, or a store whose address pass has not issued), so every older store has
    * its PA in the store buffer before a load reaches the l1d, and a load never
    * passes a strict op.  Among eligible entries the oldest issues (ALU select). */
   generate
      for(genvar i = 0; i < N_MEM_SCHED_ENTRIES; i=i+1)
	begin : mem_rdy
	   always_comb
	     begin
		t_mem_entry_rdy[i] = r_mem_sched_valid[i] && !r_mem_sched_issued[i] && (r_mem_sched_blk[i] == BLK_NONE) &&
				     /* ldd: no other ldd outstanding, nothing parked or parking */
				     (r_mem_sched_uops[i].dst2_valid ?
				      (((t_mem_ldd_out & ~(1 << i)) == 'd0) && !r_park_valid && !w_park_in) : 1'b1) &&
				     (!r_mem_sched_mg[i] || r_mem_sched_sd_ok[i]) &&
				     !(mem_q_next_full||mem_q_full) && !t_flash_clear &&
				     (r_mem_sched_uops[i].srcA_valid ?
				      (!r_prf_inflight[r_mem_sched_uops[i].srcA] |
				       (t_iwb && (t_iwb_dst != 'd0) && (r_mem_sched_uops[i].srcA == t_iwb_dst)) |
				       (w_mem_rsp_int_valid && (r_mem_sched_uops[i].srcA == mem_rsp_dst_ptr))) : 1'b1) &&
`ifdef ENABLE_INT_SRCC
				     /* indexed FP load/store: the index (srcC) too */
				     (r_mem_sched_uops[i].srcC_valid ?
				      (!r_prf_inflight[r_mem_sched_uops[i].srcC] |
				       (t_iwb && (t_iwb_dst != 'd0) && (r_mem_sched_uops[i].srcC == t_iwb_dst)) |
				       (w_mem_rsp_int_valid && (r_mem_sched_uops[i].srcC == mem_rsp_dst_ptr))) : 1'b1) &&
`endif
				     ((r_mem_sched_uops[i].fp_srcB_valid && !r_mem_sched_uops[i].is_store) ?
				      !r_fp_prf_inflight[r_mem_sched_uops[i].srcB] : 1'b1);
		t_mem_elig[i] = t_mem_entry_rdy[i] &
				(r_mem_sched_mv[i] ? 1'b1 :
				 (t_mem_strict[i] | r_mem_sched_old1[i]) ? ((|r_mem_sched_matrix[i]) == 1'b0) :
				 ((|(r_mem_sched_matrix[i] & t_mem_pending)) == 1'b0));
		/* retired store, no older store still to commit, data in the l1d: commit
		 * it (commits stay in program order through the exec mem_q and the MQ,
		 * so they pipeline back to back) */
		t_mem_cmt_rdy[i] = t_mem_st_live[i] && r_mem_sched_ret[i] && r_mem_sched_sd_ok[i] && !r_mem_sched_cmt[i] &&
				   ((|(r_mem_sched_matrix[i] & t_mem_st_live & ~r_mem_sched_cmt)) == 1'b0) &&
				   !(mem_q_next_full||mem_q_full);
		/* store data source ready (read through the store-data PRF port) */
		t_mem_sd_rdy[i] = (t_mem_st_live[i] || (r_mem_sched_valid[i] && r_mem_sched_mg[i])) &&
				  !r_mem_sched_sd_sel[i] && !t_flash_clear &&
				  (r_mem_sched_uops[i].fp_srcB_valid ? !r_fp_prf_inflight[r_mem_sched_uops[i].srcB] :
				   r_mem_sched_uops[i].srcB_valid ? !r_prf_inflight[r_mem_sched_uops[i].srcB] : 1'b1) &&
				  /* SPARC std: rd+1, read the cycle after rd through the same port */
				  (r_mem_sched_uops[i].srcD_valid ? !r_prf_inflight[r_mem_sched_uops[i].srcD] : 1'b1);
		t_mem_st_retire[i] = t_mem_st_live[i] && r_mem_sched_issued[i] && !r_mem_sched_ret[i] &&
				     ((retired_rob_ptr_valid && (r_mem_sched_uops[i].rob_ptr == retired_rob_ptr)) ||
				      (retired_rob_ptr_two_valid && (r_mem_sched_uops[i].rob_ptr == retired_rob_ptr_two)));
		/* LSU-owned blocks release when the stores they wait on have drained (or,
		 * for BLK_SB_DATA, have their data); the wait mask drops freed slots */
		t_blk_release[i] = ((r_mem_sched_blk[i] == BLK_UNCACHEABLE) &&
				    ((head_of_rob_ptr_valid && (head_of_rob_ptr == r_mem_sched_uops[i].rob_ptr)) ||
				     (head_of_rob_ds_committable && (next_head_of_rob_ptr == r_mem_sched_uops[i].rob_ptr)))) ||
				   ((r_mem_sched_blk[i] == BLK_SB_CONFLICT) && ((r_mem_sched_blk_st[i] & ~t_mem_free_entry) == 'd0)) ||
				   ((r_mem_sched_blk[i] == BLK_TLB) && !mem_tlb_busy) ||
				   ((r_mem_sched_blk[i] == BLK_SB_DATA) &&
				    ((r_mem_sched_blk_st[i] & ~t_mem_free_entry & ~r_mem_sched_sd_ok) == 'd0));
	     end // always_comb
	   assign w_mem_sched_oldest_ready[i] = t_mem_elig[i] & (~(|(t_mem_elig & r_mem_sched_matrix[i])));
	end // block: mem_rdy
   endgenerate

   find_lowest_set_bit#(`LG_MEM_SCHED_ENTRIES) ffs_mem_sched_alloc( .in(~r_mem_sched_valid & MEM_SCHED_USABLE),
								   .y(t_mem_sched_alloc_ptr));
   find_lowest_set_bit#(`LG_MEM_SCHED_ENTRIES) ffs_mem_sched_select( .in(w_mem_sched_oldest_ready),
								    .y(t_mem_sched_pick_ptr));
   find_lowest_set_bit#(`LG_MEM_SCHED_ENTRIES) ffs_mem_sched_cmt( .in(t_mem_cmt_rdy),
								      .y(t_mem_cmt_ptr));
   find_lowest_set_bit#(`LG_MEM_SCHED_ENTRIES) ffs_mem_sched_sd( .in(t_mem_sd_rdy),
								     .y(t_mem_sd_ptr));

   assign lsu_st_pending = |(r_mem_sched_valid & r_mem_sched_st);

   /* restart color (rv64core's r_restart_counter, 1 bit) */
   always_ff@(posedge clk)
     begin
	r_restart_color <= reset ? 1'b0 : (restart_complete ? !r_restart_color : r_restart_color);
     end
   assign restart_color = r_restart_color;

   /* colors still on their way to the l1d: the AGU stage and the request FIFO
    * (commits are never dead, so their color does not matter) */
   always_comb
     begin
	logic [`LG_MQ_ENTRIES:0] t_cnt, t_p;
	mem_color_pending = 2'd0;
	if(r_mem_ready && !r_mem_uq_commit)
	  begin
	     mem_color_pending[r_mem_uq_color] = 1'b1;
	  end
	t_cnt = r_mq_tail_ptr - r_mq_head_ptr;
	for(integer i = 0; i < N_MQ_ENTRIES; i = i + 1)
	  begin
	     t_p = r_mq_head_ptr + i[`LG_MQ_ENTRIES:0];
	     if((i < t_cnt) && !r_mem_q[t_p[`LG_MQ_ENTRIES-1:0]].commit)
	       begin
		  mem_color_pending[r_mem_q[t_p[`LG_MQ_ENTRIES-1:0]].restart_id] = 1'b1;
	       end
	  end
     end // always_comb

   /* entry classes (registered state only) */
   always_comb
     begin
	t_mem_strict = r_mem_sched_valid & ~r_mem_sched_ld & ~r_mem_sched_st & ~r_mem_sched_mv;
	t_mem_st_live = r_mem_sched_valid & r_mem_sched_st;
	for(integer j = 0; j < N_MEM_SCHED_ENTRIES; j = j + 1)
	  begin
	     /* an ldd the l1d still owes a response: issued, or blocked on the cache
	      * (a miss/MQ block answers it later; an LSU-owned block, bit 2, does not) */
	     t_mem_ldd_out[j] = r_mem_sched_valid[j] & r_mem_sched_uops[j].dst2_valid &
				(r_mem_sched_issued[j] | ((r_mem_sched_blk[j] != BLK_NONE) & !r_mem_sched_blk[j][2]));
	  end
	/* an atomic (old1) holds back everything younger until it is answered */
	t_mem_pending = t_mem_strict | (r_mem_sched_valid & r_mem_sched_old1) | (t_mem_st_live & ~r_mem_sched_issued);
     end // always_comb

   always_comb
     begin
	/* one issue per cycle into the mem pipe: loads/address passes first (a
	 * commit is off the critical path; when the LSU fills with retired stores
	 * nothing else is ready, so commits cannot starve) */
	t_mem_issue_addr = |w_mem_sched_oldest_ready;
	t_mem_issue_cmt = (|t_mem_cmt_rdy) & !t_mem_issue_addr;
	t_mem_issue = t_mem_issue_cmt | t_mem_issue_addr;
	t_mem_sched_select_ptr = t_mem_issue_cmt ? t_mem_cmt_ptr : t_mem_sched_pick_ptr;
	t_picked_mem_uop = r_mem_sched_uops[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]];
	/* store / merge-load data capture: the store-data PRF read port (port 3) */
	t_sd_go = (|t_mem_sd_rdy) & !r_sd_std_ph2;
	t_sd_src = r_sd_std_ph2 ? r_mem_sched_uops[r_sd_idx].srcD :
		   r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].srcB;
	t_mem_alloc_entry = 'd0;
	t_mem_select_entry = 'd0;
	if(t_pop_mem_uq)
	  begin
	     t_mem_alloc_entry[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
	if(t_mem_issue)
	  begin
	     t_mem_select_entry[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
	/* freed: a strict op or FP<->GPR move at issue, a simple load at its data
	 * response, a plain store when the l1d has written it */
	t_mem_free_entry = t_mem_select_entry & (t_mem_strict | r_mem_sched_mv) & ~r_mem_sched_ser & {N_MEM_SCHED_ENTRIES{t_mem_issue_addr}};
	if(mem_rsp_valid && mem_rsp_lsu_hold && (r_mem_sched_ld[mem_rsp_lsu_idx] | r_mem_sched_ser[mem_rsp_lsu_idx]))
	  begin
	     t_mem_free_entry[mem_rsp_lsu_idx] = 1'b1;
	  end
	if(mem_st_done_valid)
	  begin
	     t_mem_free_entry[mem_st_done_idx] = 1'b1;
	  end
	t_mem_free_entry = t_mem_free_entry & r_mem_sched_valid;
	t_mem_sched_mask_valid = r_mem_sched_valid & (~t_mem_free_entry);
	/* merging partial loads read memory like any load; their old register is
	 * captured into the entry's store-buffer data slot before they issue.  No
	 * SPARC integer load merges (MIPS LWL/LWR did); kept for the FP singles
	 * that land in half of a 64-bit FP register. */
	t_mem_uq_merge = 1'b0;
	/* ldstub/swap (rv64core's AMOs): held like a load (a block replays it),
	 * issued only as the oldest LSU op so every older store has drained and
	 * nothing younger passes it, and performed non-speculatively by the l1d as
	 * one read-modify-write.  swap's rd (the store data) is captured into its
	 * store-buffer data slot before issue, as a merging load's old register. */
	t_mem_uq_atomic = (t_mem_uq.op == S_LDSTUB) | (t_mem_uq.op == S_SWAP);
	/* lda/sta to a non-memory ASI (SRMMU registers, flushes, module registers,
	 * cache diagnostics) go the same way: held, oldest, performed by the l1d at
	 * the ROB head (a store's data captured first) */
	t_mem_uq_mmureg = !asi_is_memory(t_mem_uq.asi);
	t_mem_uq_generic_load = (t_mem_uq.op == LW) |
				(t_mem_uq.op == LB) | (t_mem_uq.op == LBU) |
				(t_mem_uq.op == LH) | (t_mem_uq.op == LHU) |
				(t_mem_uq.op == LD) | (t_mem_uq.op == LWC1) |
				(t_mem_uq.op == LDC1) | (t_mem_uq.op == S_LDFSR) | t_mem_uq_merge | t_mem_uq_atomic | t_mem_uq_mmureg;
	t_mem_uq_plain_store = is_lsu_store(t_mem_uq.op) & !t_mem_uq_mmureg;
	t_mem_uq_serial = (t_mem_uq.op == CHWB) | (t_mem_uq.op == CHWBINV) | (t_mem_uq.op == CHINV) |
			  (t_mem_uq.op == CHBWBINV) | (t_mem_uq.op == CHBINV) | (t_mem_uq.op == CHBIDX);
	/* issue only as the oldest op */
	t_mem_uq_old1 = t_mem_uq_atomic | t_mem_uq_mmureg;
	/* GPR<->FPR moves only borrow the mem pipe as a cross-register-file path (MEM_MOV,
	 * echoed by the l1d with no cache access): no memory ordering either way */
	t_mem_uq_move = (t_mem_uq.op == MFC1) | (t_mem_uq.op == MTC1) |
			(t_mem_uq.op == DMFC1) | (t_mem_uq.op == DMTC1);
     end // always_comb

   /* LSU state next-values */
   always_comb
     begin
	n_mem_sched_valid = r_mem_sched_valid;
	n_mem_sched_ld = r_mem_sched_ld;
	n_mem_sched_st = r_mem_sched_st;
	n_mem_sched_ser = r_mem_sched_ser;
	n_mem_sched_old1 = r_mem_sched_old1;
	n_mem_sched_mg = r_mem_sched_mg;
	n_mem_sched_mv = r_mem_sched_mv;
	n_mem_sched_issued = r_mem_sched_issued;
	n_mem_sched_sd_sel = r_mem_sched_sd_sel;
	n_mem_sched_sd_ok = r_mem_sched_sd_ok;
	n_mem_sched_ret = r_mem_sched_ret | t_mem_st_retire;
	n_mem_sched_cmt = r_mem_sched_cmt;
	n_mem_sched_ep = r_mem_sched_ep;
	for(integer i = 0; i < N_MEM_SCHED_ENTRIES; i = i + 1)
	  begin
	     n_mem_sched_blk[i] = t_blk_release[i] ? BLK_NONE : r_mem_sched_blk[i];
	     n_mem_sched_blk_st[i] = r_mem_sched_blk_st[i] & ~t_mem_free_entry;
	     n_mem_sched_ep_snap[i] = r_mem_sched_ep_snap[i];
	     n_mem_sched_matrix[i] = t_mem_alloc_entry[i] ? t_mem_sched_mask_valid :
				     (r_mem_sched_matrix[i] & ~t_mem_free_entry);
	  end
	if(t_pop_mem_uq)
	  begin
	     n_mem_sched_valid[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = 1'b1;
	     n_mem_sched_ld[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = t_mem_uq_generic_load;
	     n_mem_sched_st[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = t_mem_uq_plain_store;
	     n_mem_sched_ser[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = t_mem_uq_serial;
	     n_mem_sched_old1[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = t_mem_uq_old1;
	     n_mem_sched_mg[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = t_mem_uq_merge | (t_mem_uq.op == S_SWAP) |
										    (t_mem_uq_mmureg & is_lsu_store(t_mem_uq.op));
	     n_mem_sched_mv[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = t_mem_uq_move;
	     n_mem_sched_ep[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = !r_mem_sched_ep[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]];
	  end
	if(t_mem_issue_addr)
	  begin
	     n_mem_sched_issued[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = 1'b1;
	     n_mem_sched_ep_snap[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = r_mem_sched_ep;
	  end
	if(t_mem_issue_cmt)
	  begin
	     n_mem_sched_cmt[t_mem_sched_select_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
	if(t_sd_go)
	  begin
	     n_mem_sched_sd_sel[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] = 1'b1;
	  end
	if(r_sd_go)
	  begin
	     n_mem_sched_sd_ok[r_sd_idx] = 1'b1;
	  end
	if(mem_blk_valid)
	  begin
	     n_mem_sched_issued[mem_rsp_lsu_idx] = 1'b0;
	     n_mem_sched_blk[mem_rsp_lsu_idx] = mem_blk_code;
	     /* LSU-owned: the stores to wait on, minus any drained (or slot reused)
	      * since the l1d compared */
	     n_mem_sched_blk_st[mem_rsp_lsu_idx] = mem_blk_st & t_mem_st_live & ~t_mem_free_entry &
						   ~(r_mem_sched_ep ^ r_mem_sched_ep_snap[mem_rsp_lsu_idx]);
	  end
	if(mem_wake_valid)
	  begin
	     n_mem_sched_blk[mem_rsp_lsu_idx] = BLK_NONE;
	  end
	for(integer i = 0; i < N_MEM_SCHED_ENTRIES; i = i + 1)
	  begin
	     if(t_mem_free_entry[i])
	       begin
		  n_mem_sched_valid[i] = 1'b0;
		  n_mem_sched_ld[i] = 1'b0;
		  n_mem_sched_st[i] = 1'b0;
		  n_mem_sched_ser[i] = 1'b0;
		  n_mem_sched_old1[i] = 1'b0;
		  n_mem_sched_mg[i] = 1'b0;
		  n_mem_sched_mv[i] = 1'b0;
		  n_mem_sched_issued[i] = 1'b0;
		  n_mem_sched_sd_sel[i] = 1'b0;
		  n_mem_sched_sd_ok[i] = 1'b0;
		  n_mem_sched_ret[i] = 1'b0;
		  n_mem_sched_cmt[i] = 1'b0;
		  n_mem_sched_blk[i] = BLK_NONE;
		  n_mem_sched_blk_st[i] = 'd0;
	       end
	  end
	/* flush: everything speculative goes; retired stores are committed state and
	 * stay (they keep draining through the flush) */
	t_mem_survive = n_mem_sched_valid & n_mem_sched_st & n_mem_sched_ret;
	if(t_flash_clear)
	  begin
	     n_mem_sched_valid = t_mem_survive;
	     n_mem_sched_ld = 'd0;
	     n_mem_sched_ser = 'd0;
	     n_mem_sched_old1 = n_mem_sched_old1 & t_mem_survive;
	     n_mem_sched_mg = 'd0;
	     n_mem_sched_st = t_mem_survive;
	     n_mem_sched_issued = n_mem_sched_issued & t_mem_survive;
	     n_mem_sched_sd_sel = n_mem_sched_sd_sel & t_mem_survive;
	     n_mem_sched_sd_ok = n_mem_sched_sd_ok & t_mem_survive;
	     n_mem_sched_ret = n_mem_sched_ret & t_mem_survive;
	     n_mem_sched_cmt = n_mem_sched_cmt & t_mem_survive;
	     for(integer i = 0; i < N_MEM_SCHED_ENTRIES; i = i + 1)
	       begin
		  n_mem_sched_blk[i] = BLK_NONE;
		  n_mem_sched_blk_st[i] = 'd0;
		  n_mem_sched_matrix[i] = n_mem_sched_matrix[i] & t_mem_survive;
	       end
	  end
	/* unusable slots stay invalid: a constant synthesis can see */
	n_mem_sched_valid = n_mem_sched_valid & MEM_SCHED_USABLE;
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_mem_sched_valid <= 'd0;
	     r_mem_sched_ld <= 'd0;
	     r_mem_sched_st <= 'd0;
	     r_mem_sched_ser <= 'd0;
	     r_mem_sched_old1 <= 'd0;
	     r_mem_sched_mg <= 'd0;
	     r_mem_sched_mv <= 'd0;
	     r_mem_sched_issued <= 'd0;
	     r_mem_sched_sd_sel <= 'd0;
	     r_mem_sched_sd_ok <= 'd0;
	     r_mem_sched_ret <= 'd0;
	     r_mem_sched_cmt <= 'd0;
	     r_mem_sched_ep <= 'd0;
	     for(integer i = 0; i < N_MEM_SCHED_ENTRIES; i = i + 1)
	       begin
		  r_mem_sched_blk[i] <= BLK_NONE;
		  r_mem_sched_blk_st[i] <= 'd0;
		  r_mem_sched_ep_snap[i] <= 'd0;
		  r_mem_sched_matrix[i] <= 'd0;
	       end
	  end
	else
	  begin
	     r_mem_sched_valid <= n_mem_sched_valid;
	     r_mem_sched_ld <= n_mem_sched_ld;
	     r_mem_sched_st <= n_mem_sched_st;
	     r_mem_sched_ser <= n_mem_sched_ser;
	     r_mem_sched_old1 <= n_mem_sched_old1;
	     r_mem_sched_mg <= n_mem_sched_mg;
	     r_mem_sched_mv <= n_mem_sched_mv;
	     r_mem_sched_issued <= n_mem_sched_issued;
	     r_mem_sched_sd_sel <= n_mem_sched_sd_sel;
	     r_mem_sched_sd_ok <= n_mem_sched_sd_ok;
	     r_mem_sched_ret <= n_mem_sched_ret;
	     r_mem_sched_cmt <= n_mem_sched_cmt;
	     r_mem_sched_ep <= n_mem_sched_ep;
	     for(integer i = 0; i < N_MEM_SCHED_ENTRIES; i = i + 1)
	       begin
		  r_mem_sched_blk[i] <= n_mem_sched_blk[i];
		  r_mem_sched_blk_st[i] <= n_mem_sched_blk_st[i];
		  r_mem_sched_ep_snap[i] <= n_mem_sched_ep_snap[i];
		  r_mem_sched_matrix[i] <= n_mem_sched_matrix[i];
	       end
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(t_pop_mem_uq)
	  begin
	     r_mem_sched_uops[t_mem_sched_alloc_ptr[`LG_MEM_SCHED_ENTRIES-1:0]] <= t_mem_uq;
	  end
     end // always_ff@ (posedge clk)

   /* store data capture: read at t (store-data PRF port), write the l1d store
    * buffer at t+1 -- which is also the ROB's store-data-complete (retire gate) */
   always_ff@(posedge clk)
     begin
	/* a std is picked at t (rd read), reads rd+1 at t+1 (r_sd_std_ph2: no new
	 * pick, the r_sd_* fields hold), and writes the store buffer at t+2 */
	if(reset)
	  begin
	     r_sd_go <= 1'b0;
	     r_sd_std_ph2 <= 1'b0;
	  end
	else
	  begin
	     r_sd_go <= (t_sd_go & !r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].srcD_valid) |
			r_sd_std_ph2;
	     r_sd_std_ph2 <= t_sd_go & r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].srcD_valid;
	  end
	if(r_sd_std_ph2)
	  begin
	     r_sd_hi <= w_mem_srcB[31:0];
	  end
	else
	  begin
	     r_sd_idx <= t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0];
	     r_sd_fp <= r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].fp_srcB_valid;
	     r_sd_std <= r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].srcD_valid;
	     r_sd_fp_hi <= r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].jmp_imm[0];
	     r_sd_zero <= !(r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].fp_srcB_valid |
			    r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].srcB_valid);
	     r_sd_rob <= r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].rob_ptr;
	     r_sd_fsr <= (r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].op == S_STFSR);
	     r_sd_fcr <= r_mem_sched_uops[t_mem_sd_ptr[`LG_MEM_SCHED_ENTRIES-1:0]].hilo_src[`LG_FCR_PRF_ENTRIES-1:0];
	  end
     end // always_ff@ (posedge clk)

   always_comb
     begin
	lsu_sb.live = t_mem_st_live;
	lsu_sb.epoch = r_mem_sched_ep;
	lsu_sb.data_ok = r_mem_sched_sd_ok;
	for(integer j = 0; j < N_MEM_SCHED_ENTRIES; j = j + 1)
	  begin
	     lsu_sb.matrix[j*N_MEM_SCHED_ENTRIES +: N_MEM_SCHED_ENTRIES] = r_mem_sched_matrix[j];
	  end
	lsu_sb.retired_pending = |(t_mem_st_live & r_mem_sched_ret);
	lsu_sb.data_valid = r_sd_go;
	lsu_sb.data_idx = r_sd_idx;
	/* FR=0 swc1 odd reg (fp_hi): store the HIGH 32b half (placed low for MEM_SW) */
	lsu_sb.data = r_sd_fsr ? {32'd0, w_fsr} :
		      r_sd_zero ? 64'd0 :
		      r_sd_fp ? (r_sd_fp_hi ? {32'd0, r_fp_rd_dq[63:32]} : r_fp_rd_dq) :
		      /* std: rd at the address, rd+1 after it (big-endian MEM_SD) */
		      r_sd_std ? {r_sd_hi, w_mem_srcB[31:0]} :
		      64'(w_mem_srcB);
     end // always_comb

`ifdef LSU_TRACE
   always_ff@(negedge clk)
     begin
	if(mem_blk_valid)
	  begin
	     $display("[LSU] cyc=%0d blk idx=%0d code=%0d rob=%0d st=%b", r_cycle, mem_rsp_lsu_idx, mem_blk_code, mem_rsp_rob_ptr, mem_blk_st);
	  end
	if(mem_wake_valid)
	  begin
	     $display("[LSU] cyc=%0d wake idx=%0d", r_cycle, mem_rsp_lsu_idx);
	  end
	if(t_mem_issue)
	  begin
	     $display("[LSU] cyc=%0d %s idx=%0d rob=%0d pc=%x", r_cycle, t_mem_issue_cmt ? "commit" : "issue",
		      t_mem_sched_select_ptr, t_picked_mem_uop.rob_ptr, t_picked_mem_uop.pc);
	  end
	if(mem_st_done_valid)
	  begin
	     $display("[LSU] cyc=%0d st_done idx=%0d", r_cycle, mem_st_done_idx);
	  end
	if(r_sd_go)
	  begin
	     $display("[LSU] cyc=%0d sdata idx=%0d data=%x", r_cycle, r_sd_idx, lsu_sb.data);
	  end
     end // always_ff@ (negedge clk)
`endif

   //need another queue to hold store data
   
   always_comb
     begin
	/* store-data complete (the ROB's retire gate): an LSU data capture */
	core_store_data_ptr = r_sd_rob;
	core_store_data_ptr_valid = r_sd_go;
     end


   
   
   
   //always_ff@(negedge clk)
     //begin
   //if(r_dq_ready)
   //begin
   //$display("cycle %d : popping dq, rob ptr %d, src ptr %d, pc %x, tag %d", r_cycle, mem_dq.rob_ptr, mem_dq.src_ptr, mem_dq.pc, mem_dq.tag);
   //	  end
	//if(r_mem_ready)
	  //begin
	    // $display("cycle %d, popping aq , rob ptr %d, srcb ptr %d, srcB val %b", r_cycle, mem_uq.rob_ptr, mem_uq.srcB, mem_uq.srcB_valid);
	  //end
   //end

   //always_ff@(posedge clk)
   //begin
   //core_store_data <= t_core_store_data;
   //end
   
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_mem_ready <= 1'b0;
	  end
	else
	  begin
	     r_mem_ready <= t_mem_issue;
	  end
     end // always_ff@ (posedge clk)

   
   //$stop();
   //end

   wire [`M_WIDTH-1:0] w_agu_la;
   wire		       w_cached, w_mapped;
   wire [1:0]	       w_seg;
   
   /* SPARC: the access goes out at its VA with its ASI; the l1d translates the
    * user/supervisor insn and data ASIs (0x8-0xb) through the SRMMU (PA = VA with
    * the MMU off).  The bypass ASIs 0x20-0x2f put PA[35:32] = ASI[3:0] and go
    * uncached (device space).  The other ASIs (MMU registers, probe/flush, cache
    * diagnostics) are not plumbed yet and go out untranslated. */
   assign w_agu_la = w_agu;
   assign w_cached = (mem_uq.asi[7:4] != 4'h2) & asi_is_memory(mem_uq.asi);
   assign w_mapped = (mem_uq.asi[7:2] == 6'b000010);
   assign w_seg = 2'd0;
   assign w_bad_seg_perms = 1'b0;

   wire w_bad_seg_perms;

   always_comb
     begin
	t_mem_simm = {{E_BITS{mem_uq.imm[15]}},mem_uq.imm};
	t_mem_tail.op = MEM_LW;
	t_mem_tail.addr = `REQ_ADDR_WIDTH'(w_agu_la);
	t_mem_tail.rob_ptr = mem_uq.rob_ptr;
	t_mem_tail.dst_valid = 1'b0;
	t_mem_tail.fp_dst = 1'b0;
	t_mem_tail.fp_merge = 1'b0;
	t_mem_tail.fp_hi = 1'b0;
	t_mem_tail.fp_pres = 32'd0;
	t_mem_tail.dst_ptr = mem_uq.dst;
	t_mem_tail.dst2_ptr = mem_uq.dst2;
	t_mem_tail.dst2_valid = 1'b0;
	t_mem_tail.is_store = 1'b0;
	t_mem_tail.is_atomic = 1'b0;
	t_mem_tail.data = 'd0;
	t_mem_tail.bad_addr = 1'b0;
	t_mem_tail.cached = w_cached;
	t_mem_tail.mapped = w_mapped;
	t_mem_tail.asi = mem_uq.asi;
	t_mem_tail.pc = mem_uq.pc;   /* un-guarded for synth: store-tracer PC watchpoint */
	t_mem_tail.lsu_hold = r_mem_uq_lsu_hold;
	t_mem_tail.lsu_idx = r_mem_uq_lsu_idx;
	t_mem_tail.commit = 1'b0;
	t_mem_tail.restart_id = r_mem_uq_color;
	t_mem_tail.lsu_older_st = r_mem_uq_older_st;
	t_mem_tail.lsu_older_ep = r_mem_uq_older_ep;
`ifdef VERILATOR
	t_mem_tail.pc = mem_uq.pc;
	t_mem_tail.uuid = {32'd0, r_cycle[31:0]};   /* r_cycle is now 64b; uuid keeps the low 32 */
`endif	
	case(mem_uq.op)
	  CHBWBINV, CHBINV, CHBIDX:
	    begin
	       /* R10000 secondary-cache ops: like the CH ops, one non-speculative mem op
		* the l1d answers when its L2 request is acked; the L2 does the block */
	       t_mem_tail.op = (mem_uq.op == CHBWBINV) ? MEM_BLK_WBINV :
			       (mem_uq.op == CHBINV) ? MEM_BLK_INV : MEM_BLK_IDX;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end
	  SB:
	    begin
	       t_mem_tail.op = MEM_SB;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_bad_seg_perms;	       
	    end // case: SB
	  SH:
	    begin
	       t_mem_tail.op = MEM_SH;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = w_agu[0] | w_bad_seg_perms;
	    end // case: SW
	  SW:
	    begin
	       t_mem_tail.op = MEM_SW;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end // case: SW
	  LW:
	    begin
	       t_mem_tail.op = MEM_LW;
	       t_mem_tail.dst_valid = mem_uq.dst_valid;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end // case: LW
	  LB:
	    begin
	       t_mem_tail.op = MEM_LB;
	       t_mem_tail.dst_valid = mem_uq.dst_valid;
	       t_mem_tail.bad_addr = w_bad_seg_perms;	       
	    end
	  LBU:
	    begin
	       t_mem_tail.op = MEM_LBU;
	       t_mem_tail.dst_valid = mem_uq.dst_valid;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end // case: LBU
	  LHU:
	    begin
	       t_mem_tail.op = MEM_LHU;
	       t_mem_tail.dst_valid = mem_uq.dst_valid;
	       t_mem_tail.bad_addr = w_agu[0] | w_bad_seg_perms;
	    end // case: LBU
	  LH:
	    begin
	       t_mem_tail.op = MEM_LH;
	       t_mem_tail.dst_valid = mem_uq.dst_valid;
	       t_mem_tail.bad_addr = w_agu[0] | w_bad_seg_perms;
	    end // case: LH
	  LD:
	    begin
	       t_mem_tail.op = MEM_LD;
	       t_mem_tail.dst_valid = mem_uq.dst_valid;
	       t_mem_tail.dst2_valid = mem_uq.dst2_valid;   /* SPARC ldd */
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  SD:
	    begin
	       t_mem_tail.op = MEM_SD;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  S_LDSTUB:
	    begin
	       /* the l1d writes 0xff and answers the old byte (its data is not used) */
	       t_mem_tail.op = MEM_LDSTUB;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.is_atomic = 1'b1;
	       t_mem_tail.dst_valid = mem_uq.dst_valid;
	       t_mem_tail.bad_addr = w_bad_seg_perms;
	    end
	  S_SWAP:
	    begin
	       /* the store data (rd) is in the l1d store-buffer slot (captured first) */
	       t_mem_tail.op = MEM_SWAP;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.is_atomic = 1'b1;
	       t_mem_tail.dst_valid = mem_uq.dst_valid;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end
	  LWC1:
	    begin
	       /* FP load (word): normal L1D load, result writes the FP PRF.  FR=0
		* (fp_srcB_valid): merge the loaded 32 into the jmp_imm[0] half, preserving
		* the OTHER half (fp_pres = old even-reg half read at issue), spliced at
		* writeback. */
	       t_mem_tail.op = MEM_LW;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.fp_dst = 1'b1;
	       t_mem_tail.fp_merge = mem_uq.fp_srcB_valid;
	       t_mem_tail.fp_hi = mem_uq.jmp_imm[0];
	       t_mem_tail.fp_pres = mem_uq.jmp_imm[0] ? r_fp_rd_srcB[31:0] : r_fp_rd_srcB[63:32];
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end
	  LDC1:
	    begin
	       /* FP load (dword): normal L1D load, result writes the FP PRF */
	       t_mem_tail.op = MEM_LD;
	       t_mem_tail.dst_valid = 1'b1;
	       t_mem_tail.fp_dst = 1'b1;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  SWC1:
	    begin
	       /* FP store (word): store data comes from the FP PRF via the dq */
	       t_mem_tail.op = MEM_SW;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end
	  SDC1:
	    begin
	       /* FP store (dword): store data comes from the FP PRF via the dq */
	       t_mem_tail.op = MEM_SD;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  S_STFSR:
	    begin
	       /* serializing: the FSR (r_fcsr and fcc) is the store data */
	       t_mem_tail.op = MEM_SW;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end
	  S_STDFQ:
	    begin
	       /* the FP queue is always empty (no deferred FP traps): stores 0 */
	       t_mem_tail.op = MEM_SD;
	       t_mem_tail.is_store = 1'b1;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[2:0] != 3'd0) | w_bad_seg_perms;
	    end
	  S_LDFSR:
	    begin
	       /* serializing: the response writes the FSR (r_ldfsr_*), no register */
	       t_mem_tail.op = MEM_LW;
	       t_mem_tail.dst_valid = 1'b0;
	       t_mem_tail.bad_addr = (w_agu[1:0] != 2'd0) | w_bad_seg_perms;
	    end
	  default:
	    begin
	    end
	endcase // case (mem_uq.op)
	if(r_mem_uq_commit)
	  begin
	     /* retired plain store drain: the l1d rebuilds it from its store buffer
	      * (PA, data); mark it non-faulting and cached so admission never waits
	      * on the ROB head */
	     t_mem_tail.commit = 1'b1;
	     t_mem_tail.is_store = 1'b1;
	     t_mem_tail.dst_valid = 1'b0;
	     t_mem_tail.bad_addr = 1'b0;
	     t_mem_tail.cached = 1'b1;
	     t_mem_tail.mapped = 1'b0;
	     t_mem_tail.asi = 8'h0b;
	     t_mem_tail.addr = 'd0;
	  end
     end // always_comb
   


   always_comb
     begin
	t_fwd_int_mem_srcA = t_iwb && (t_iwb_dst != 'd0) && (t_picked_mem_uop.srcA == t_iwb_dst);
	t_fwd_mem_mem_srcA = w_mem_rsp_int_valid && (t_picked_mem_uop.srcA == mem_rsp_dst_ptr);
	t_fwd_int_mem_srcC = t_iwb && (t_iwb_dst != 'd0) && (t_picked_mem_uop.srcC == t_iwb_dst);
	t_fwd_mem_mem_srcC = w_mem_rsp_int_valid && (t_picked_mem_uop.srcC == mem_rsp_dst_ptr);
     end
   
   always_ff@(posedge clk)
     begin
	r_fwd_int_mem_srcA <= t_fwd_int_mem_srcA;
	r_fwd_mem_mem_srcA <= t_fwd_mem_mem_srcA;
	if(t_fwd_int_mem_srcA)
	  begin
	     r_fwd_mem_srcA_data <= t_iwb_data;
	  end
	else if(t_fwd_mem_mem_srcA)
	  begin
	     r_fwd_mem_srcA_data <= w_mem_rsp_int_data;
	  end
	r_fwd_int_mem_srcC <= t_fwd_int_mem_srcC;
	r_fwd_mem_mem_srcC <= t_fwd_mem_mem_srcC;
	if(t_fwd_int_mem_srcC)
	  begin
	     r_fwd_mem_srcC_data <= t_iwb_data;
	  end
	else if(t_fwd_mem_mem_srcC)
	  begin
	     r_fwd_mem_srcC_data <= w_mem_rsp_int_data;
	  end
	
	r_fwd_int_srcA <= t_iwb && (t_iwb_dst != 'd0) && (t_picked_uop.srcA == t_iwb_dst);
	r_fwd_int_srcB <= t_iwb && (t_iwb_dst != 'd0) && (t_picked_uop.srcB == t_iwb_dst);
	
	r_fwd_mem_srcA <= w_mem_rsp_int_valid && (t_picked_uop.srcA == mem_rsp_dst_ptr);
	r_fwd_mem_srcB <= w_mem_rsp_int_valid && (t_picked_uop.srcB == mem_rsp_dst_ptr);

	/* capture the forwarded DATA with its flag -- int result wins if both
	 * match, mirroring the mux priority above */
	if(t_iwb && (t_iwb_dst != 'd0) && (t_picked_uop.srcA == t_iwb_dst))
	  begin
	     r_fwd_srcA_data <= t_iwb_data;
	  end
	else if(w_mem_rsp_int_valid && (t_picked_uop.srcA == mem_rsp_dst_ptr))
	  begin
	     r_fwd_srcA_data <= w_mem_rsp_int_data;
	  end
	if(t_iwb && (t_iwb_dst != 'd0) && (t_picked_uop.srcB == t_iwb_dst))
	  begin
	     r_fwd_srcB_data <= t_iwb_data;
	  end
	else if(w_mem_rsp_int_valid && (t_picked_uop.srcB == mem_rsp_dst_ptr))
	  begin
	     r_fwd_srcB_data <= w_mem_rsp_int_data;
	  end

	r_fwd_hilo_int <= r_start_int && t_wr_hilo && (t_picked_uop.hilo_src == int_uop.hilo_dst);
	r_fwd_hilo_mul <= t_hilo_prf_ptr_val_out && (t_picked_uop.hilo_src == t_hilo_prf_ptr_out);
	r_fwd_hilo_div <= 1'b0;   /* SPARC divides do not write Y */
	if(r_start_int && t_wr_hilo && (t_picked_uop.hilo_src == int_uop.hilo_dst))
	  begin
	     r_fwd_hilo_data <= t_hilo_result;
	  end
	else if(t_hilo_prf_ptr_val_out && (t_picked_uop.hilo_src == t_hilo_prf_ptr_out))
	  begin
	     r_fwd_hilo_data <= t_mul_result[63:32];
	  end
     end


`ifdef ENABLE_INT_SRCC
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_prf_zero <= '1;
	  end
	else
	  begin
	     if(t_iwb && (t_iwb_dst != 'd0))
	       begin
		  r_prf_zero[t_iwb_dst] <= (t_iwb_data == 'd0);
	       end
	     if(mem_rsp_dst_valid & ~mem_rsp_fp_dst & (mem_rsp_dst_ptr != 'd0))
	       begin
		  r_prf_zero[mem_rsp_dst_ptr] <= (w_mem_rsp_int_data == 'd0);
	       end
	  end
     end // always_ff@ (posedge clk)
`endif

   /* SPARC icc, stored beside the value in the integer PRF (uop.vh): written by
    * the icc writers' ALU writeback, read through srcC (the flags RAT's
    * register) by the readers.  Like r_prf_zero, a reader woken by the writer's
    * writeback executes the next cycle, after this write -- no bypass.  Reset 0
    * covers p0, the reset flags register. */
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_prf_icc <= '{default:4'd0};
	  end
	else if(t_iwb && t_iwb_flags && (t_iwb_dst != 'd0))
	  begin
	     r_prf_icc[t_iwb_dst] <= t_iwb_icc;
	  end
     end // always_ff@ (posedge clk)

   rf4r2w #(.WIDTH(`M_WIDTH), .LG_DEPTH(`LG_PRF_ENTRIES))
   intprf (.clk(clk),
	   .reset(reset),
	   .rdptr0(t_picked_uop.srcA),
	   .rdptr1(t_picked_uop.srcB),
	   .rdptr2(t_picked_mem_uop.srcA),
	   .rdptr3(t_sd_src),
`ifdef ENABLE_INT_SRCC
	   .rdptr4(t_picked_mem_uop.srcC),
`else
	   .rdptr4('d0),
`endif
	   .wrptr0(t_iwb_dst),
	   .wrptr1(mem_rsp_dst_ptr),
	   .wen0(t_iwb),
	   .wen1(mem_rsp_dst_valid & ~mem_rsp_fp_dst),
	   .wr0(t_iwb_data),
	   .wr1(w_mem_rsp_int_data),
	   .rd0(w_srcA),
	   .rd1(w_srcB),
	   .rd2(w_mem_srcA),
	   .rd3(w_mem_srcB),
	   .rd4(w_mem_srcC)
	   );

   

  
   always_ff@(posedge clk)
     begin
	r_src_hilo <= r_hilo_prf[t_picked_uop.hilo_src];
	
	if(r_start_int && t_wr_hilo)
	  begin
	     r_hilo_prf[int_uop.hilo_dst] <= t_hilo_result;
	  end
	else if(t_hilo_prf_ptr_val_out)
	  begin
	     r_hilo_prf[t_hilo_prf_ptr_out] <= t_mul_result[63:32];
	  end	     
     end // always_ff@ (posedge clk)

   
   
   /* FP control/status register FCR31 (FCSR): ctc1 writes it, cfc1 reads it,
    * a retiring FP op updates Cause/Flags.  CTC1 serializes, so it never
    * coincides with a retiring FP op's update (core_fcsr_we). */
   always_comb
     begin
	n_fcsr = r_fcsr;
	if(r_start_int & t_wr_fcsr)
	  begin
	     n_fcsr = t_srcA[31:0] & ~FCC_MASK;   /* FCC lives in r_fcr_prf */
	  end
	else if(t_ldfsr_wr)
	  begin
	     /* ldfsr writes RD, TEM, NS, aexc and cexc (fcc goes to r_fcr_prf);
	      * ver, ftt and qne are kept (interpret.cc FSR_LDFSR_MASK) */
	     n_fcsr = (r_fcsr & ~FSR_LD_MASK) | (mem_rsp_load_data[31:0] & FSR_LD_MASK);
	  end
	else if(core_fsr_trap)
	  begin
	     n_fcsr[16:14] = core_fsr_ftt;
	     if(core_fsr_ftt == 3'd1)
	       begin
		  n_fcsr[4:0] = sparc_exc(core_fsr_cexc5);
	       end
	  end
	else if(core_fcsr_we)
	  begin
	     n_fcsr[4:0] = sparc_exc(core_fcsr_cause6[4:0]);              /* cexc */
	     n_fcsr[9:5] = r_fcsr[9:5] | sparc_exc(core_fcsr_flags5);     /* aexc */
	     n_fcsr[16:14] = 3'd0;                                         /* ftt */
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	r_fcsr <= reset ? 32'd0 : n_fcsr;
     end // always_ff

   /* ldfsr (serializing, so alone in the machine): its load response, unless it
    * trapped, writes the FSR and its fcc register */
   logic r_ldfsr_valid;
   logic [`LG_ROB_ENTRIES-1:0] r_ldfsr_rob;
   logic [`LG_FCR_PRF_ENTRIES-1:0] r_ldfsr_fcr;
   wire w_ldfsr_issue = r_mem_ready & !r_mem_uq_commit & (mem_uq.op == S_LDFSR);
   assign t_ldfsr_wr = r_ldfsr_valid & mem_rsp_valid & (mem_rsp_rob_ptr == r_ldfsr_rob) & !mem_rsp_faulted;
   always_ff@(posedge clk)
     begin
	if(reset || t_flash_clear)
	  begin
	     r_ldfsr_valid <= 1'b0;
	  end
	else if(w_ldfsr_issue)
	  begin
	     r_ldfsr_valid <= 1'b1;
	  end
	else if(t_ldfsr_wr)
	  begin
	     r_ldfsr_valid <= 1'b0;
	  end
	if(w_ldfsr_issue)
	  begin
	     r_ldfsr_rob <= mem_uq.rob_ptr;
	     r_ldfsr_fcr <= mem_uq.hilo_dst[`LG_FCR_PRF_ENTRIES-1:0];
	  end
     end // always_ff@ (posedge clk)

   
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     complete_valid_1 <= 1'b0;
	  end
	else
	  begin
	     complete_valid_1 <= r_start_int && t_alu_valid || t_mul_complete || t_div_complete;
	  end
     end // always_ff@ (posedge clk)

   
   always_ff@(posedge clk)
     begin
	if(t_mul_complete || t_div_complete)
	  begin
	     complete_bundle_1.rob_ptr <= t_mul_complete ? t_rob_ptr_out : t_div_rob_ptr_out;
	     complete_bundle_1.complete <= 1'b1;
	     complete_bundle_1.faulted <= 1'b0;
	     complete_bundle_1.restart_pc <= 'd0;
	     complete_bundle_1.is_ii <= 1'b0;
	     complete_bundle_1.take_br <= 1'b0;
	     complete_bundle_1.overflow <= 1'b0;
	     complete_bundle_1.trap <= 1'b0;
	     /* {Y, rd}: the core reports data[63:32] as Y (retire_y_data) */
	     complete_bundle_1.data <= t_mul_complete ? `MEM_WIDTH'(t_mul_result) : `MEM_WIDTH'(w_div_rd);
	     complete_bundle_1.fwd_sel <= 2'b00;
	     complete_bundle_1.fwd_selB <= 2'b00;
	     complete_bundle_1.srcB_val <= 32'd0;
	     complete_bundle_1.hi_nzA <= 1'b0;
	     complete_bundle_1.hi_nzB <= 1'b0;
	  end
	else
	  begin
	     complete_bundle_1.rob_ptr <= int_uop.rob_ptr;
	     complete_bundle_1.complete <= t_alu_valid;
	     complete_bundle_1.faulted <= t_mispred_br || t_unimp_op || t_fault;
	     complete_bundle_1.restart_pc <= t_pc;
	     complete_bundle_1.is_ii <= t_unimp_op;
	     complete_bundle_1.take_br <= t_take_br;
	     complete_bundle_1.overflow <= t_overflow;
	     complete_bundle_1.trap <= t_trap;	     
	     complete_bundle_1.data <= {(t_wr_hilo ? t_hilo_result : 32'd0), t_result};
	     /* which source fed t_srcA for this uop -- see complete_t.fwd_sel */
	     complete_bundle_1.fwd_sel <= {r_fwd_int_srcA, r_fwd_mem_srcA};
	     /* srcB operand + its mux select, same edge as take_br/data */
	     complete_bundle_1.fwd_selB <= {r_fwd_int_srcB, r_fwd_mem_srcB};
	     complete_bundle_1.srcB_val <= t_srcB[31:0];
	     complete_bundle_1.hi_nzA <= 1'b0;   /* 32-bit: no high half */
	     complete_bundle_1.hi_nzB <= 1'b0;
	  end
	//(uq.rob_ptr == 'd5) ? 1'b1 : 1'b0;
     end
   



`ifdef VERILATOR
   /* ==================================================================
    * OPERAND VALUE CHECK (sim-only).
    *
    * The invariant the silicon violated, twice, on 2026-09-02:
    *   the source operand an instruction CONSUMES must equal the value most
    *   recently written to that physical register.
    *
    * Evidence (captures/CAPTURE_fault_20260902_{0940,1949}.txt): a `lw t9`
    * wrote 0 to physreg P; a `bnez t9` reading P took its branch (so it saw
    * NON-zero -- the encoding in the guest's own libc is `bne $25,$0`, so the
    * second operand is $zero and taken REQUIRES non-zero); a `jr t9` reading
    * the same P, with no intervening write, got 0 and jumped to 0.
    *
    * Why an assertion over real workloads and NOT a directed test: the fault
    * needs a long stall (ring `gap` = 20-57 cycles) to park a consumer on a
    * missing load so that wakeup collides with writeback.  Hand-building that
    * timing is far harder than letting a real boot produce it.  Why not formal:
    * PDR does not converge at 56k latches and BMC from reset cannot reach a
    * state that needs a full cache miss to set up.
    *
    * Unlike the formal harness this shadows EVERY physreg, so every executed
    * instruction is checked.  The two same-cycle write bypasses are modelled
    * explicitly -- without them a legitimately forwarded operand reads as a
    * mismatch, which is a false positive, not a bug.
    * ================================================================== */
   logic [`M_WIDTH-1:0] r_vchk_shadow [N_INT_PRF_ENTRIES-1:0];
   logic [N_INT_PRF_ENTRIES-1:0] r_vchk_valid;
   logic [`M_WIDTH-1:0] t_vchk_expect;
   integer 		vchk_i;

   wire w_vchk_wr0 = t_iwb & (t_iwb_dst != 'd0);
   wire w_vchk_wr1 = mem_rsp_dst_valid & (~mem_rsp_fp_dst) & (mem_rsp_dst_ptr != 'd0);

   wire w_vchk_read = r_start_int & int_uop.srcA_valid & (~int_uop.fp_srcA_valid)
		    & (int_uop.srcA != 'd0) & r_vchk_valid[int_uop.srcA];

   always_comb
     begin
	/* a write landing THIS cycle is what the operand mux is supposed to
	 * forward, so it -- not the shadow -- is the correct expectation. */
	t_vchk_expect = (w_vchk_wr1 & (mem_rsp_dst_ptr == int_uop.srcA)) ? w_mem_rsp_int_data :
			(w_vchk_wr0 & (t_iwb_dst     == int_uop.srcA)) ? t_iwb_data :
			r_vchk_shadow[int_uop.srcA];
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_vchk_valid <= 'd0;
	  end
	else
	  begin
	     if(w_vchk_wr0)
	       begin
		  r_vchk_shadow[t_iwb_dst] <= t_iwb_data;
		  r_vchk_valid[t_iwb_dst]  <= 1'b1;
	       end
	     if(w_vchk_wr1)
	       begin
		  r_vchk_shadow[mem_rsp_dst_ptr] <= w_mem_rsp_int_data;
		  r_vchk_valid[mem_rsp_dst_ptr]  <= 1'b1;
	       end

	     if(w_vchk_read & (t_srcA != t_vchk_expect))
	       begin
		  $display("[VALCHK] cyc=%0d pc=%x op=%0d srcA=p%0d GOT %x EXPECT %x  fwd_int=%b fwd_mem=%b",
			   r_cycle, int_uop.pc, int_uop.op, int_uop.srcA,
			   t_srcA, t_vchk_expect, r_fwd_int_srcA, r_fwd_mem_srcA);
		  $stop();
	       end
	  end
     end // always_ff
`endif



`ifdef VERILATOR
   /* ==================================================================
    * READER-AGREEMENT CHECK (sim-only).  dsheffie's formulation:
    *   every reader of a given physical register gets the SAME value, unless
    *   the register has been recycled (reallocated to a new producer).
    *
    * Strictly better than the value check above for this bug, because it never
    * models the WRITE path: the first reader of an allocation establishes the
    * reference and every later reader must match it.  Forwarding, bypass
    * timing and read-during-write are all irrelevant to whether two readers
    * AGREE -- which is precisely why the previous harnesses kept producing
    * false positives around same-cycle bypasses.
    *
    * This is exactly what silicon violated on 2026-09-02 (two captures):
    *   lw t9   -> physreg P
    *   bnez t9 -> reads P, branch TAKEN     => saw non-zero
    *   jr t9   -> reads P, target 0         => saw zero
    * with no write to P in between.  Physregs are written once per allocation,
    * so two readers disagreeing is impossible in a correct machine.
    *
    * Recycling: a physreg starts a new life when it is pushed as a dst.  An
    * older consumer of the previous allocation cannot still be pending at that
    * point -- the register is only freed once the overwriting instruction
    * retires, which is after every older reader has retired.
    * ================================================================== */
   logic [`M_WIDTH-1:0] r_rd_ref   [N_INT_PRF_ENTRIES-1:0];
   logic [N_INT_PRF_ENTRIES-1:0] r_rd_seen;

   wire w_rda_valid = r_start_int & int_uop.srcA_valid & (~int_uop.fp_srcA_valid)
		    & (int_uop.srcA != 'd0);

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_rd_seen <= 'd0;
	  end
	else
	  begin
	     /* recycle: a new producer claims this physreg -> drop the reference */
	     if(uq_push && uq_uop.dst_valid)
	       begin
		  r_rd_seen[uq_uop.dst] <= 1'b0;
	       end
	     if(uq_push && uq_uop.dst2_valid)
	       begin
		  r_rd_seen[uq_uop.dst2] <= 1'b0;   /* SPARC ldd: rd+1 */
	       end
	     if(uq_push_two && uq_uop_two.dst_valid)
	       begin
		  r_rd_seen[uq_uop_two.dst] <= 1'b0;
	       end

	     if(w_rda_valid)
	       begin
		  if(r_rd_seen[int_uop.srcA] == 1'b0)
		    begin
		       r_rd_ref[int_uop.srcA]  <= t_srcA;
		       r_rd_seen[int_uop.srcA] <= 1'b1;
		    end
		  else if(r_rd_ref[int_uop.srcA] != t_srcA)
		    begin
		       $display("[RDAGREE] cyc=%0d pc=%x op=%0d p%0d: first reader saw %x, this reader sees %x  (fwd_int=%b fwd_mem=%b)",
				r_cycle, int_uop.pc, int_uop.op, int_uop.srcA,
				r_rd_ref[int_uop.srcA], t_srcA, r_fwd_int_srcA, r_fwd_mem_srcA);
		       $stop();
		    end
	       end
	  end
     end // always_ff
`endif



`ifdef VERILATOR
   /* debug only: a retired store must commit and free its slot (the r_graduated
    * failure mode: one store retired but never freed wedges every flush/CACHE op).
    * Per-entry age since retirement, reset when the slot is freed or reallocated. */
   logic [31:0] r_dbg_ret_age [N_MEM_SCHED_ENTRIES-1:0];
   always_ff@(posedge clk)
     begin
	for(integer i = 0; i < N_MEM_SCHED_ENTRIES; i = i + 1)
	  begin
	     if(reset || !(t_mem_st_live[i] && r_mem_sched_ret[i]))
	       begin
		  r_dbg_ret_age[i] <= 32'd0;
	       end
	     else
	       begin
		  r_dbg_ret_age[i] <= r_dbg_ret_age[i] + 32'd1;
		  if(r_dbg_ret_age[i] == 32'd200000)
		    begin
		       $display("[STUCKST] cyc=%0d lsu slot %0d rob=%0d op=%0d retired 200K cycles ago, still live: cmt=%b sd_ok=%b",
				r_cycle, i, r_mem_sched_uops[i].rob_ptr, r_mem_sched_uops[i].op, r_mem_sched_cmt[i], r_mem_sched_sd_ok[i]);
		    end
	       end
	  end
     end
`endif
`ifdef STALL_SNAP
   /* debug: where is the ROB head, and what is it waiting on */
   always_comb
     begin
	logic t_hin_alu, t_hin_mem;
	logic [2:0] t_hai, t_hmi;
	uop_t t_hu;
	t_hin_alu = 1'b0; t_hin_mem = 1'b0; t_hai = 3'd0; t_hmi = 3'd0;
	for(integer i = 0; i < N_INT_SCHED_ENTRIES; i = i + 1)
	  begin
	     if(r_alu_sched_valid[i] && (r_alu_sched_uops[i].rob_ptr == head_of_rob_ptr))
	       begin
		  t_hin_alu = 1'b1;
		  t_hai = i[2:0];
	       end
	  end
	for(integer i = 0; i < N_MEM_SCHED_ENTRIES; i = i + 1)
	  begin
	     if(r_mem_sched_valid[i] && (r_mem_sched_uops[i].rob_ptr == head_of_rob_ptr))
	       begin
		  t_hin_mem = 1'b1;
		  t_hmi = i[2:0];
	       end
	  end
	t_hu = t_hin_alu ? r_alu_sched_uops[t_hai] : r_mem_sched_uops[t_hmi];
	dbg_exec_snap = '0;
	dbg_exec_snap[31:0] = {8'hE0, t_hin_alu, t_hai, r_alu_srcA_rdy[t_hai], r_alu_srcB_rdy[t_hai],
			       t_hu.srcA_valid, t_hu.srcB_valid, t_hin_mem, t_hmi, r_mem_sched_blk[t_hmi],
			       r_mem_sched_issued[t_hmi], t_uq_empty, t_uq_full, t_mem_uq_empty, t_mem_uq_full, r_mem_ready, 3'd0};
	dbg_exec_snap[63:32] = {1'b0, t_hu.srcA[6:0], 1'b0, t_hu.srcB[6:0], 1'b0, t_hu.dst[6:0], t_hu.op[7:0]};
	dbg_exec_snap[95:64] = {{(8-N_INT_SCHED_ENTRIES){1'b0}}, r_alu_sched_valid, {(8-N_INT_SCHED_ENTRIES){1'b0}}, t_alu_entry_rdy,
				r_mem_sched_valid, r_mem_sched_issued};
	dbg_exec_snap[127:96] = {r_mem_sched_ld, r_mem_sched_st, r_mem_sched_ret, r_mem_sched_cmt};
	for(integer i = 0; i < 8; i = i + 1)
	  begin
	     dbg_exec_snap[128 + 3*i +: 3] = r_mem_sched_blk[i];
	  end
	dbg_exec_snap[159:152] = {r_prf_inflight[t_hu.srcA], r_prf_inflight[t_hu.srcB], 6'd0};
	dbg_exec_snap[191:160] = {{(8-`LG_MQ_ENTRIES-1){1'b0}}, r_mq_head_ptr, {(8-`LG_MQ_ENTRIES-1){1'b0}}, r_mq_tail_ptr, r_mem_sched_sd_ok, r_mem_sched_ser};
	dbg_exec_snap[319:192] = r_prf_inflight;
     end
`else
   assign dbg_exec_snap = '0;
`endif
`ifdef RSTWIN_TRACE   /* VERILATOR-only: per-restart completion trace (verbose) */
   /* debug only: name every port-1 completion that lands near a restart, and time
    * the flush -> restart window.  r_dbg_st_* = what last STARTED at each rob slot. */
   logic [31:0] r_dbg_st_pc [N_ROB_ENTRIES-1:0];
   logic [8:0]  r_dbg_st_op [N_ROB_ENTRIES-1:0];
   logic [31:0] r_dbg_st_ep [N_ROB_ENTRIES-1:0];
   logic [3:0]  r_dbg_since_rc;
   logic        r_dbg_dsd;
   always_ff@(posedge clk)
     begin
	if(r_start_int)
	  begin
	     r_dbg_st_pc[int_uop.rob_ptr] <= int_uop.pc[31:0];
	     r_dbg_st_op[int_uop.rob_ptr] <= int_uop.op;
	     r_dbg_st_ep[int_uop.rob_ptr] <= int_uop.clear_id;
	  end
	r_dbg_since_rc <= reset ? 4'hf : (restart_complete ? 4'd0 : ((r_dbg_since_rc == 4'hf) ? 4'hf : (r_dbg_since_rc + 4'd1)));
	r_dbg_dsd <= reset ? 1'b0 : ds_done;
     end
   always_ff@(negedge clk)
     begin
	if(!reset && ds_done && !r_dbg_dsd)
	  $display("[RSTWIN] cyc=%0d flush starts (ds_done rises), clear_cnt=%0d r_start_int=%b int_rob=%0d op=%0d", r_cycle, clear_cnt, r_start_int, int_uop.rob_ptr, int_uop.op);
	if(!reset && restart_complete)
	  $display("[RSTWIN] cyc=%0d restart completes", r_cycle);
	if(!reset && complete_valid_1 && (r_dbg_since_rc < 4'd8))
	  $display("[RSTWIN] cyc=%0d port1 completion %0d cyc after restart: rob=%0d kind=%s op=%0d pc=%x ep=%0d cur=%0d",
		   r_cycle, r_dbg_since_rc, complete_bundle_1.rob_ptr,
		   r_dbg_mulc ? "MUL" : r_dbg_divc ? "DIV" : "ALU",
		   r_dbg_st_op[complete_bundle_1.rob_ptr], r_dbg_st_pc[complete_bundle_1.rob_ptr],
		   r_dbg_st_ep[complete_bundle_1.rob_ptr], clear_cnt);
     end
   logic r_dbg_mulc, r_dbg_divc;
   always_ff@(posedge clk)
     begin
	r_dbg_mulc <= t_mul_complete;
	r_dbg_divc <= !t_mul_complete & t_div_complete;
     end
`endif
`ifdef VERILATOR
   /* debug only: r_prf_inflight is wiped while ds_done is high, so a push in that
    * cycle loses its inflight set and its consumers read the register early */
   always_ff@(negedge clk)
     begin
	if(!reset && ds_done && ((uq_push && uq_uop.dst_valid) || (uq_push_two && uq_uop_two.dst_valid)))
	  $display("[PUSHDSDONE] cyc=%0d push with dst during ds_done: rob=%0d dst=p%0d pc=%x", r_cycle,
		   uq_push ? uq_uop.rob_ptr : uq_uop_two.rob_ptr, uq_push ? uq_uop.dst : uq_uop_two.dst, uq_push ? uq_uop.pc : uq_uop_two.pc);
     end
`endif
`ifdef VERILATOR
   /* debug only: after a restart, NO state may be changed by an op from a flushed
    * epoch (uop.clear_id != clear_cnt).  Every unit that can write state is checked;
    * units that only carry a rob_ptr look the epoch up in a dispatch-time table. */
   logic [31:0] r_dbg_ep [N_ROB_ENTRIES-1:0];
   logic        r_dbg_post;     /* between restart_complete and the next flush */
   always_ff@(posedge clk)
     begin
	if(uq_push)
	  begin
	     r_dbg_ep[uq_uop.rob_ptr] <= uq_uop.clear_id;
	  end
	if(uq_push_two)
	  begin
	     r_dbg_ep[uq_uop_two.rob_ptr] <= uq_uop_two.clear_id;
	  end
	r_dbg_post <= reset ? 1'b0 : (ds_done ? 1'b0 : (restart_complete ? 1'b1 : r_dbg_post));
     end
   always_ff@(negedge clk)
     begin
	if(!reset && r_dbg_post)
	  begin
	     if(r_start_int && (int_uop.clear_id != clear_cnt) &&
		(t_wr_int_prf || t_wr_hilo || t_mispred_br || t_alu_valid))
	       $display("[STALEEXEC] cyc=%0d ALU op=%0d pc=%x rob=%0d ep=%0d cur=%0d wr_prf=%b wr_hilo=%b mispred=%b",
			r_cycle, int_uop.op, int_uop.pc, int_uop.rob_ptr, int_uop.clear_id, clear_cnt,
			t_wr_int_prf, t_wr_hilo, t_mispred_br);
	     if(t_mul_complete && (r_dbg_ep[t_rob_ptr_out] != clear_cnt))
	       $display("[STALEEXEC] cyc=%0d MUL complete rob=%0d ep=%0d cur=%0d", r_cycle, t_rob_ptr_out, r_dbg_ep[t_rob_ptr_out], clear_cnt);
	     if(t_div_complete && (r_dbg_ep[t_div_rob_ptr_out] != clear_cnt))
	       $display("[STALEEXEC] cyc=%0d DIV complete rob=%0d ep=%0d cur=%0d", r_cycle, t_div_rob_ptr_out, r_dbg_ep[t_div_rob_ptr_out], clear_cnt);
	     if((w_fpu_result_valid || w_fpu_fcr_valid) && (r_dbg_ep[w_fpu_rob_ptr] != clear_cnt))
	       $display("[STALEEXEC] cyc=%0d FPU complete rob=%0d ep=%0d cur=%0d", r_cycle, w_fpu_rob_ptr, r_dbg_ep[w_fpu_rob_ptr], clear_cnt);
	     if(r_cvt_valid && (r_dbg_ep[r_cvt_rob] != clear_cnt))
	       $display("[STALEEXEC] cyc=%0d CVT complete rob=%0d ep=%0d cur=%0d", r_cycle, r_cvt_rob, r_dbg_ep[r_cvt_rob], clear_cnt);
	     if(w_fdiv_complete && (r_dbg_ep[w_fdiv_rob_ptr] != clear_cnt))
	       $display("[STALEEXEC] cyc=%0d FDIV complete rob=%0d ep=%0d cur=%0d", r_cycle, w_fdiv_rob_ptr, r_dbg_ep[w_fdiv_rob_ptr], clear_cnt);
	     if(r_sd_go && (r_dbg_ep[r_sd_rob] != clear_cnt))
	       $display("[STALEEXEC] cyc=%0d SD capture rob=%0d ep=%0d cur=%0d", r_cycle, r_sd_rob, r_dbg_ep[r_sd_rob], clear_cnt);
	     if(mem_rsp_valid && (r_dbg_ep[mem_rsp_rob_ptr] != clear_cnt))
	       $display("[STALEEXEC] cyc=%0d MEM rsp rob=%0d ep=%0d cur=%0d dst_valid=%b", r_cycle, mem_rsp_rob_ptr, r_dbg_ep[mem_rsp_rob_ptr], clear_cnt, mem_rsp_dst_valid);
	  end
     end
`endif
endmodule
