`include "machine.vh"
`include "rob.vh"
`include "uop.vh"

`ifdef VERILATOR
import "DPI-C" function void record_fetch(int push1, int push2, int push3, int push4,
					  longint pc0, longint pc1, longint pc2, longint pc3,
					  int bubble, int fq_full);

`endif





module compute_pht_idx(pc, idx);
   input logic [`M_WIDTH-1:0] pc;
   output logic [`LG_PHT_SZ-1:0]   idx;

   /* the PHT is the PC-indexed bimodal (history goes to the tagged tables), indexed
    * per 16B LINE (bit 4 up): the entry holds a counter for each of the 4 slots */
   assign idx = pc[`LG_PHT_SZ+3:4];
   
endmodule

module l1i(clk,
	   state,
	   reset,
	   flush_req,
	   flush_complete,
	   flush_line_req,
	   flush_line_idx,
	   flush_line_complete,
	   blk_inv_req,
	   blk_inv_addr,
	   blk_inv_line,
	   blk_inv_done,
	   restart_pc,
	   restart_npc,
	   restart_npc_valid,
	   dbg_arch_hist,
	   dbg_spec_hist,
	   restart_valid,
	   restart_ack,
	   retire_valid,
	   retired_call,
	   retired_ret,
	   retire_reg_ptr,
	   retire_reg_data,
	   retire_reg_valid,
	   branch_pc_valid,
	   branch_pc,
	   branch_target,
	   branch_is_indirect,
	   took_branch,
	   branch_fault,
	   branch_bpu_idx,
	   
	   insn,
	   insn_valid,
	   insn_ack,
	   
	   insn_two,
	   insn_valid_two,
	   insn_ack_two,
	   
	   //output to the memory system
	   mem_req_ack,
	   mem_req_valid,
	   mem_req_addr,
	   mem_req_opcode,
	   mem_req_cacheable,
	   mem_req_mask,
	   //reply from memory system
	   mem_rsp_valid,
	   mem_rsp_load_data,
	   cache_accesses,
	   cache_hits,
	   mmu_ctrl_e,
	   mmu_ctrl_bm,
	   mmu_ctx,
	   tlb_flush,
	   psr_s,
	   page_walk_req_valid,
	   page_walk_req_va,
	   page_walk_rsp_valid,
	   page_walk_rsp
	   );

   input logic clk;
   /* SRMMU: enable, context, PSR.S (the fetch ASI 0x8/0x9 for the ACC check), the
    * itlb's walk request (a pulse; the VA is held until the response) and its
    * response */
   input logic mmu_ctrl_e;
   input logic mmu_ctrl_bm;   /* Viking boot mode: MMU-off fetches come from the PROM */
   input logic [`SRMMU_CTX_BITS-1:0] mmu_ctx;
   input logic tlb_flush;   /* clear the itlb (mmu.sv: a ctrl/ctpr write) */
   input logic psr_s;
   output logic page_walk_req_valid;
   output logic [31:0] page_walk_req_va;
   input logic page_walk_rsp_valid;
   input page_walk_rsp_t page_walk_rsp;
   output logic [3:0] state;
   
   input logic reset;
   
   input logic 	      flush_req;
   output logic       flush_complete;
   /* per-line invalidate (I-side CACHE ops): clear both ways of one set, instead of
    * the whole-cache flush above.  Separate handshake, so the L1/L2 flush sequencers
    * never see it. */
   input logic 	      flush_line_req;
   input logic [`LG_L1I_NUM_SETS-1:0] flush_line_idx;
   output logic       flush_line_complete;
   /* R10000 block op, from the L2: clear the 128-byte block's 8 sets at every colour
    * (the kernel may name the block by an address of another colour) in the
    * background -- through the valid arrays' write port, giving way to fills and to a
    * flush -- while fetch carries on.  blk_inv_done pulses when all are clear. */
   input logic 	      blk_inv_req;
   input logic [`PA_WIDTH-1:0] blk_inv_addr;
   /* with blk_inv_req: only the line at blk_inv_addr, at every colour (the L2's
    * coherence drop before an L1D fill or write-around) -- 1 cycle per colour */
   input logic 	      blk_inv_line;
   output logic       blk_inv_done;
   //restart signals
   input logic [`M_WIDTH-1:0] restart_pc;
   /* SPARC jmpl;rett: the restart's NEXT pc -- fetch one instruction at
    * restart_pc, then continue at restart_npc (a restart into a delay slot) */
   input logic [`M_WIDTH-1:0] restart_npc;
   input logic 	      restart_npc_valid;
   /* Global history, read back over the existing trace-index debug port.
    * ARCH is the RETIRED history (updated at branch retirement); SPEC is the
    * speculative copy the PHT is actually indexed with.  Dumping BOTH lets a
    * capture test whether speculative history was correctly restored after a
    * squash (n_spec_gbl_hist = n_arch_gbl_hist) -- if it was not, later
    * predictions index the wrong PHT entry, which no per-instruction pht_idx
    * can reveal. */
   output logic [63:0]        dbg_arch_hist;
   output logic [63:0]        dbg_spec_hist;
   input logic 	      restart_valid;
   output logic       restart_ack;
   //return stack signals
   input logic 			retire_valid;
   input logic 			retired_call;
   input logic 			retired_ret;

   input logic [`LG_PRF_ENTRIES-1:0] retire_reg_ptr;
   input logic [`M_WIDTH-1:0]	retire_reg_data;
   input logic 			retire_reg_valid;

   input logic 			branch_pc_valid;
   input logic [`M_WIDTH-1:0] 		branch_pc;
   input logic [`M_WIDTH-1:0] 		branch_target;      /* retiring indirect jump's target */
   input logic 				branch_is_indirect;
   
   input logic 			took_branch;
   input logic 			branch_fault;
   
   input logic [`LG_BPU_TBL_SZ-1:0] branch_bpu_idx;

   
   output insn_fetch_t insn;
   output logic insn_valid;
   input logic 	insn_ack;
   
   output 	insn_fetch_t insn_two;
   output logic insn_valid_two;
   input logic 	insn_ack_two;

   input logic 	mem_req_ack;
   output logic mem_req_valid;
   
   localparam L1I_NUM_SETS = 1 << `LG_L1I_NUM_SETS;
   localparam L1I_CL_LEN = 1 << `LG_L1D_CL_LEN;
   localparam L1I_CL_LEN_BITS = 1 << (`LG_L1D_CL_LEN + 3);
   localparam LG_WORDS_PER_CL = `LG_L1D_CL_LEN - 2;
   localparam WORDS_PER_CL = 1<<LG_WORDS_PER_CL;
   localparam IDX_START = `LG_L1D_CL_LEN;
   localparam IDX_STOP  = `LG_L1D_CL_LEN + `LG_L1I_NUM_SETS;
   /* VIPT alias handling (mirrors l1d): take the tag down to LG_PG_SZ so it CARRIES
    * the alias bits VA[12..] that the index uses but translation changes.  Cache <=
    * page (IDX_STOP<=LG_PG_SZ): TAG_LSB==IDX_STOP -> identical to the old tag (no-op).
    * Cache > page: the widened tag makes an aliased VA-indexed fetch MISS, and the
    * fill is VA-indexed (r_miss_pc, below) so the reload re-lookup finds it.  Read-only
    * cache: a synonym just makes a harmless duplicate line at the other index -- no
    * writeback / physical-retry needed (unlike l1d's dirty case). */
   localparam TAG_LSB = (IDX_STOP < `LG_PG_SZ) ? IDX_STOP : `LG_PG_SZ;
   localparam LG_ALIAS_BITS = IDX_STOP - TAG_LSB;   // == max(0, IDX_STOP - LG_PG_SZ)
   localparam N_TAG_BITS = `PA_WIDTH - TAG_LSB;
   localparam WORD_START = 2;
   localparam WORD_STOP = WORD_START+LG_WORDS_PER_CL;
   localparam N_FQ_ENTRIES = 1 << `LG_FQ_ENTRIES;
   localparam RETURN_STACK_ENTRIES = 1 << `LG_RET_STACK_ENTRIES;
   localparam PHT_ENTRIES = 1 << `LG_PHT_SZ;
   localparam BTB_ENTRIES = 1 << `LG_BTB_SZ;

   output logic [(`PA_WIDTH-1):0] mem_req_addr;
   output logic [5:0] 			  mem_req_opcode;
   output logic				  mem_req_cacheable;
   output logic [15:0]			  mem_req_mask;
   
   input logic 				  mem_rsp_valid;
   input logic [L1I_CL_LEN_BITS-1:0] 	  mem_rsp_load_data;
   output logic [63:0] 			  cache_accesses;
   output logic [63:0] 			  cache_hits;
      
   logic [N_TAG_BITS-1:0] 		  t_cache_tag, r_cache_tag, r_tag_out0, r_tag_out1;

   logic 				  r_pht_update;
   /* PHT entry holds FOUR packed 2-bit counters, one per instruction slot in the
    * 16B line (rv64core l1i_2way parity).  Previously one 2-bit counter indexed at
    * 8-byte granularity, so ADJACENT instructions aliased onto the same counter --
    * and, more importantly, only the first slot's prediction was consulted when
    * forming a fetch group, so a not-taken branch anywhere in the line truncated
    * it.  LG_PHT_SZ drops 16->14 to keep total storage identical (2^14 x 8 bits ==
    * 2^16 x 2 bits = 128Kbit); the bits-per-predicted-branch is unchanged at 2. */
   logic [7:0] 				  r_pht_out_vec, r_pht_update_out;
   logic [1:0] 				  t_pht_out;
   logic [7:0] 				  t_pht_val_vec;
   logic [1:0] 				  t_pht_val;
   logic 				  t_do_pht_wr;
   /* per-slot "is a predicted-TAKEN control transfer" */
   logic 				  t_tcb0, t_tcb1, t_tcb2, t_tcb3;
   logic [1:0] 				  r_pht_update_slot;
   logic [1:0] 				  t_pht_old;
   
   logic [`LG_PHT_SZ-1:0] 		  n_pht_idx,r_pht_idx;
   logic [`LG_PHT_SZ-1:0] 		  r_pht_update_idx;
   logic [`LG_PHT_SZ-1:0] 		  t_retire_pht_idx;
   /* branch-predictor update state kept in the front end: every pushed fetch group
    * writes its PHT index here and its insns carry only r_bpu_idx (rv64core 291b0cb).
    * At retire the core hands back branch_bpu_idx and the PHT index is looked up. */
   localparam N_BPU_TBL = 1 << `LG_BPU_TBL_SZ;
   logic [`LG_PHT_SZ-1:0] 		  r_bpu_tbl[N_BPU_TBL-1:0];
   logic [`LG_BPU_TBL_SZ-1:0] 		  r_bpu_idx;
   logic 				  t_bpu_alloc;
   /* per-slot predicted direction: the bimodal/gshare counter MSBs, with the tagged
    * table's slot overridden on a hit */
   logic [3:0] 				  t_pred_vec;
   /* tagged table entry: [16] valid, [15:7] tag, [6:5] slot, [4:2] 3b ctr, [1:0] useful */
   localparam T1_W = 1 + `TAGE_TAG_W + 2 + 3 + 2;
   localparam N_T1 = 1 << `LG_TAGE_SZ;
   logic [`LG_TAGE_SZ-1:0] 		  t_t1_n_idx, r_t1_idx;
   logic [`TAGE_TAG_W-1:0] 		  t_t1_n_tag, r_t1_tag;
   logic [T1_W-1:0] 			  r_t1_out;
   logic 				  t_t1_hit;
   /* per fetch group, in the front end */
   logic [`LG_TAGE_SZ-1:0] 		  r_bpu_t1_idx[N_BPU_TBL-1:0];
   logic [`TAGE_TAG_W-1:0] 		  r_bpu_t1_tag[N_BPU_TBL-1:0];
   logic 				  r_bpu_t1_hit[N_BPU_TBL-1:0];
   logic [T1_W-1:0] 			  r_bpu_t1_ent[N_BPU_TBL-1:0];
   /* retire stage (aligned with r_pht_update_out) */
   logic [`LG_TAGE_SZ-1:0] 		  r_t1u_idx;
   logic [`TAGE_TAG_W-1:0] 		  r_t1u_tag;
   logic 				  r_t1u_hit;
   logic [T1_W-1:0] 			  r_t1u_ent;
   logic 				  t_t1_provider, t_t1_wr;
   logic [T1_W-1:0] 			  t_t1_wr_data;
   logic [2:0] 				  t_t1_ctr;
   logic [1:0] 				  t_t1_u;
   /* T2: same geometry, long (48b) history */
   logic [`LG_TAGE_SZ-1:0] 		  t_t2_n_idx, r_t2_idx;
   logic [`TAGE_TAG_W-1:0] 		  t_t2_n_tag, r_t2_tag;
   logic [T1_W-1:0] 			  r_t2_out;
   logic 				  t_t2_hit;
   logic [`LG_TAGE_SZ-1:0] 		  r_bpu_t2_idx[N_BPU_TBL-1:0];
   logic [`TAGE_TAG_W-1:0] 		  r_bpu_t2_tag[N_BPU_TBL-1:0];
   logic 				  r_bpu_t2_hit[N_BPU_TBL-1:0];
   logic [T1_W-1:0] 			  r_bpu_t2_ent[N_BPU_TBL-1:0];
   logic [`LG_TAGE_SZ-1:0] 		  r_t2u_idx;
   logic [`TAGE_TAG_W-1:0] 		  r_t2u_tag;
   logic 				  r_t2u_hit;
   logic [T1_W-1:0] 			  r_t2u_ent;
   logic 				  t_t2_provider, t_t2_wr;
   logic [T1_W-1:0] 			  t_t2_wr_data;
   logic [2:0] 				  t_t2_ctr;
   logic [1:0] 				  t_t2_u;
   logic 				  t_prov_pred, t_alt_pred, t_t1_free, t_t2_free;
   
   logic 				  r_take_br;
   
   logic [(`M_WIDTH-1):0] 		  r_btb[BTB_ENTRIES-1:0];
   logic [BTB_ENTRIES-1:0] 		  r_btb_valid;
   
   
   logic [(4*WORDS_PER_CL)-1:0] 	  r_jump_out0, r_jump_out1, t_jump_out;
   
   logic [`LG_L1I_NUM_SETS-1:0] 	    t_cache_idx, r_cache_idx;   
   logic [L1I_CL_LEN_BITS-1:0] 		    r_array_out0, r_array_out1, t_array_out;
   logic 				    r_mem_req_valid, n_mem_req_valid;
   logic [(`PA_WIDTH-1):0] r_mem_req_addr, n_mem_req_addr;
   logic				    r_mem_req_cacheable,n_mem_req_cacheable;
   
   

   /* 2-wide fetch queue in two banks: entry i lives in bank i[0] at row i>>1.  The
    * (at most two) pushes per cycle and the two decode reads are always consecutive
    * entries, so each bank sees one write and one read per cycle (1W1R -> LUTRAM). */
   localparam N_FQ_ROWS = N_FQ_ENTRIES/2;
   insn_fetch_t r_fq_b0[N_FQ_ROWS-1:0];
   insn_fetch_t r_fq_b1[N_FQ_ROWS-1:0];
   
   logic [`LG_FQ_ENTRIES:0] r_fq_head_ptr, n_fq_head_ptr;
   logic [`LG_FQ_ENTRIES:0] r_fq_next_head_ptr, n_fq_next_head_ptr;
   logic [`LG_FQ_ENTRIES:0] r_fq_next_tail_ptr, n_fq_next_tail_ptr;
   
   logic [`LG_FQ_ENTRIES:0] r_fq_tail_ptr, n_fq_tail_ptr;
   logic 		    r_resteer_bubble, n_resteer_bubble;
   /* WAIT_FOR_TLB: r_iw_mine = this wait's walk is out (a walk left over from
    * before a restart is waited out first), r_iw_done = it answered last cycle
    * (the itlb has the entry this cycle), r_ihold = a faulting fetch was pushed:
    * fetch nothing more until the restart */
   logic 		    r_iw_mine, n_iw_mine;
   logic 		    r_iw_done;
   logic 		    r_ihold, n_ihold;
   
   
   logic 		    fq_full, fq_next_empty, fq_empty;
   logic 		    fq_full2;
   
   
   logic [(`M_WIDTH-1):0]   r_spec_return_stack [RETURN_STACK_ENTRIES-1:0];
   logic [(`M_WIDTH-1):0]   r_arch_return_stack [RETURN_STACK_ENTRIES-1:0];
   logic [`LG_RET_STACK_ENTRIES-1:0] n_arch_rs_tos, r_arch_rs_tos;
   logic [`LG_RET_STACK_ENTRIES-1:0] n_spec_rs_tos, r_spec_rs_tos, t_next_spec_rs_tos;   
   
   logic [`GBL_HIST_LEN-1:0] 	     n_arch_gbl_hist, r_arch_gbl_hist;
   logic [`GBL_HIST_LEN-1:0] 	     n_spec_gbl_hist, r_spec_gbl_hist;
   assign dbg_arch_hist = {{(64-`GBL_HIST_LEN){1'b0}}, r_arch_gbl_hist};
   assign dbg_spec_hist = {{(64-`GBL_HIST_LEN){1'b0}}, r_spec_gbl_hist};

   logic [`GBL_HIST_LEN-1:0] 	     r_last_spec_gbl_hist;
   

   logic [LG_WORDS_PER_CL-1:0] 	     t_insn_idx;
   
   logic [63:0] 			 n_cache_accesses, r_cache_accesses;
   logic [63:0] 			 n_cache_hits, r_cache_hits;
   
function logic [31:0] select_cl32(logic [L1I_CL_LEN_BITS-1:0] cl, logic[LG_WORDS_PER_CL-1:0] pos);
   logic [31:0] 			 w32;
   case(pos)
     2'd0:
       w32 = cl[31:0];
     2'd1:
       w32 = cl[63:32];
     2'd2:
       w32 = cl[95:64];
     2'd3:
       w32 = cl[127:96];
   endcase // case (pos)
   return w32;
endfunction

function logic [3:0] select_pd(logic [15:0] cl, logic[LG_WORDS_PER_CL-1:0] pos);
   logic [3:0] j;
   case(pos)
     2'd0:
       j = cl[3:0];
     2'd1:
       j = cl[7:4];
     2'd2:
       j = cl[11:8];
     2'd3:
       j = cl[15:12];
   endcase // case (pos)
   return j;
endfunction

   
   typedef enum logic [3:0] {INITIALIZE = 'd0,
			     IDLE = 'd1,
                             ACTIVE = 'd2,
                             INJECT_RELOAD = 'd3,
			     RELOAD_TURNAROUND = 'd4,
                             FLUSH_CACHE = 'd5,
			     WAIT_FOR_NOT_FULL = 'd6,
			     INIT_PHT = 'd7,
			     WAIT_FOR_TLB = 'd8
			    } state_t;
   
   logic [(`M_WIDTH-1):0] r_pc, n_pc, r_miss_pc, n_miss_pc;
   logic [(`M_WIDTH-1):0] r_cache_pc, n_cache_pc;
   logic [(`M_WIDTH-1):0] r_btb_pc;
   /* BTB: PC-indexed last target, the default indirect predictor; its index is recorded
    * per fetch group so retire trains the entry it predicted from */
   logic [`LG_BTB_SZ-1:0] t_btb_n_idx, r_btb_idx;
   logic [`LG_BTB_SZ-1:0] r_bpu_btb_idx[N_BPU_TBL-1:0];
   /* mini-ITTAGE: one tagged table {valid, tag, 2b conf, target} indexed by pc ^ global
    * history; on a tag hit it overrides the BTB for an indirect jump.  Allocated only when
    * the BTB mispredicts, so monomorphic jumps stay in the BTB.  Blind-written at retire
    * from the fetch-group metadata, like the TAGE tables. */
   localparam ITT_W = 1 + `ITT_TAG_W + 2 + `M_WIDTH;
   logic [`LG_ITT_SZ-1:0] t_itt_n_idx, r_itt_idx;
   logic [`ITT_TAG_W-1:0] t_itt_n_tag, r_itt_tag;
   logic [ITT_W-1:0] 	  r_itt_out, t_itt_wr_data;
   logic 		  t_itt_hit, t_itt_wr;
   logic [`LG_ITT_SZ-1:0] r_bpu_itt_idx[N_BPU_TBL-1:0];
   logic [`ITT_TAG_W-1:0] r_bpu_itt_tag[N_BPU_TBL-1:0];
   logic 		  r_bpu_itt_hit[N_BPU_TBL-1:0];
   logic [ITT_W-1:0] 	  r_bpu_itt_ent[N_BPU_TBL-1:0];   /* the slot as read at fetch */
   logic [`LG_ITT_SZ-1:0] t_ittu_idx;
   logic [`ITT_TAG_W-1:0] t_ittu_tag;
   logic 		  t_ittu_hit;
   logic [1:0] 		  t_ittu_conf;
   logic [ITT_W-1:0] 	  t_ittu_ent;

   wire [`M_WIDTH-1:0]		  w_la_pc;
   wire [`PA_WIDTH-1:0] w_tlb_pc;
   
   
   
   
   
   state_t n_state, r_state;
   assign state = r_state;
   
   logic 		  r_restart_req, n_restart_req;
   logic 		  r_restart_ack, n_restart_ack;
   logic 		  r_npc_pend, n_npc_pend;
   logic [`M_WIDTH-1:0]   r_npc, n_npc, r_npc_l1, n_npc_l1;
   logic 		  r_req, n_req;
   logic 		  r_valid_out0, r_valid_out1;
   /* L1I way select / replacement: r_lru_out = the set's LRU way (read with the arrays),
    * r_fill_way = the way the outstanding reload writes */
   logic 		  r_lru_out, r_fill_way, n_fill_way;
   logic 		  t_lru_wr, t_lru_val;
   logic [`LG_L1I_NUM_SETS-1:0] t_lru_idx;
   logic 		  t_miss, t_hit;
   logic 		  t_push_insn, t_push_insn2;
   
   logic 		  t_clear_fq;
   logic 		  r_flush_req, n_flush_req;
   logic 		  r_flush_complete, n_flush_complete;
   logic 		  r_fline_req, n_fline_req;      /* a per-line invalidate is pending */
   logic [`LG_L1I_NUM_SETS-1:0] r_fline_idx, n_fline_idx;
   logic 		  r_fline_one, n_fline_one;      /* FLUSH_CACHE clears just one set */
   logic 		  r_fline_complete, n_fline_complete;
   logic 		  n_delay_slot, r_delay_slot;
   logic 		  t_take_br, t_is_cflow;
   logic 		  t_update_spec_hist;
   
   logic [31:0] 	  t_insn_data, t_insn_data2;
   logic [`M_WIDTH-1:0]   t_simm;
   logic 		  t_is_call, t_is_ret;
   logic [2:0] 		  t_branch_cnt;
   logic [4:0] 		  t_branch_marker, t_spec_branch_marker;
   logic [2:0] 		  t_first_branch;
   /* branch pair: a predicted-taken direct branch in slot 1 of the fetch group is
    * pushed together with the insn before it; its delay slot is fetched next */
   logic [3:0] 		  t_gb_pd1;
   logic 		  t_gb_ok1;
   logic 		  t_gb_take1;
   logic [`M_WIDTH-1:0]   t_gb_pc1, t_gb_target1;
   logic [`M_WIDTH-1:0]   t_gb_simm1;

   logic 		  t_init_pht;
   logic [`LG_PHT_SZ-1:0] r_init_pht_idx, n_init_pht_idx;
   

   
   //always_ff@(negedge clk)
   //begin
   //$display("r_cache_pc = %x, t_branch_locs = %b, t_insn_idx = %d, t_branch_marker = %b, first_branch = %d",
   //r_cache_pc,t_branch_locs, t_insn_idx, t_branch_marker, t_first_branch);
   //end
   
   
   insn_fetch_t t_insn, t_insn2;
   logic [3:0] t_pd, r_pd;

   
   logic [63:0] 	  r_cycle;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : r_cycle + 'd1;
     end


   assign flush_complete = r_flush_complete;
   assign flush_line_complete = r_fline_complete;

   localparam BINV_CNT_BITS = LG_ALIAS_BITS + 3;   /* {colour, line in the block} */
   logic 		  r_binv_busy, n_binv_busy;
   logic [BINV_CNT_BITS-1:0] r_binv_cnt, n_binv_cnt;
   logic [`LG_PG_SZ-8:0]  r_binv_off, n_binv_off;   /* the block's offset in the page */
   logic 		  r_binv_done;
   logic 		  r_binv_line, n_binv_line;   /* one line, every colour */
   /* the last {colour, line} of the walk: every colour of a line, or the whole block */
   wire 		  w_binv_last = r_binv_line ? ((r_binv_cnt | BINV_CNT_BITS'(7)) == {BINV_CNT_BITS{1'b1}}) :
			  (r_binv_cnt == {BINV_CNT_BITS{1'b1}});
   logic 		  t_binv_fire;
   logic [31:0] 	  t_binv_va;
   assign blk_inv_done = r_binv_done;
   always_comb
     begin
	/* the set of {colour, block offset, line}: a VA with those bits, indexed as fetch does */
	t_binv_va = {{(32-`LG_PG_SZ){1'b0}}, r_binv_off, r_binv_cnt[2:0], 4'd0} |
		    (({{(32-BINV_CNT_BITS){1'b0}}, r_binv_cnt} >> 3) << `LG_PG_SZ);
	t_binv_fire = r_binv_busy && !mem_rsp_valid && (r_state != FLUSH_CACHE);
	n_binv_busy = r_binv_busy;
	n_binv_cnt = r_binv_cnt;
	n_binv_off = r_binv_off;
	n_binv_line = r_binv_line;
	if(blk_inv_req)
	  begin
	     n_binv_busy = 1'b1;
	     /* a line drop starts at colour 0 of its line; a block drop at line 0 */
	     n_binv_cnt = blk_inv_line ? BINV_CNT_BITS'(blk_inv_addr[6:4]) : 'd0;
	     n_binv_off = blk_inv_addr[`LG_PG_SZ-1:7];
	     n_binv_line = blk_inv_line;
	  end
	else if(t_binv_fire)
	  begin
	     /* a line drop steps the colour only (the line is cnt[2:0]) */
	     n_binv_cnt = r_binv_cnt + (r_binv_line ? BINV_CNT_BITS'(8) : BINV_CNT_BITS'(1));
	     n_binv_busy = !w_binv_last;
	  end
     end // always_comb
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_binv_busy <= 1'b0;
	     r_binv_cnt <= 'd0;
	     r_binv_off <= 'd0;
	     r_binv_done <= 1'b0;
	     r_binv_line <= 1'b0;
	  end
	else
	  begin
	     r_binv_busy <= n_binv_busy;
	     r_binv_cnt <= n_binv_cnt;
	     r_binv_off <= n_binv_off;
	     r_binv_line <= n_binv_line;
	     r_binv_done <= t_binv_fire && w_binv_last;
	  end
     end // always_ff
   
   assign insn_valid = !fq_empty;
   assign insn_valid_two = !(fq_next_empty || fq_empty);

   
   assign restart_ack = r_restart_ack;

   assign mem_req_valid = r_mem_req_valid;
   assign mem_req_addr = r_mem_req_addr;
   assign mem_req_opcode = MEM_LW;
   assign mem_req_cacheable = r_mem_req_cacheable;
   assign mem_req_mask = 16'hffff;
   
   assign cache_hits = r_cache_hits;
   assign cache_accesses = r_cache_accesses;
   
   always_comb
     begin
	n_fq_tail_ptr = r_fq_tail_ptr;
	n_fq_head_ptr = r_fq_head_ptr;
	n_fq_next_head_ptr = r_fq_next_head_ptr;
	n_fq_next_tail_ptr = r_fq_next_tail_ptr;
	
	fq_empty = (r_fq_head_ptr == r_fq_tail_ptr);
	fq_next_empty = (r_fq_next_head_ptr == r_fq_tail_ptr);
	
	fq_full = (r_fq_head_ptr != r_fq_tail_ptr) &&
		  (r_fq_head_ptr[`LG_FQ_ENTRIES-1:0] == r_fq_tail_ptr[`LG_FQ_ENTRIES-1:0]);
	
	fq_full2 = (r_fq_head_ptr != r_fq_next_tail_ptr) &&
		   (r_fq_head_ptr[`LG_FQ_ENTRIES-1:0] == r_fq_next_tail_ptr[`LG_FQ_ENTRIES-1:0]) || fq_full;
	
	/* head and next_head are consecutive entries, so they sit in opposite banks */
	insn = r_fq_head_ptr[0] ? r_fq_b1[r_fq_head_ptr[`LG_FQ_ENTRIES-1:1]] :
	       r_fq_b0[r_fq_head_ptr[`LG_FQ_ENTRIES-1:1]];
	insn_two = r_fq_next_head_ptr[0] ? r_fq_b1[r_fq_next_head_ptr[`LG_FQ_ENTRIES-1:1]] :
		   r_fq_b0[r_fq_next_head_ptr[`LG_FQ_ENTRIES-1:1]];

	if(t_push_insn2)
	  begin
	     n_fq_tail_ptr = r_fq_tail_ptr + 'd2;
	     n_fq_next_tail_ptr = r_fq_next_tail_ptr + 'd2;
	  end
	else if(t_push_insn)
	  begin
	     n_fq_tail_ptr = r_fq_tail_ptr + 'd1;
	     n_fq_next_tail_ptr = r_fq_next_tail_ptr + 'd1;
	  end
	
	if(insn_ack && !insn_ack_two)
	  begin
	     n_fq_head_ptr = r_fq_head_ptr + 'd1;
	     n_fq_next_head_ptr = r_fq_next_head_ptr + 'd1;
	  end
	else if(insn_ack && insn_ack_two)
	  begin
	     n_fq_head_ptr = r_fq_head_ptr + 'd2;
	     n_fq_next_head_ptr = r_fq_next_head_ptr + 'd2;
	  end
     end // always_comb

   /* bank write port: the tail entry goes to bank tail[0]; a second push goes to
    * the other bank at next_tail's row */
   logic 		  t_fq_wr0, t_fq_wr1;
   logic [`LG_FQ_ENTRIES-2:0] t_fq_wr_row0, t_fq_wr_row1;
   insn_fetch_t t_fq_wr_data0, t_fq_wr_data1;
   always_comb
     begin
	t_fq_wr0 = 1'b0;
	t_fq_wr1 = 1'b0;
	t_fq_wr_row0 = r_fq_tail_ptr[`LG_FQ_ENTRIES-1:1];
	t_fq_wr_row1 = r_fq_tail_ptr[`LG_FQ_ENTRIES-1:1];
	t_fq_wr_data0 = t_insn;
	t_fq_wr_data1 = t_insn;
	if(t_push_insn | t_push_insn2)
	  begin
	     if(r_fq_tail_ptr[0])
	       begin
		  t_fq_wr1 = 1'b1;
		  t_fq_wr_row1 = r_fq_tail_ptr[`LG_FQ_ENTRIES-1:1];
		  t_fq_wr_data1 = t_insn;
		  t_fq_wr0 = t_push_insn2;
		  t_fq_wr_row0 = r_fq_next_tail_ptr[`LG_FQ_ENTRIES-1:1];
		  t_fq_wr_data0 = t_insn2;
	       end
	     else
	       begin
		  t_fq_wr0 = 1'b1;
		  t_fq_wr_row0 = r_fq_tail_ptr[`LG_FQ_ENTRIES-1:1];
		  t_fq_wr_data0 = t_insn;
		  t_fq_wr1 = t_push_insn2;
		  t_fq_wr_row1 = r_fq_next_tail_ptr[`LG_FQ_ENTRIES-1:1];
		  t_fq_wr_data1 = t_insn2;
	       end
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(t_fq_wr0)
	  begin
	     r_fq_b0[t_fq_wr_row0] <= t_fq_wr_data0;
	  end
	if(t_fq_wr1)
	  begin
	     r_fq_b1[t_fq_wr_row1] <= t_fq_wr_data1;
	  end
     end // always_ff@ (posedge clk)

   /* mini-ITTAGE lookup + retire update.  Entry layout: [ITT_W-1] valid,
    * [ITT_W-2 -: ITT_TAG_W] tag, [M_WIDTH+1:M_WIDTH] conf, [M_WIDTH-1:0] target. */
   always_comb
     begin
	t_itt_hit = r_itt_out[ITT_W-1] && (r_itt_out[ITT_W-2:`M_WIDTH+2] == r_itt_tag);
	t_ittu_idx = r_bpu_itt_idx[branch_bpu_idx];
	t_ittu_tag = r_bpu_itt_tag[branch_bpu_idx];
	t_ittu_hit = r_bpu_itt_hit[branch_bpu_idx];
	t_ittu_ent = r_bpu_itt_ent[branch_bpu_idx];
	t_ittu_conf = t_ittu_ent[`M_WIDTH+1:`M_WIDTH];
	t_itt_wr = 1'b0;
	t_itt_wr_data = {1'b1, t_ittu_tag, t_ittu_conf, branch_target};
	if(t_init_pht)
	  begin
	     t_itt_wr = 1'b1;
	     t_itt_wr_data = 'd0;
	  end
	else if(branch_pc_valid && branch_is_indirect)
	  begin
	     if(t_ittu_hit)
	       begin
		  /* the ITT provided: confirm, or weaken and finally replace the target */
		  t_itt_wr = 1'b1;
		  if(!branch_fault)
		    begin
		       t_itt_wr_data = {1'b1, t_ittu_tag, (t_ittu_conf == 2'd3) ? 2'd3 : t_ittu_conf + 2'd1, branch_target};
		    end
		  else if(t_ittu_conf != 2'd0)
		    begin
		       t_itt_wr_data = {t_ittu_ent[ITT_W-1:`M_WIDTH+2], t_ittu_conf - 2'd1, t_ittu_ent[`M_WIDTH-1:0]};
		    end
		  else
		    begin
		       t_itt_wr_data = {1'b1, t_ittu_tag, 2'd0, branch_target};
		    end
	       end
	     else if(branch_fault)
	       begin
		  /* the BTB provided and missed: allocate here (if the slot is free), else age it */
		  t_itt_wr = 1'b1;
		  t_itt_wr_data = (!t_ittu_ent[ITT_W-1] || (t_ittu_conf == 2'd0)) ?
				  {1'b1, t_ittu_tag, 2'd0, branch_target} :
				  {t_ittu_ent[ITT_W-1:`M_WIDTH+2], t_ittu_conf - 2'd1, t_ittu_ent[`M_WIDTH-1:0]};
	       end
	  end
     end

   ram1r1w #(.WIDTH(ITT_W), .LG_DEPTH(`LG_ITT_SZ)) itt
     (
      .clk(clk),
      .rd_addr(t_itt_n_idx),
      .wr_addr(t_init_pht ? r_init_pht_idx[`LG_ITT_SZ-1:0] : t_ittu_idx),
      .wr_data(t_itt_wr_data),
      .wr_en(t_itt_wr),
      .rd_data(r_itt_out)
      );

   always_ff@(posedge clk)
     begin
	if(reset) 
	  begin
	     r_btb_valid <= 'd0;
	  end
	else if(branch_pc_valid && branch_is_indirect)
	  begin
	     r_btb_valid[r_bpu_btb_idx[branch_bpu_idx]] <= 1'b1;
	  end
     end // always_ff@ (posedge clk)

   
   always_ff@(posedge clk)
     begin
	/* train on every retired indirect jump (not just at a mispredict's restart),
	 * at the index its fetch group looked up */
	if(branch_pc_valid && branch_is_indirect)
	  begin
	     r_btb[r_bpu_btb_idx[branch_bpu_idx]] <= branch_target;
	  end	
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	/* cold/invalid entry -> POISON, not zero: see BTB_POISON_PC in machine.vh */
	r_btb_pc <= reset ? `BTB_POISON_PC : 
		    r_btb_valid[t_btb_n_idx] ? r_btb[t_btb_n_idx] : `BTB_POISON_PC;
	r_btb_idx <= t_btb_n_idx;
	r_itt_idx <= t_itt_n_idx;
	r_itt_tag <= t_itt_n_tag;
	
     end


   /* SRMMU itlb: looked up with the next fetch pc, so its (registered) outputs
    * line up with r_cache_pc.  MMU off: PA = VA, cached. */
   wire 		w_itlb_hit, w_itlb_c, w_itlb_m;
   wire [2:0] 		w_itlb_acc;
   wire [1:0] 		w_itlb_level;
   wire [`PA_WIDTH-1:0] w_itlb_pa;
   logic 		r_xlate;
   logic 		r_bmode;
   logic 		t_itlb_replace;
   tlb #(.N(`N_ITLB_ENTRIES), .ID(1)) itlb(
				   .clk(clk),
				   .reset(reset),
				   .clear(tlb_flush),
				   .active(mmu_ctrl_e),
				   .ctx(mmu_ctx),
				   .req(1'b1),
				   .va(n_cache_pc[31:0]),
				   .pa(w_itlb_pa),
				   .hit(w_itlb_hit),
				   .acc(w_itlb_acc),
				   .level(w_itlb_level),
				   .c(w_itlb_c),
				   .m(w_itlb_m),
				   .replace(t_itlb_replace),
				   .replace_va(r_iwalk_va),
				   .page_walk_rsp(page_walk_rsp),
				   .set_m(1'b0),
				   .set_m_va(32'd0)
				   );
   always_ff@(posedge clk)
     begin
	r_xlate <= reset ? 1'b0 : mmu_ctrl_e;
	r_bmode <= reset ? 1'b0 : (!mmu_ctrl_e & mmu_ctrl_bm);
     end
   /* boot mode (MCR.E = 0, BM = 1): the fetch reads the PROM, PROM_PA |
    * va[18:0] (the untranslated itlb pa is the va) */
   assign w_tlb_pc = r_bmode ? (`SUN4M_PROM_PA | `PA_WIDTH'(w_itlb_pa[18:0])) : w_itlb_pa;

   /* the fetch's verdict: an itlb miss walks; a hit needs execute permission
    * (interpret.cc mmu_xlate: user ACC 2-4, supervisor ACC 2-4 and 6-7) */
   wire 		w_ix = psr_s ? ((w_itlb_acc[2:1] == 2'b01) | (w_itlb_acc == 3'd4) | (w_itlb_acc[2:1] == 2'b11)) :
			((w_itlb_acc[2:1] == 2'b01) | (w_itlb_acc == 3'd4));
   wire 		w_itlb_miss1 = r_xlate & !w_itlb_hit;
   wire 		w_iperm_fault = r_xlate & w_itlb_hit & !w_ix;
   /* no fetch from device space but the PROM (machine.vh SUN4M_IFETCH_PA) */
   wire 		w_idev_fault = r_xlate & w_itlb_hit & w_ix & !`SUN4M_IFETCH_PA(w_tlb_pc);

   /* the walk, one at a time; a faulting walk leaves its verdict in a one-entry
    * fault cache the refetch consumes (single use, as in the l1d) */
   logic 		r_iwalk_busy, n_iwalk_busy;
   logic 		r_iwalk_req, n_iwalk_req;
   logic [31:0] 	r_iwalk_va, n_iwalk_va;
   logic 		r_ifc_valid, n_ifc_valid;
   /* a walk outstanding across a fetch restart: its fault is not cached (it may
    * have read a PTE the OS has since made valid -- an invalid PTE needs no TLB
    * flush on SRMMU, so nothing else would tell us) */
   logic 		r_iwalk_stale, n_iwalk_stale;
   logic [19:0] 	r_ifc_vpn;
   logic [2:0] 		r_ifc_ft;
   logic [1:0] 		r_ifc_level;
   logic 		t_iwalk_start, t_ifc_use;
   wire 		w_ifc_hit = r_ifc_valid & (r_ifc_vpn == r_cache_pc[31:12]);
   /* this fetch faults: a cached walk fault for its page, no execute permission,
    * or a device-space page */
   wire 		w_ifault = r_req & ((w_itlb_miss1 & w_ifc_hit) | w_iperm_fault | w_idev_fault);
   assign page_walk_req_valid = r_iwalk_req;
   assign page_walk_req_va = r_iwalk_va;

   always_comb
     begin
	n_iwalk_busy = r_iwalk_busy;
	n_iwalk_req = 1'b0;
	n_iwalk_va = r_iwalk_va;
	/* a cached walk fault is only for the fetch that caused the walk: any fetch
	 * restart (trap, rett, mispredict) drops it, else a fault seen on a
	 * speculative path -- e.g. fetching a trap handler's return target before
	 * the handler has fixed the PTE -- traps a later, correct fetch */
	n_ifc_valid = r_ifc_valid & !t_ifc_use & !restart_valid;
	n_iwalk_stale = (r_iwalk_stale | (r_iwalk_busy & restart_valid)) & r_iwalk_busy;
	t_itlb_replace = 1'b0;
	if(t_iwalk_start)
	  begin
	     n_iwalk_busy = 1'b1;
	     n_iwalk_req = 1'b1;
	     n_iwalk_va = r_miss_pc[31:0];
	     n_ifc_valid = 1'b0;
	     n_iwalk_stale = 1'b0;
	  end
	if(page_walk_rsp_valid)
	  begin
	     n_iwalk_busy = 1'b0;
	     t_itlb_replace = !page_walk_rsp.fault;
	     n_ifc_valid = page_walk_rsp.fault & !r_iwalk_stale & !restart_valid;
	     n_iwalk_stale = 1'b0;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	r_iwalk_busy <= reset ? 1'b0 : n_iwalk_busy;
	r_iwalk_req <= reset ? 1'b0 : n_iwalk_req;
	r_ifc_valid <= reset ? 1'b0 : n_ifc_valid;
	r_iwalk_stale <= reset ? 1'b0 : n_iwalk_stale;
	r_iwalk_va <= n_iwalk_va;
	r_iw_done <= reset ? 1'b0 : (page_walk_rsp_valid & r_iw_mine);
	if(page_walk_rsp_valid)
	  begin
	     r_ifc_vpn <= r_iwalk_va[31:12];
	     r_ifc_ft <= page_walk_rsp.ft;
	     r_ifc_level <= page_walk_rsp.level;
	  end
     end // always_ff@ (posedge clk)
   
   wire w_hit0 = r_valid_out0 & (r_tag_out0 == w_tlb_pc[(`PA_WIDTH-1):TAG_LSB]);
   wire w_hit1 = r_valid_out1 & (r_tag_out1 == w_tlb_pc[(`PA_WIDTH-1):TAG_LSB]);
   always_comb
     begin
	t_array_out = w_hit1 ? r_array_out1 : r_array_out0;
	t_jump_out = w_hit1 ? r_jump_out1 : r_jump_out0;
     end
   //always@(negedge clk)
   //begin
   //if(r_req)
   //begin
   //$display("w_tlb_pc %x, hit %b, r_cache_tag %x",
   //w_tlb_pc[31:IDX_STOP], w_hit, r_cache_tag);
   //
   //
   //end
   //end
   always_comb
     begin
	n_pc = r_pc;
	n_miss_pc = r_miss_pc;
	n_fill_way = r_fill_way;
	n_cache_pc = 'd0;
	n_state = r_state;
	n_restart_ack = 1'b0;
	n_npc_pend = r_npc_pend;
	n_npc = r_npc;
	n_npc_l1 = r_npc_l1;
	n_flush_req = r_flush_req | flush_req;
	n_fline_req = r_fline_req | flush_line_req;
	n_fline_idx = flush_line_req ? flush_line_idx : r_fline_idx;
	n_fline_one = r_fline_one;
	n_fline_complete = 1'b0;
	n_flush_complete = 1'b0;
	n_delay_slot = r_delay_slot;
	t_cache_idx = 'd0;
	t_cache_tag = 'd0;
	n_req = 1'b0;
	n_mem_req_valid = 1'b0;
	n_mem_req_addr = r_mem_req_addr;
	n_mem_req_cacheable = r_mem_req_cacheable;
	
	n_resteer_bubble = 1'b0;
	n_iw_mine = r_iw_mine;
	n_ihold = r_ihold;
	t_iwalk_start = 1'b0;
	t_ifc_use = 1'b0;
	t_next_spec_rs_tos = r_spec_rs_tos+'d1;
	n_restart_req = restart_valid | r_restart_req;

	/* an itlb miss or fault: no cache hit/miss (WAIT_FOR_TLB walks, or the
	 * fetch is pushed as an instruction_access_exception) */
	if(w_itlb_miss1 || w_iperm_fault)
	  begin
	     t_miss = 1'b0;
	     t_hit  = 1'b0;
	  end
	else
	  begin
	     t_miss = r_req & !(w_hit0 | w_hit1);
	     t_hit  = r_req & (w_hit0 | w_hit1);
	  end

	t_insn_idx = r_cache_pc[WORD_STOP-1:WORD_START];
	
	t_pd = select_pd(t_jump_out, t_insn_idx);

	t_insn_data  = select_cl32(t_array_out, t_insn_idx);
	t_insn_data2 = select_cl32(t_array_out, t_insn_idx + 2'd1);


	t_branch_marker = {1'b1,
			   select_pd(t_jump_out, 'd3) != 4'd0,
                           select_pd(t_jump_out, 'd2) != 4'd0,
                           select_pd(t_jump_out, 'd1) != 4'd0,
                           select_pd(t_jump_out, 'd0) != 4'd0
                           } >> t_insn_idx;

	/* the 2-bit counter for the instruction actually being fetched */
	/* only the MSB (the direction) is consumed; the LSB stays the bimodal's */
	t_pht_out = (t_insn_idx == 2'd0) ? {t_pred_vec[0], r_pht_out_vec[0]} :
		    (t_insn_idx == 2'd1) ? {t_pred_vec[1], r_pht_out_vec[2]} :
		    (t_insn_idx == 2'd2) ? {t_pred_vec[2], r_pht_out_vec[4]} :
		    {t_pred_vec[3], r_pht_out_vec[6]};

	/* Predicted-TAKEN per slot: a conditional branch (pd==1) predicted not-taken
	 * does NOT end the fetch group, and neither does a non-branch.  This is the
	 * whole point -- the old marker used (pd != 0), so ~7-8% of instructions
	 * (not-taken conditional branches) truncated a group for no reason. */
	t_tcb0 = ~((((select_pd(t_jump_out, 'd0) == 4'd1) & ~t_pred_vec[0]) |
		    (select_pd(t_jump_out, 'd0) == 4'd0)));
	t_tcb1 = ~((((select_pd(t_jump_out, 'd1) == 4'd1) & ~t_pred_vec[1]) |
		    (select_pd(t_jump_out, 'd1) == 4'd0)));
	t_tcb2 = ~((((select_pd(t_jump_out, 'd2) == 4'd1) & ~t_pred_vec[2]) |
		    (select_pd(t_jump_out, 'd2) == 4'd0)));
	t_tcb3 = ~((((select_pd(t_jump_out, 'd3) == 4'd1) & ~t_pred_vec[3]) |
		    (select_pd(t_jump_out, 'd3) == 4'd0)));

	t_spec_branch_marker = ({1'b1, t_tcb3, t_tcb2, t_tcb1, t_tcb0} >> t_insn_idx);

	
	t_first_branch = 'd7;
	casez(t_spec_branch_marker)
	  5'b????1:
	    t_first_branch = 'd0;
	  5'b???10:
	    t_first_branch = 'd1;
	  5'b??100:
	    t_first_branch = 'd2;
	  5'b?1000:
	    t_first_branch = 'd3;
	  5'b10000:
	    t_first_branch = 'd4;
	  default:
	    t_first_branch = 'd7;
	endcase

	/* branch pair: the first predicted-taken insn is slot 1 (relative to
	 * t_insn_idx) and is a direct branch -- conditional (1, predicted taken by
	 * the same counter t_tcb* used), likely (2), j (3), b (8).  Calls (5/9)
	 * push the return stack with their own pc and BTB/return targets (4/6/7)
	 * are looked up for the head slot, so those keep the branch-alone path.
	 * [slot 0, branch] are pushed together; the delay slot (next 16B line when
	 * idx == 2) is fetched sequentially next cycle, then the target. */
	t_gb_pd1 = select_pd(t_jump_out, t_insn_idx + 2'd1);
	t_gb_pc1 = r_cache_pc + 'd4;
	t_gb_simm1 = {{(`M_WIDTH-24){t_insn_data2[21]}}, t_insn_data2[21:0], 2'd0};
	t_gb_target1 = t_gb_pc1 + t_gb_simm1;
	/* a b<cond>,a (2) pairs only when predicted taken: predicted not taken, it
	 * skips its slot, which the branch-alone path below does */
	t_gb_ok1 = (t_first_branch == 'd1) && (t_insn_idx <= 2'd2) && !fq_full2 &&
		   ((t_gb_pd1 == 4'd1) || ((t_gb_pd1 == 4'd2) && t_pred_vec[t_insn_idx + 2'd1]) ||
		    (t_gb_pd1 == 4'd3) || (t_gb_pd1 == 4'd8));

	t_branch_cnt = {2'd0, select_pd(t_jump_out, 'd0) != 4'd0} +
		       {2'd0, select_pd(t_jump_out, 'd1) != 4'd0} +
		       {2'd0, select_pd(t_jump_out, 'd2) != 4'd0} +
		       {2'd0, select_pd(t_jump_out, 'd3) != 4'd0};
	
		
	/* SPARC Bicc/FBfcc: the byte displacement sext(disp22)*4, from the branch's own pc */
	t_simm = {{(`M_WIDTH-24){t_insn_data[21]}}, t_insn_data[21:0], 2'd0};
	t_clear_fq = 1'b0;
	t_push_insn = 1'b0;
	t_push_insn2 = 1'b0;
	t_take_br = 1'b0;
	t_is_cflow = 1'b0;
	t_gb_take1 = 1'b0;
	t_update_spec_hist = 1'b0;
	t_is_call = 1'b0;
	t_is_ret = 1'b0;
	t_init_pht = 1'b0;
	n_init_pht_idx = r_init_pht_idx;
	
	case(r_state)
	  INITIALIZE:
	    begin
	       n_state = INIT_PHT;
	    end
	  INIT_PHT:
	    begin
	       t_init_pht = 1'b1;
	       n_init_pht_idx = r_init_pht_idx + 'd1;
	       if(r_init_pht_idx == (PHT_ENTRIES-1))
		 begin
		    n_state = FLUSH_CACHE;	       
		    t_cache_idx = 0;
		 end
	    end
	  IDLE:
	    begin
	       if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_pc = restart_pc;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end
	    end	  
	  ACTIVE:
	    begin
	       t_cache_idx = r_pc[IDX_STOP-1:IDX_START];
	       t_cache_tag = N_TAG_BITS'(r_pc[(`M_WIDTH-1):TAG_LSB]);
	       /* accessed with this address */
	       n_cache_pc = r_pc;
	       n_req = 1'b1;
	       n_pc = r_pc + 'd4;
	       /* a restart into a delay slot (jmpl;rett): the restart pc is looked up
		* now, the one after it is restart_npc, and it is consumed as a delay
		* slot (pushed alone) */
	       if(r_npc_pend && (r_pc == r_npc_l1))
		 begin
		    n_pc = r_npc;
		    n_delay_slot = 1'b1;
		    n_npc_pend = 1'b0;
		 end
	       if(r_resteer_bubble)
		 begin
		    //do nothing?
		 end
	       else if(n_flush_req)
		 begin
		    n_flush_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = 0;
		 end
	       else if(n_fline_req)
		 begin
		    n_fline_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = n_fline_idx;
		    n_fline_one = 1'b1;
		 end
	       else if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_delay_slot = 1'b0;
		    n_pc = restart_pc;
		    n_req = 1'b0;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end // if (n_restart_req)
	       else if(w_itlb_miss1 && r_req && !w_ifc_hit)
		 begin
		    /* itlb miss: walk in WAIT_FOR_TLB, then re-present the fetch.
		     * r_pc (may be a branch target for a delay-slot fetch) is held. */
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_iw_mine = 1'b0;
		    n_state = WAIT_FOR_TLB;
		 end
	       else if(r_req && r_cache_pc[1:0] != 2'b00 && !fq_full)
		 begin
		    t_push_insn = 1'b1;
		    n_pc = r_cache_pc + 'd4;
		 end
	       else if(r_req && r_cache_pc[1:0] != 2'b00 && fq_full)
		 begin
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_state = WAIT_FOR_NOT_FULL;
		 end
	       else if(w_ifault && !fq_full)
		 begin
		    /* instruction_access_exception: push the faulting fetch alone and
		     * fetch nothing more until the trap restarts us */
		    t_push_insn = 1'b1;
		    t_ifc_use = w_itlb_miss1;
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_ihold = 1'b1;
		    n_state = WAIT_FOR_TLB;
		 end
	       else if(w_ifault && fq_full)
		 begin
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_state = WAIT_FOR_NOT_FULL;
		 end
	       else if(t_miss)
		 begin
		    n_state = INJECT_RELOAD;
		    n_mem_req_addr = {w_tlb_pc[`PA_WIDTH-1:`LG_L1D_CL_LEN],
				      {`LG_L1D_CL_LEN{1'b0}}};
		    n_mem_req_cacheable = w_itlb_c;
		    n_mem_req_valid = 1'b1;
		    n_miss_pc = r_cache_pc;
		    n_pc = r_pc;
		    /* victim: an invalid way first, else the set's LRU way */
		    n_fill_way = !r_valid_out0 ? 1'b0 : !r_valid_out1 ? 1'b1 : r_lru_out;
		 end
	       else if(t_hit && !fq_full)
		 begin
		    t_update_spec_hist = (t_pd != 4'd0);
		    if(t_pd == 4'd5 || t_pd == 4'd3)
		      begin
			 t_is_cflow = 1'b1;
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 t_is_call = (t_pd == 4'd5);
			 //if(t_is_call) $display("predict jal at %x will return to %x",
			 //r_cache_pc, r_cache_pc+'d8);
			 n_pc = r_cache_pc + {t_insn_data[29:0], 2'd0};   /* call: pc + disp30*4 */
		      end
		    else if(t_pd == 4'd10)
		      begin
			 /* ba,a: a jump with no delay slot -- straight to the target.
			  * The array is already reading the next sequential insn (r_pc);
			  * a delay-slot branch consumes that read as its slot, but here it
			  * is the wrong path: drop it (n_req = 0), and the next cycle looks
			  * up the target.  (Pushing it ran pc+4 after the jump: the branch
			  * unit checks only the direction, so it retired.) */
			 t_is_cflow = 1'b1;
			 t_take_br = 1'b1;
			 n_pc = r_cache_pc + t_simm;
			 n_req = 1'b0;
		      end
		    else if(t_pd == 4'd8)
		      begin
			 t_is_cflow = 1'b1;			 
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 n_pc = r_cache_pc + t_simm;
		      end
		    else if(t_pd == 4'd2)
		      begin
			 /* b<cond>,a: predicted by the PHT like a=0 conditionals.  Taken:
			  * the slot, then the target.  Not taken, the slot is annulled:
			  * skip it, as ba,a skips its slot (drop the sequential read,
			  * fetch pc + 8; decode then gives the branch no slot and a taken
			  * outcome restarts into it, core.sv annul_skip).  A b<cond>,a
			  * that is itself a delay slot (a DCTI couple) stays predicted
			  * taken: core.sv's couple restart reads a slot-less branch as ba,a */
			 t_is_cflow = 1'b1;
			 if(t_pht_out[1] | r_delay_slot)
			   begin
			      n_delay_slot = 1'b1;
			      t_take_br = 1'b1;
			      n_pc = r_cache_pc + t_simm;
			   end
			 else
			   begin
			      n_pc = r_cache_pc + 'd8;
			      n_req = 1'b0;
			   end
		      end
		    else if(t_pd == 4'd9)
		      begin
			 /* REGIMM branch-and-link: rt 16 BLTZAL / 17 BGEZAL / 18 BLTZALL /
			  * 19 BGEZALL.  The rs==$zero shortcut below means "this is the
			  * unconditional-call idiom, always taken" -- but that is only true
			  * for the BGEZ-flavours (rs>=0).  For the BLTZ-flavours rs<0 is
			  * NEVER true when rs==$zero, so predicting them taken would be
			  * exactly backwards.  rt bit0 (insn[16]) selects: 1 = BGEZ-type,
			  * 0 = BLTZ-type. */
			 if(t_pht_out[1] || (t_insn_data[16] && t_insn_data[25:21] == 5'd0))
			   begin
			      t_is_cflow = 1'b1;
			      n_delay_slot = 1'b1;			      
			      n_pc = r_cache_pc + t_simm;
			      t_is_call = 1'b1;
			      t_take_br = 1'b1;
			      //$display("some flavor of branch and link, predicting target %x", n_pc);
			   end
		      end
		    else if(t_pd == 4'd1 && t_pht_out[1])
		      begin
			 t_is_cflow = 1'b1;			 
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 n_pc = r_cache_pc + t_simm;
			 //if(t_insn_idx != 'd3 && !fq_full2)
			 //begin
			 //t_push_insn2 = 1'b1;
			 //n_resteer_bubble = 1'b1;
			 //n_delay_slot = 1'b0;
			 // end
		      end
		    else if(t_pd == 4'd7)
		      begin
			 t_is_cflow = 1'b1;
			 t_is_ret = 1'b1;
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 n_pc = r_spec_return_stack[t_next_spec_rs_tos];
		      end // if (t_pd == 4'd7)
		    else if(t_pd == 4'd4 || t_pd == 4'd6)
		      begin
			 t_is_cflow = 1'b1;			 
			 n_delay_slot = 1'b1;
			 t_take_br = 1'b1;
			 t_is_call = (t_pd == 4'd6);
			 n_pc = t_itt_hit ? r_itt_out[`M_WIDTH-1:0] : r_btb_pc;
			 //$display("predicted target for %x is %x", r_cache_pc, n_pc);			 
		      end
		    
		    if(r_delay_slot)
		      begin
			 n_delay_slot = 1'b0;
		      end
		    
		    //initial push multiple logic
		    if(!(t_is_cflow || r_delay_slot))
		      begin
			 /* the array was read sequentially this cycle, so the target
			  * costs one resteer bubble (vs. two single-insn cycles for
			  * the branch and its delay slot on the branch-alone path) */
			 if(t_gb_ok1)
			   begin
			      /* [slot 0, taken branch]: fetch the delay slot next, then the
			       * target (r_pc), exactly as the branch-alone path does */
			      t_push_insn2 = 1'b1;
			      t_gb_take1 = 1'b1;
			      t_update_spec_hist = 1'b1;
			      n_delay_slot = 1'b1;
			      n_cache_pc = r_cache_pc + 'd8;
			      t_cache_tag = N_TAG_BITS'(n_cache_pc[(`M_WIDTH-1):TAG_LSB]);
			      n_pc = t_gb_target1;
			      if(t_insn_idx == 2'd2)
				begin
				   t_cache_idx = r_cache_idx + 'd1;
				end
			   end
			 else if(t_first_branch >= 'd2 && !fq_full2)
			   begin
			      /* two sequential insns (no predicted-taken cflow among them);
			       * idx <= 2 here since the 16B line end bounds t_first_branch */
			      t_push_insn2 = 1'b1;
			      n_cache_pc = r_cache_pc + 'd8;
			      t_cache_tag = N_TAG_BITS'(n_cache_pc[(`M_WIDTH-1):TAG_LSB]);
			      n_pc = r_cache_pc + 'd12;
			      if(t_insn_idx == 2'd2)
				begin
				   t_cache_idx = r_cache_idx + 'd1;
				end
			   end
			 else
			   begin
			      t_push_insn = 1'b1;
			   end
		      end // if (!(t_is_cflow || r_delay_slot))
		    //else if(t_is_cflow && !r_delay_slot && t_insn_idx != 'd3 && !fq_full2)
		    //begin
		    //branch delay slot is on the same cacheline
		    //end
		    else
		      begin
			 t_push_insn = 1'b1;
		      end
		 end // if (t_hit && !fq_full)
	       else if(t_hit && fq_full)
		 begin
		    //$display("full insn queue at cycle %d", r_cycle);
		    n_pc = r_pc;
		    n_miss_pc = r_cache_pc;
		    n_state = WAIT_FOR_NOT_FULL;
		 end
	    end
	  INJECT_RELOAD:
	    begin
	       if(mem_rsp_valid)
		 begin
		    n_state = RELOAD_TURNAROUND;
		 end
	    end
	  RELOAD_TURNAROUND:
	    begin
	       t_cache_idx = r_miss_pc[IDX_STOP-1:IDX_START];
	       t_cache_tag = N_TAG_BITS'(r_miss_pc[(`M_WIDTH-1):TAG_LSB]);
	       if(n_flush_req)
		 begin
		    n_flush_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = 0;
		 end
	       else if(n_fline_req)
		 begin
		    n_fline_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = n_fline_idx;
		    n_fline_one = 1'b1;
		 end
	       else if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_delay_slot = 1'b0;
		    n_pc = restart_pc;
		    n_req = 1'b0;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end // if (n_restart_req)
	       else if(!fq_full)
		 begin
		    /* accessed with this address */
		    n_cache_pc = r_miss_pc;
		    n_req = 1'b1;
		    n_state = ACTIVE;
		 end
	    end
	  FLUSH_CACHE:
	    begin
	       if(r_fline_one)
		 begin
		    /* per-line invalidate: this cycle cleared set r_cache_idx (both ways) */
		    n_fline_one = 1'b0;
		    n_fline_complete = 1'b1;
		    n_state = IDLE;
		 end
	       else if(r_cache_idx == (L1I_NUM_SETS-1))
		 begin
		    //$display("REQ FLUSHING COMPLETE at %d", r_cycle);
		    n_flush_complete = 1'b1;
		    n_state = IDLE;
		 end
	       t_cache_idx = r_cache_idx + 'd1;
	    end
	  WAIT_FOR_NOT_FULL:
	    begin
	       t_cache_idx = r_miss_pc[IDX_STOP-1:IDX_START];
	       t_cache_tag = N_TAG_BITS'(r_miss_pc[(`M_WIDTH-1):TAG_LSB]);
	       n_cache_pc = r_miss_pc;
	       if(!fq_full)
		 begin
		    n_req = 1'b1;
		    n_state = ACTIVE;
		 end
	       else if(n_flush_req)
		 begin
		    n_flush_req = 1'b0;
		    //n_flush_complete = 1'b1;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = 0;		    
		 end
	       else if(n_fline_req)
		 begin
		    n_fline_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = n_fline_idx;
		    n_fline_one = 1'b1;
		 end
	       else if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_delay_slot = 1'b0;
		    n_pc = restart_pc;
		    n_req = 1'b0;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		 end // if (n_restart_req)
	    end
	  WAIT_FOR_TLB:
	    begin
	       /* an itlb miss: walk for r_miss_pc (after any walk left over from
		* before a restart has answered), then re-present it the cycle after
		* the response, when the itlb holds the entry.  Or (r_ihold) a faulting
		* fetch went out: wait for the restart. */
	       n_pc = r_pc;
	       if(n_flush_req)
		 begin
		    n_flush_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = 0;
		    n_iw_mine = 1'b0;
		    n_ihold = 1'b0;
		 end
	       else if(n_fline_req)
		 begin
		    n_fline_req = 1'b0;
		    t_clear_fq = 1'b1;
		    n_state = FLUSH_CACHE;
		    t_cache_idx = n_fline_idx;
		    n_fline_one = 1'b1;
		    n_iw_mine = 1'b0;
		    n_ihold = 1'b0;
		 end
	       else if(n_restart_req)
		 begin
		    n_restart_ack = 1'b1;
		    n_restart_req = 1'b0;
		    n_delay_slot = 1'b0;
		    n_pc = restart_pc;
		    n_req = 1'b0;
		    n_state = ACTIVE;
		    t_clear_fq = 1'b1;
		    n_iw_mine = 1'b0;
		    n_ihold = 1'b0;
		 end
	       else if(r_ihold)
		 begin
		 end
	       else if(r_iw_done)
		 begin
		    t_cache_idx = r_miss_pc[IDX_STOP-1:IDX_START];
		    t_cache_tag = N_TAG_BITS'(r_miss_pc[(`M_WIDTH-1):TAG_LSB]);
		    n_cache_pc = r_miss_pc;
		    n_req = 1'b1;
		    n_iw_mine = 1'b0;
		    n_state = ACTIVE;
		 end
	       else if(!r_iw_mine && !r_iwalk_busy)
		 begin
		    t_iwalk_start = 1'b1;
		    n_iw_mine = 1'b1;
		 end
	    end
	  default:
	    begin
	    end
	endcase // case (r_state)
	if(n_restart_ack)
	  begin
	     n_npc_pend = restart_npc_valid;
	     n_npc = restart_npc;
	     n_npc_l1 = restart_pc;
	  end
     end // always_comb

   always_comb
     begin
	n_cache_accesses = r_cache_accesses;
	n_cache_hits = r_cache_hits;	
	if(t_hit)
	  begin
	     n_cache_hits = r_cache_hits + 'd1;
	  end
	if(r_req)
	  begin
	     n_cache_accesses = r_cache_accesses + 'd1;
	  end
     end
   
   always_comb
     begin
	t_insn.data = t_insn_data;
	t_insn.misaligned  = r_req & (r_cache_pc[1:0] != 2'b00);
	t_insn.tlb_miss    = w_ifault & (r_cache_pc[1:0] == 2'b00);
	t_insn.bad_va      = 1'b0;
	t_insn.mmu.fault   = w_ifault;
	t_insn.mmu.ft      = w_itlb_miss1 ? r_ifc_ft :
			     (!psr_s && (w_itlb_acc[2:1] == 2'b11)) ? FT_PRIVILEGE : FT_PROTECTION;
	t_insn.mmu.level   = w_itlb_miss1 ? r_ifc_level : w_itlb_level;
	t_insn.mmu.at      = {1'b0, 1'b1, psr_s};
	t_insn.pc = r_cache_pc;
	t_insn.pred_target = n_pc;
	t_insn.pred = t_take_br;
	t_insn.bpu_idx = r_bpu_idx;
	t_insn.is_branch = (t_pd != 4'd0) && (t_pd != 4'd10) &&   /* a delay slot follows */
			   !((t_pd == 4'd2) && !t_take_br);         /* (not a skipped b<cond>,a slot) */
`ifdef	ENABLE_CYCLE_ACCOUNTING
	t_insn.fetch_cycle = r_cycle;
`endif
	t_insn2.data = t_insn_data2;
	t_insn2.misaligned = 1'b0;
	t_insn2.tlb_miss = 1'b0;
	t_insn2.bad_va = 1'b0;
	t_insn2.mmu = '0;
	t_insn2.pc = r_cache_pc + 'd4;
	t_insn2.pred_target = t_gb_take1 ? n_pc : 'd0;
	t_insn2.pred = t_gb_take1;
	/* same 16B line as slot 0 -> SAME PHT entry (the slot is disambiguated at
	 * retire by branch_pc[3:2]).  Was 'd0: harmless while the fetch group
	 * truncated at any branch (slots 2-4 could never BE branches), but with
	 * predicted-taken grouping they can, and they then trained entry 0 -- 2.85
	 * -> 18.8 mispredicts/kiloinsn. */
	t_insn2.bpu_idx = r_bpu_idx;
	t_insn2.is_branch = (select_pd(t_jump_out, t_insn_idx + 2'd1) != 4'd0) &&
			    (select_pd(t_jump_out, t_insn_idx + 2'd1) != 4'd10);
`ifdef	ENABLE_CYCLE_ACCOUNTING
	t_insn2.fetch_cycle = r_cycle;
`endif
     end // always_comb
   
   logic t_wr_valid_ram_en0, t_wr_valid_ram_en1, t_valid_ram_value;
   logic [`LG_L1I_NUM_SETS-1:0] t_valid_ram_idx;

   
   compute_pht_idx cpi0 (.pc(n_cache_pc), .idx(n_pht_idx));

   always_comb
     begin
	t_pred_vec = {r_pht_out_vec[7], r_pht_out_vec[5], r_pht_out_vec[3], r_pht_out_vec[1]};
	/* tagged table: index/tag from the same pc + history the PHT index uses, so the
	 * registered read lines up with r_cache_pc.  Fold is written for 16b history,
	 * 10b index, 9b tag. */
	t_t1_n_idx = n_cache_pc[`LG_TAGE_SZ+3:4] ^ r_spec_gbl_hist[9:0] ^ {4'd0, r_spec_gbl_hist[15:10]};
	t_btb_n_idx = n_cache_pc[(`LG_BTB_SZ+1):2];
	/* mini-ITTAGE: word pc ^ the newest 16 history bits (as T1), separate tag fold */
	t_itt_n_idx = n_cache_pc[`LG_ITT_SZ+1:2] ^ r_spec_gbl_hist[7:0] ^ r_spec_gbl_hist[15:8];
	t_itt_n_tag = n_cache_pc[`LG_ITT_SZ+`ITT_TAG_W+1:`LG_ITT_SZ+2] ^ r_spec_gbl_hist[15:7] ^ {r_spec_gbl_hist[6:0], 2'd0};
	t_t1_n_tag = n_cache_pc[`LG_TAGE_SZ+`TAGE_TAG_W+3:`LG_TAGE_SZ+4] ^ r_spec_gbl_hist[15:7] ^
		     {r_spec_gbl_hist[6:0], 2'd0};
	/* T2 folds all 48 history bits (5 index chunks, 6 tag chunks, offset) */
	t_t2_n_idx = n_cache_pc[`LG_TAGE_SZ+3:4] ^ r_spec_gbl_hist[9:0] ^ r_spec_gbl_hist[19:10] ^
		     r_spec_gbl_hist[29:20] ^ r_spec_gbl_hist[39:30] ^ {2'd0, r_spec_gbl_hist[47:40]};
	t_t2_n_tag = n_cache_pc[`LG_TAGE_SZ+`TAGE_TAG_W+3:`LG_TAGE_SZ+4] ^ r_spec_gbl_hist[47:39] ^
		     r_spec_gbl_hist[38:30] ^ r_spec_gbl_hist[29:21] ^ r_spec_gbl_hist[20:12] ^
		     r_spec_gbl_hist[11:3] ^ {r_spec_gbl_hist[2:0], 6'd0};
	t_t1_hit = r_t1_out[16] && (r_t1_out[15:7] == r_t1_tag);
	t_t2_hit = r_t2_out[16] && (r_t2_out[15:7] == r_t2_tag);
	if(t_t1_hit)
	  begin
	     t_pred_vec[r_t1_out[6:5]] = r_t1_out[4];
	  end
	/* longest matching history wins its slot */
	if(t_t2_hit)
	  begin
	     t_pred_vec[r_t2_out[6:5]] = r_t2_out[4];
	  end
     end

   

   always_comb
     begin
	t_retire_pht_idx = r_bpu_tbl[branch_bpu_idx];
     end

   
   always_comb
     begin
	t_wr_valid_ram_en0 = (mem_rsp_valid && !r_fill_way) || r_state == FLUSH_CACHE || t_binv_fire;
	t_wr_valid_ram_en1 = (mem_rsp_valid && r_fill_way) || r_state == FLUSH_CACHE || t_binv_fire;
	t_valid_ram_value = (r_state != FLUSH_CACHE) && !t_binv_fire;
	t_valid_ram_idx = mem_rsp_valid ? r_miss_pc[IDX_STOP-1:IDX_START] :
			  t_binv_fire ? t_binv_va[IDX_STOP-1:IDX_START] : r_cache_idx;
     end

      
     // always_ff@(negedge clk)
     //   begin
     // 	  if((t_push_insn | t_push_insn2 | t_push_insn3 | t_push_insn4) && (t_pd != 'd0))
     // 	    begin
     // 	       $display("spec %x : cycle %d n_pht_idx = %d, hist = %b, pred = %b",
     // 			t_insn.pc, r_cycle, t_insn.pht_idx, r_last_spec_gbl_hist, t_insn.pred);
     // 	    end
     // 	  if(branch_pc_valid)
     // 	    begin
     // 	       $display("arch %x : cycle %d n_pht_idx = %d, hist = %b, took branch %b, mispred %b, comp_pht %d", 
     // 			branch_pc, r_cycle, branch_pht_idx, n_arch_gbl_hist, took_branch, branch_fault, t_retire_pht_idx);
     // 	    end
     //   end
   
   always_comb
     begin
	/* read-modify-write: the retiring branch updates only ITS 2-bit field and the
	 * other three counters in the entry are written back unchanged. */
	t_pht_old = (r_pht_update_slot == 2'd0) ? r_pht_update_out[1:0] :
		    (r_pht_update_slot == 2'd1) ? r_pht_update_out[3:2] :
		    (r_pht_update_slot == 2'd2) ? r_pht_update_out[5:4] :
		    r_pht_update_out[7:6];
	t_pht_val = t_pht_old;
	t_do_pht_wr = r_pht_update;

	case(t_pht_old)
	  2'd0:
	    begin
	       if(r_take_br)
		 begin
		    t_pht_val =  2'd1;
		 end
	       else
		 begin
		    t_do_pht_wr = 1'b0;
		 end
	    end
	  2'd1:
	    begin
	       t_pht_val = r_take_br ? 2'd2 : 2'd0;
	    end
	  2'd2:
	    begin
	       t_pht_val = r_take_br ? 2'd3 : 2'd1;
	    end
	  2'd3:
	    begin
	       if(!r_take_br)
		 begin
		    t_pht_val = 2'd2;
		 end
	       else
		 begin
		    t_do_pht_wr = 1'b0;
		 end
	    end
	endcase // case (t_pht_old)

	/* splice the updated counter back into its slot, leaving the other three */
	t_pht_val_vec = (r_pht_update_slot == 2'd0) ? {r_pht_update_out[7:2], t_pht_val} :
			(r_pht_update_slot == 2'd1) ? {r_pht_update_out[7:4], t_pht_val, r_pht_update_out[1:0]} :
			(r_pht_update_slot == 2'd2) ? {r_pht_update_out[7:6], t_pht_val, r_pht_update_out[3:0]} :
			{t_pht_val, r_pht_update_out[5:0]};
	/* tagged-table update, from the fetch-time copies of the entries (blind writes:
	 * no read at retire).  Provider = the longest table that hit for this branch's
	 * slot (T2, then T1), else the bimodal; alt = the next shorter one.  Only the
	 * provider trains.  A provider mispredict allocates in the first longer table
	 * whose entry is free (!valid || u == 0), else ages every longer candidate. */
	t_t2_provider = r_t2u_hit && (r_t2u_ent[6:5] == r_pht_update_slot);
	t_t1_provider = !t_t2_provider && r_t1u_hit && (r_t1u_ent[6:5] == r_pht_update_slot);
	t_t1_free = !r_t1u_ent[16] || (r_t1u_ent[1:0] == 2'd0);
	t_t2_free = !r_t2u_ent[16] || (r_t2u_ent[1:0] == 2'd0);
	t_prov_pred = t_t2_provider ? r_t2u_ent[4] : t_t1_provider ? r_t1u_ent[4] : t_pht_old[1];
	t_alt_pred = (t_t2_provider && r_t1u_hit && (r_t1u_ent[6:5] == r_pht_update_slot)) ? r_t1u_ent[4] :
		     t_pht_old[1];
	t_t1_ctr = r_t1u_ent[4:2];
	t_t1_u = r_t1u_ent[1:0];
	t_t2_ctr = r_t2u_ent[4:2];
	t_t2_u = r_t2u_ent[1:0];
	t_t1_wr = 1'b0;
	t_t2_wr = 1'b0;
	t_t1_wr_data = r_t1u_ent;
	t_t2_wr_data = r_t2u_ent;
	if(t_init_pht)
	  begin
	     t_t1_wr = 1'b1;
	     t_t1_wr_data = 'd0;
	     t_t2_wr = 1'b1;
	     t_t2_wr_data = 'd0;
	  end
	else if(r_pht_update)
	  begin
	     /* train the provider */
	     if(t_t2_provider)
	       begin
		  t_do_pht_wr = 1'b0;
		  t_t2_ctr = r_take_br ? ((t_t2_ctr == 3'd7) ? 3'd7 : t_t2_ctr + 3'd1) :
			     ((t_t2_ctr == 3'd0) ? 3'd0 : t_t2_ctr - 3'd1);
		  if((t_prov_pred == r_take_br) && (t_prov_pred != t_alt_pred) && (t_t2_u != 2'd3))
		    begin
		       t_t2_u = t_t2_u + 2'd1;
		    end
		  t_t2_wr = 1'b1;
		  t_t2_wr_data = {1'b1, r_t2u_ent[15:7], r_t2u_ent[6:5], t_t2_ctr, t_t2_u};
	       end
	     else if(t_t1_provider)
	       begin
		  t_do_pht_wr = 1'b0;
		  t_t1_ctr = r_take_br ? ((t_t1_ctr == 3'd7) ? 3'd7 : t_t1_ctr + 3'd1) :
			     ((t_t1_ctr == 3'd0) ? 3'd0 : t_t1_ctr - 3'd1);
		  if((t_prov_pred == r_take_br) && (t_prov_pred != t_alt_pred) && (t_t1_u != 2'd3))
		    begin
		       t_t1_u = t_t1_u + 2'd1;
		    end
		  t_t1_wr = 1'b1;
		  t_t1_wr_data = {1'b1, r_t1u_ent[15:7], r_t1u_ent[6:5], t_t1_ctr, t_t1_u};
	       end
	     /* provider mispredicted: allocate in a longer table */
	     if(t_prov_pred != r_take_br)
	       begin
		  if(!t_t2_provider && !t_t1_provider)
		    begin
		       /* bimodal provided: candidates T1 then T2 */
		       if(t_t1_free)
			 begin
			    t_t1_wr = 1'b1;
			    t_t1_wr_data = {1'b1, r_t1u_tag, r_pht_update_slot, r_take_br ? 3'd4 : 3'd3, 2'd0};
			 end
		       else if(t_t2_free)
			 begin
			    t_t2_wr = 1'b1;
			    t_t2_wr_data = {1'b1, r_t2u_tag, r_pht_update_slot, r_take_br ? 3'd4 : 3'd3, 2'd0};
			 end
		       else
			 begin
			    t_t1_wr = 1'b1;
			    t_t1_wr_data = {r_t1u_ent[16:2], r_t1u_ent[1:0] - 2'd1};
			    t_t2_wr = 1'b1;
			    t_t2_wr_data = {r_t2u_ent[16:2], r_t2u_ent[1:0] - 2'd1};
			 end
		    end
		  else if(t_t1_provider)
		    begin
		       /* T1 provided: the only longer candidate is T2 */
		       t_t2_wr = 1'b1;
		       if(t_t2_free)
			 begin
			    t_t2_wr_data = {1'b1, r_t2u_tag, r_pht_update_slot, r_take_br ? 3'd4 : 3'd3, 2'd0};
			 end
		       else
			 begin
			    t_t2_wr_data = {r_t2u_ent[16:2], r_t2u_ent[1:0] - 2'd1};
			 end
		    end
	       end
	  end
     end
   
   always_comb
     begin
	t_bpu_alloc = t_push_insn | t_push_insn2;
     end

   always_ff@(posedge clk)
     begin
	if(t_bpu_alloc)
	  begin
	     r_bpu_tbl[r_bpu_idx] <= r_pht_idx;
	     r_bpu_btb_idx[r_bpu_idx] <= r_btb_idx;
	     r_bpu_itt_idx[r_bpu_idx] <= r_itt_idx;
	     r_bpu_itt_tag[r_bpu_idx] <= r_itt_tag;
	     r_bpu_itt_hit[r_bpu_idx] <= t_itt_hit;
	     r_bpu_itt_ent[r_bpu_idx] <= r_itt_out;
	     r_bpu_t1_idx[r_bpu_idx] <= r_t1_idx;
	     r_bpu_t1_tag[r_bpu_idx] <= r_t1_tag;
	     r_bpu_t1_hit[r_bpu_idx] <= t_t1_hit;
	     r_bpu_t1_ent[r_bpu_idx] <= r_t1_out;
	     r_bpu_t2_idx[r_bpu_idx] <= r_t2_idx;
	     r_bpu_t2_tag[r_bpu_idx] <= r_t2_tag;
	     r_bpu_t2_hit[r_bpu_idx] <= t_t2_hit;
	     r_bpu_t2_ent[r_bpu_idx] <= r_t2_out;
	  end
     end

   always_ff@(posedge clk)
     begin
	r_t1_idx <= t_t1_n_idx;
	r_t1_tag <= t_t1_n_tag;
	r_t1u_idx <= r_bpu_t1_idx[branch_bpu_idx];
	r_t1u_tag <= r_bpu_t1_tag[branch_bpu_idx];
	r_t1u_hit <= r_bpu_t1_hit[branch_bpu_idx];
	r_t1u_ent <= r_bpu_t1_ent[branch_bpu_idx];
	r_t2_idx <= t_t2_n_idx;
	r_t2_tag <= t_t2_n_tag;
	r_t2u_idx <= r_bpu_t2_idx[branch_bpu_idx];
	r_t2u_tag <= r_bpu_t2_tag[branch_bpu_idx];
	r_t2u_hit <= r_bpu_t2_hit[branch_bpu_idx];
	r_t2u_ent <= r_bpu_t2_ent[branch_bpu_idx];
     end

   ram1r1w #(.WIDTH(T1_W), .LG_DEPTH(`LG_TAGE_SZ)) t1
     (
      .clk(clk),
      .rd_addr(t_t1_n_idx),
      .wr_addr(t_init_pht ? r_init_pht_idx[`LG_TAGE_SZ-1:0] : r_t1u_idx),
      .wr_data(t_t1_wr_data),
      .wr_en(t_t1_wr),
      .rd_data(r_t1_out)
      );

   ram1r1w #(.WIDTH(T1_W), .LG_DEPTH(`LG_TAGE_SZ)) t2
     (
      .clk(clk),
      .rd_addr(t_t2_n_idx),
      .wr_addr(t_init_pht ? r_init_pht_idx[`LG_TAGE_SZ-1:0] : r_t2u_idx),
      .wr_data(t_t2_wr_data),
      .wr_en(t_t2_wr),
      .rd_data(r_t2_out)
      );

   always_ff@(posedge clk)
     begin
	r_bpu_idx <= reset ? 'd0 : (t_bpu_alloc ? r_bpu_idx + 'd1 : r_bpu_idx);
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_pht_idx <= 'd0;
	     r_last_spec_gbl_hist <= 'd0;
	     r_pht_update <= 1'b0;
	     r_pht_update_idx <= 'd0;
	     r_pht_update_slot <= 2'd0;
	     r_take_br <= 1'b0;
	     r_pd <= 'd0;
	  end
	else
	  begin
	     r_pht_idx <= n_pht_idx;
	     r_last_spec_gbl_hist <= r_spec_gbl_hist;
	     r_pht_update <= branch_pc_valid;
	     r_pht_update_idx <= t_retire_pht_idx;
	     /* which of the 4 packed counters this retiring branch owns */
	     r_pht_update_slot <= branch_pc[3:2];
	     r_take_br <= took_branch;
	     r_pd <= t_pd;
	  end
     end // always_ff@

`ifdef TOPDOWN
   /* per-cycle fetch group size and why the group ended (top.cc topdown_fetch):
    * 0 full 2, 1 cut at the 16B line end, 2 cut before a predicted-taken cflow,
    * 3 the cflow insn alone, 4 its delay slot alone, 5 fetch queue full,
    * 6 resteer bubble, 7 miss/tlb/other state, 8 restart/flush redirect,
    * 9 branch pair: [insn, predicted-taken direct branch] */
   import "DPI-C" function void topdown_fetch(input int npush, input int why, input int fq_cnt);
   logic [3:0] t_td_why;
   logic [2:0] t_td_n;
   always_comb
     begin
	t_td_n = t_push_insn2 ? 3'd2 : t_push_insn ? 3'd1 : 3'd0;
	t_td_why = 4'd7;
	if(r_state != ACTIVE)
	  begin
	     t_td_why = 4'd7;
	  end
	else if(r_resteer_bubble)
	  begin
	     t_td_why = 4'd6;
	  end
	else if(t_clear_fq)
	  begin
	     t_td_why = 4'd8;
	  end
	else if(!t_hit)
	  begin
	     t_td_why = 4'd7;
	  end
	else if(fq_full)
	  begin
	     t_td_why = 4'd5;
	  end
	else if(r_delay_slot)
	  begin
	     t_td_why = 4'd4;
	  end
	else if(t_is_cflow)
	  begin
	     t_td_why = 4'd3;
	  end
	else if(t_gb_take1)
	  begin
	     t_td_why = 4'd9;
	  end
	else if(t_td_n == 3'd2)
	  begin
	     t_td_why = 4'd0;
	  end
	else if({1'b0, t_td_n} < {1'b0, t_first_branch})
	  begin
	     t_td_why = 4'd5;
	  end
	else if(({1'b0, t_first_branch} + {2'b0, t_insn_idx}) == 4'd4)
	  begin
	     t_td_why = 4'd1;
	  end
	else
	  begin
	     t_td_why = 4'd2;
	  end
     end // always_comb
   always_ff@(negedge clk)
     begin
	if(!reset)
	  begin
	     topdown_fetch({29'd0, t_td_n}, {28'd0, t_td_why},
			   {{(31-`LG_FQ_ENTRIES){1'b0}}, r_fq_tail_ptr - r_fq_head_ptr});
	  end
     end
`endif

`ifdef VERILATOR
   localparam ZP = (64-`M_WIDTH);   
   always_ff@(negedge clk)
     begin
	//$display("%b %b %b %b", t_push_insn, t_push_insn2, t_push_insn3, t_push_insn4);
	record_fetch(t_push_insn ? 32'd1 : 32'd0,
		     t_push_insn2 ? 32'd1 : 32'd0,
		     32'd0,
		     32'd0,
		     {{ZP{1'b0}}, t_insn.pc},
		     {{ZP{1'b0}}, t_insn2.pc},
		     64'd0,
		     64'd0,
		     r_resteer_bubble ? 32'd1 : 32'd0,
		     fq_full ? 32'd1 : 32'd0);
	
	
     end
`endif
	  

   ram2r1w #(.WIDTH(8), .LG_DEPTH(`LG_PHT_SZ) ) pht
     (
      .clk(clk),
      .rd_addr0(n_pht_idx),
      .rd_addr1(t_retire_pht_idx),
      .wr_addr(t_init_pht ? r_init_pht_idx : r_pht_update_idx),
      .wr_data(t_init_pht ? 8'b01010101 : t_pht_val_vec),
      .wr_en(t_init_pht || t_do_pht_wr),
      .rd_data0(r_pht_out_vec),
      .rd_data1(r_pht_update_out)
      );
         
   wire [3:0] w_pd0, w_pd1, w_pd2, w_pd3;
   predecode pd0 (.insn_(mem_rsp_load_data[31:0]),   .pd(w_pd0));
   predecode pd1 (.insn_(mem_rsp_load_data[63:32]),  .pd(w_pd1));
   predecode pd2 (.insn_(mem_rsp_load_data[95:64]),  .pd(w_pd2));
   predecode pd3 (.insn_(mem_rsp_load_data[127:96]), .pd(w_pd3));   
   
   
   ram1r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1I_NUM_SETS))
   valid_array0 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(t_valid_ram_idx),
	   .wr_data(t_valid_ram_value),
	   .wr_en(t_wr_valid_ram_en0),
	   .rd_data(r_valid_out0)
	   );

   
   ram1r1w #(.WIDTH(N_TAG_BITS), .LG_DEPTH(`LG_L1I_NUM_SETS))
   tag_array0 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	   .wr_data(r_mem_req_addr[`PA_WIDTH-1:TAG_LSB]),
	   .wr_en(mem_rsp_valid && !r_fill_way),
	   .rd_data(r_tag_out0)
	   );
   
   ram1r1w #(.WIDTH(L1I_CL_LEN_BITS), .LG_DEPTH(`LG_L1I_NUM_SETS)) 
   insn_array0 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	   .wr_data({bswap32(mem_rsp_load_data[127:96]),
		     bswap32(mem_rsp_load_data[95:64]),
		     bswap32(mem_rsp_load_data[63:32]), 
		     bswap32(mem_rsp_load_data[31:0])}),
	   .wr_en(mem_rsp_valid && !r_fill_way),
	   .rd_data(r_array_out0)
	   );

   ram1r1w #(.WIDTH(4*WORDS_PER_CL), .LG_DEPTH(`LG_L1I_NUM_SETS))
   pd_data0 (
	    .clk(clk),
	    .rd_addr(t_cache_idx),
	    .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	    .wr_data({w_pd3,w_pd2,w_pd1,w_pd0}),
	    .wr_en(mem_rsp_valid && !r_fill_way),
	    .rd_data(r_jump_out0)
	    );

   ram1r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1I_NUM_SETS))
   valid_array1 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(t_valid_ram_idx),
	   .wr_data(t_valid_ram_value),
	   .wr_en(t_wr_valid_ram_en1),
	   .rd_data(r_valid_out1)
	   );

   
   ram1r1w #(.WIDTH(N_TAG_BITS), .LG_DEPTH(`LG_L1I_NUM_SETS))
   tag_array1 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	   .wr_data(r_mem_req_addr[`PA_WIDTH-1:TAG_LSB]),
	   .wr_en(mem_rsp_valid && r_fill_way),
	   .rd_data(r_tag_out1)
	   );
   
   ram1r1w #(.WIDTH(L1I_CL_LEN_BITS), .LG_DEPTH(`LG_L1I_NUM_SETS)) 
   insn_array1 (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	   .wr_data({bswap32(mem_rsp_load_data[127:96]),
		     bswap32(mem_rsp_load_data[95:64]),
		     bswap32(mem_rsp_load_data[63:32]), 
		     bswap32(mem_rsp_load_data[31:0])}),
	   .wr_en(mem_rsp_valid && r_fill_way),
	   .rd_data(r_array_out1)
	   );

   ram1r1w #(.WIDTH(4*WORDS_PER_CL), .LG_DEPTH(`LG_L1I_NUM_SETS))
   pd_data1 (
	    .clk(clk),
	    .rd_addr(t_cache_idx),
	    .wr_addr(r_miss_pc[IDX_STOP-1:IDX_START]),
	    .wr_data({w_pd3,w_pd2,w_pd1,w_pd0}),
	    .wr_en(mem_rsp_valid && r_fill_way),
	    .rd_data(r_jump_out1)
	    );

   /* 1 bit/set LRU: the way NOT used most recently; a hit marks the other way, a fill
    * marks the way that was not filled */
   always_comb
     begin
	t_lru_wr = 1'b0;
	t_lru_val = 1'b0;
	t_lru_idx = r_cache_idx;
	if(mem_rsp_valid)
	  begin
	     t_lru_wr = 1'b1;
	     t_lru_val = !r_fill_way;
	     t_lru_idx = r_miss_pc[IDX_STOP-1:IDX_START];
	  end
	else if(t_hit)
	  begin
	     t_lru_wr = 1'b1;
	     t_lru_val = w_hit0;
	     t_lru_idx = r_cache_idx;
	  end
     end

   ram1r1w #(.WIDTH(1), .LG_DEPTH(`LG_L1I_NUM_SETS))
   lru_array (
	   .clk(clk),
	   .rd_addr(t_cache_idx),
	   .wr_addr(t_lru_idx),
	   .wr_data(t_lru_val),
	   .wr_en(t_lru_wr),
	   .rd_data(r_lru_out)
	   );
	    
	     
   always_comb
     begin
	n_spec_rs_tos = r_spec_rs_tos;
	if(n_restart_ack)
	  begin
	     /* n_arch, not r_arch: the retire of the mispredicted branch itself
	      * (retired_call/ret, flopped in core) arrives the same cycle as
	      * restart_valid, so r_arch_* is one push/pop stale here.  Mirrors
	      * the n_arch_gbl_hist restore below. */
	     n_spec_rs_tos = n_arch_rs_tos;
	  end
	else if(t_is_call)
	  begin
	     n_spec_rs_tos = r_spec_rs_tos - 'd1;
	  end
	else if(t_is_ret)
	  begin
	     n_spec_rs_tos = r_spec_rs_tos + 'd1;
	  end
     end

   always_ff@(posedge clk)
     begin
	if(t_is_call)
	  begin
	     r_spec_return_stack[r_spec_rs_tos] <= r_cache_pc + 'd8;
	  end
	else if(n_restart_ack)
	  begin
	     r_spec_return_stack <= r_arch_return_stack;
	     /* the mispredicted call's own arch push lands this same cycle */
	     if(retire_reg_valid && retire_valid && retired_call)
	       begin
		  r_spec_return_stack[r_arch_rs_tos] <= retire_reg_data + 'd8;
	       end
	  end
     end // always_ff@ (posedge clk)
   
   always_ff@(posedge clk)
     begin
	/* a SPARC call links its OWN pc (%o7); ret / retl go to %o7 + 8 */
	if(retire_reg_valid && retire_valid && retired_call)
	  begin
	     r_arch_return_stack[r_arch_rs_tos] <= retire_reg_data + 'd8;
	  end
     end
   always_comb
     begin
	n_arch_rs_tos = r_arch_rs_tos;
	if(retire_valid && retired_call)
	  begin
	     n_arch_rs_tos = r_arch_rs_tos - 'd1;
	  end
	else if(retire_valid && retired_ret)
	  begin
	     n_arch_rs_tos = r_arch_rs_tos + 'd1;
	  end
     end

   always_comb
     begin
	n_spec_gbl_hist = r_spec_gbl_hist;
	if(n_restart_ack)
	  begin
	     n_spec_gbl_hist = n_arch_gbl_hist;
	  end
	else if(t_update_spec_hist)
	  begin
	     n_spec_gbl_hist = {r_spec_gbl_hist[`GBL_HIST_LEN-2:0], t_take_br | t_gb_take1};
	  end
     end // always_comb

   // always_ff@(negedge clk)
   //   begin
   // 	if(n_restart_ack)
   // 	  begin
   // 	     $display("fix = %b, r_cycle %d", n_spec_gbl_hist, r_cycle);
   // 	  end
	
   // 	if(t_update_spec_hist)
   // 	  begin
   // 	     $display("take_br = %b, cycle %d", t_take_br, r_cycle);
   // 	     $display("old = %b", r_spec_gbl_hist);
   // 	     $display("new = %b", n_spec_gbl_hist);
	     
   // 	  end
   //   end
      


   always_comb
     begin
	n_arch_gbl_hist = r_arch_gbl_hist;
	if(branch_pc_valid)
	  begin
	     n_arch_gbl_hist = {r_arch_gbl_hist[`GBL_HIST_LEN-2:0], took_branch};
	  end
     end
   
   

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= INITIALIZE;
	     r_init_pht_idx <= 'd0;
	     r_pc <= 'd0;
	     r_miss_pc <= 'd0;
	     r_fill_way <= 1'b0;
	     r_cache_pc <= 'd0;
	     r_restart_ack <= 1'b0;
	     r_cache_idx <= 'd0;
	     r_cache_tag <= 'd0;
	     r_req <= 1'b0;
	     r_mem_req_valid <= 1'b0;
	     r_mem_req_addr <= 'd0;
	     r_mem_req_cacheable <= 1'b0;	     
	     r_fq_head_ptr <= 'd0;
	     r_fq_next_head_ptr <= 'd1;
	     r_fq_next_tail_ptr <= 'd1;
	     r_fq_tail_ptr <= 'd0;
	     r_restart_req <= 1'b0;
	     r_npc_pend <= 1'b0;
	     r_flush_req <= 1'b0;
	     r_flush_complete <= 1'b0;
	     r_fline_req <= 1'b0;
	     r_fline_idx <= 'd0;
	     r_fline_one <= 1'b0;
	     r_fline_complete <= 1'b0;
	     r_delay_slot <= 1'b0;
	     r_spec_rs_tos <= RETURN_STACK_ENTRIES-1;
	     r_arch_rs_tos <= RETURN_STACK_ENTRIES-1;
	     r_arch_gbl_hist <= 'd0;
	     r_spec_gbl_hist <= 'd0;
	     r_cache_hits <= 'd0;
	     r_cache_accesses <= 'd0;
	     r_resteer_bubble <= 1'b0;
	     r_iw_mine <= 1'b0;
	     r_ihold <= 1'b0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_init_pht_idx <= n_init_pht_idx;
	     r_pc <= n_pc;
	     r_miss_pc <= n_miss_pc;
	     r_fill_way <= n_fill_way;
	     r_cache_pc <= n_cache_pc;
	     r_restart_ack <= n_restart_ack;
	     r_cache_idx <= t_cache_idx;
	     r_cache_tag <= t_cache_tag;	     
	     r_req <= n_req;
	     r_mem_req_valid <= n_mem_req_valid;
	     r_mem_req_addr <= n_mem_req_addr;
	     r_mem_req_cacheable <= n_mem_req_cacheable;
	     r_fq_head_ptr <= t_clear_fq ? 'd0 : n_fq_head_ptr;
	     r_fq_next_head_ptr <= t_clear_fq ? 'd1 : n_fq_next_head_ptr;
	     r_fq_next_tail_ptr <= t_clear_fq ? 'd1 : n_fq_next_tail_ptr;
	     r_fq_tail_ptr <= t_clear_fq ? 'd0 : n_fq_tail_ptr;
	     r_restart_req <= n_restart_req;
	     r_npc_pend <= n_npc_pend;
	     r_npc <= n_npc;
	     r_npc_l1 <= n_npc_l1;
	     r_flush_req <= n_flush_req;
	     r_flush_complete <= n_flush_complete;
	     r_fline_req <= n_fline_req;
	     r_fline_idx <= n_fline_idx;
	     r_fline_one <= n_fline_one;
	     r_fline_complete <= n_fline_complete;
	     r_delay_slot <= n_delay_slot;
	     r_spec_rs_tos <= n_spec_rs_tos;
	     r_arch_rs_tos <= n_arch_rs_tos;
	     r_arch_gbl_hist <= n_arch_gbl_hist;
	     r_spec_gbl_hist <= n_spec_gbl_hist;
	     r_cache_hits <= n_cache_hits;
	     r_cache_accesses <= n_cache_accesses;
	     r_resteer_bubble <= n_resteer_bubble;
	     r_iw_mine <= n_iw_mine;
	     r_ihold <= n_ihold;	     
	  end
     end
   
endmodule
