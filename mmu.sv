`include "machine.vh"
`include "rob.vh"

`ifdef VERILATOR
/* sim-only: the MMU registers' reset values (top.cc --mmu-* options) until the
 * ASI 0x4 accesses are plumbed, and the checker hook that mirrors a walk-time
 * (possibly speculative) PTE R-bit write into the ISS's memory */
import "DPI-C" function int mmu_preload(input int regid);
import "DPI-C" function void mmu_set_ref(input longint pte_pa, input int pte);
`endif

/* SRMMU table walker + registers, after rv64core's mmu.sv: one walker shared by
 * the L1I and L1D TLBs.  The walk (interpret.cc srmmu_walk) starts at the context
 * table, ctpr << 4 + 4*ctx, then follows PTDs (ET=1) through up to three page
 * tables indexed by VA[31:24], VA[23:18], VA[17:12]; a PTE (ET=2) ends it at its
 * level, ET=0 is an invalid fault and ET=3 (or a PTD at level 3) a translation
 * fault.
 *
 * PTE R/M: R may be set speculatively, M may not.  A walk that lands on a PTE with
 * R=0 writes PTE|R back (any access, wrong path included; the checker is told so
 * the ISS copy matches).  M is set only for a store that hits a dtlb entry with
 * M=0 once it is non-speculative (at the ROB head): the L1D asks for a mark walk
 * (l1d_mark with l1d_req), the walker re-walks and writes PTE|R|M, and the L1D
 * sets M in its entry.
 *
 * Memory: word reads and writes go to the L2 as UNCACHED requests, which the L2
 * makes coherent with the write-back L1D by probing the line out first.  A PTE
 * read-modify-write holds the L1 arbiter (mem_lock) from the read to the write,
 * so no L1D access to the line can land between them. */
module mmu(clk,
	   reset,
	   sys_reset,
	   ctrl_e,
	   ctrl_nf,
	   ctrl_bm,
	   ctx,
	   l1i_req,
	   l1i_va,
	   l1d_req,
	   l1d_va,
	   l1d_mark,
	   l1d_probe,
	   page_walk_rsp,
	   walk_pte,
	   l1i_rsp_valid,
	   l1d_rsp_valid,
	   fault_valid,
	   fault_ft,
	   fault_level,
	   fault_at,
	   fault_va,
	   fault_asi,
	   mem_req_valid,
	   mem_req_addr,
	   mem_req_store,
	   mem_req_mask,
	   mem_req_data,
	   mem_lock,
	   mem_req_ack,
	   mem_rsp_valid,
	   mem_rsp_data,
	   reg_wr,
	   reg_fsr_clr,
	   reg_sel,
	   reg_wdata,
	   reg_ctrl,
	   reg_ctpr,
	   reg_fsr,
	   reg_far,
	   flush_req,
	   tlb_flush);

   input logic clk;
   input logic reset;
   /* a system reset (the SS-20's sysctrl): the walker resets and the control
    * register leaves translation (E, NF clear) for boot mode (BM); the context
    * table pointer, context and fault status/address keep their values, as
    * ss10sim's system_reset (qemu's cpu reset) */
   input logic sys_reset;
   output logic ctrl_e;
   output logic ctrl_nf;   /* MCR.NF: data-access faults are recorded, not trapped (core.sv) */
   output logic ctrl_bm;   /* MCR.BM: Viking boot mode (the L1I/L1D redirect to the PROM) */
   output logic [`SRMMU_CTX_BITS-1:0] ctx;

   input logic l1i_req;
   input logic [31:0] l1i_va;
   input logic l1d_req;
   input logic [31:0] l1d_va;
   input logic l1d_mark;   /* with l1d_req: set M (and R) in the PTE */
   input logic l1d_probe;   /* with l1d_req: an SRMMU probe (ASI 3 load): no R/M write-back */
   output page_walk_rsp_t page_walk_rsp;
   output logic [31:0] walk_pte;   /* the raw PTE, with page_walk_rsp (for a probe) */
   output logic l1i_rsp_valid;
   output logic l1d_rsp_valid;

   /* the L1 requests are pulses; each L1 holds its VA (and mark) until its
    * response */

   /* a trap on an MMU fault: record it in the fault status/address registers */
   input logic fault_valid;
   input logic [2:0] fault_ft;
   input logic [1:0] fault_level;
   input logic [2:0] fault_at;
   input logic [31:0] fault_va;
   input logic fault_asi;   /* a bus error of an alternate-space access: FSR bit 16 (qemu) */

   output logic mem_req_valid;
   output logic [`PA_WIDTH-1:0] mem_req_addr;   /* line aligned */
   output logic mem_req_store;
   output logic [15:0] mem_req_mask;
   output logic [127:0] mem_req_data;
   output logic mem_lock;
   input logic mem_req_ack;
   input logic mem_rsp_valid;
   input logic [127:0] mem_rsp_data;

   /* ---- registers (ASI 0x4) ---- */
   /* the ASI 4 accesses (l1d.sv, at the ROB head): register = VA[10:8]
    * (0 control, 1 context table pointer, 2 context, 3 fault status, 4 fault
    * address).  As interpret.cc: control keeps bits [23:0] (impl/ver read 0),
    * the fault registers ignore writes, a fault-status read clears it.  A
    * control or table-pointer write flushes both TLBs (tlb_flush, next cycle):
    * their entries came from the old tables. */
   input logic reg_wr;
   input logic reg_fsr_clr;
   input logic [2:0] reg_sel;
   input logic [31:0] reg_wdata;
   output logic [31:0] reg_ctrl;
   output logic [31:0] reg_ctpr;
   output logic [31:0] reg_fsr;
   output logic [31:0] reg_far;
   input logic flush_req;   /* an ASI 3 store (SRMMU flush): flush both TLBs */
   output logic tlb_flush;

   logic [31:0] r_ctrl, r_ctpr, r_fsr, r_far;
   logic [31:0] n_ctrl, n_ctpr;
   logic [`SRMMU_CTX_BITS-1:0] n_ctx;
   logic r_tlb_flush, n_tlb_flush;
   assign reg_ctrl = r_ctrl;
   assign reg_ctpr = r_ctpr;
   assign reg_fsr = r_fsr;
   assign reg_far = r_far;
   assign tlb_flush = r_tlb_flush;
   logic [`SRMMU_CTX_BITS-1:0] r_ctx;
   logic [31:0] n_fsr, n_far;

   assign ctrl_e = r_ctrl[0];
   assign ctrl_nf = r_ctrl[1];
   assign ctrl_bm = r_ctrl[13];
   assign ctx = r_ctx;

   /* a fault status not yet read is replaced and flagged OW (interpret.cc
    * mmu_record_fault) */
   always_comb
     begin
	n_fsr = r_fsr;
	n_far = r_far;
	n_ctrl = r_ctrl;
	n_ctpr = r_ctpr;
	n_ctx = r_ctx;
	n_tlb_flush = flush_req;
	if(reg_wr)
	  begin
	     if(reg_sel == 3'd0)
	       begin
		  n_ctrl = reg_wdata & 32'h00ffffff;
		  /* only E (translation on/off) and BM (boot mode) change what a TLB
		   * entry means.  Solaris toggles NF around every user window spill
		   * and fill (~600 control writes per 10M insns in li): those keep
		   * the TLBs */
		  n_tlb_flush = (reg_wdata[0] != r_ctrl[0]) | (reg_wdata[13] != r_ctrl[13]);
	       end
	     else if(reg_sel == 3'd1)
	       begin
		  n_ctpr = reg_wdata & 32'hfffffffc;
		  n_tlb_flush = 1'b1;
	       end
	     else if(reg_sel == 3'd2)
	       begin
		  n_ctx = `SRMMU_CTX_BITS'(reg_wdata);
	       end
	  end
	if(reg_fsr_clr)
	  begin
	     n_fsr = 32'd0;
	  end
	if(fault_valid && (fault_ft == FT_BUS_ERROR))
	  begin
	     /* interpret.cc mmu_bus_error: a pending translation fault (FT 1-4)
	      * keeps priority (only OW is set); otherwise the bus error replaces
	      * the status (OW if it was a bus error too) */
	     if((r_fsr[4:2] == 3'd0) || (r_fsr[4:2] > 3'd4))
	       begin
		  n_fsr = {15'd0, fault_asi, 6'd0, fault_level, fault_at, fault_ft, 1'b1, (r_fsr[4:2] == FT_BUS_ERROR)};
		  n_far = fault_va;
	       end
	     else
	       begin
		  n_fsr = r_fsr | 32'd1;
	       end
	  end
	else if(fault_valid)
	  begin
	     n_fsr = {22'd0, fault_level, fault_at, fault_ft, 1'b1, (r_fsr != 32'd0)};
	     n_far = fault_va;
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
`ifdef VERILATOR
	     r_ctrl <= mmu_preload(0);
	     r_ctpr <= mmu_preload(1) & 32'hfffffffc;
	     r_ctx <= `SRMMU_CTX_BITS'(mmu_preload(2));
`else
	     r_ctrl <= 32'h00002800;   /* MCR_MMODE: MBus mode, MCR_BM: boot mode (Viking) */
	     r_ctpr <= 32'd0;
	     r_ctx <= 'd0;
`endif
	     r_fsr <= 32'd0;
	     r_far <= 32'd0;
	     r_tlb_flush <= 1'b0;
	  end
	else if(sys_reset)
	  begin
	     r_ctrl <= (r_ctrl & 32'hfffffffc) | 32'h00002000;
	     r_tlb_flush <= 1'b0;
	  end
	else
	  begin
	     r_fsr <= n_fsr;
	     r_far <= n_far;
	     r_ctrl <= n_ctrl;
	     r_ctpr <= n_ctpr;
	     r_ctx <= n_ctx;
	     r_tlb_flush <= n_tlb_flush;
	  end
     end // always_ff@ (posedge clk)

`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
	if(!reset && reg_wr)
	  begin
	     $display("[MMU] reg %0d <= %08x (ctrl %08x ctpr %08x ctx %0d)", reg_sel, reg_wdata, r_ctrl, r_ctpr, r_ctx);
	  end
     end
`endif

   /* ---- walker ---- */
   typedef enum logic [2:0] {
			     IDLE,
			     LOOKUP,
			     RD,
			     RD_WAIT,
			     WR,
			     WR_WAIT,
			     DONE
			     } state_t;
   state_t r_state, n_state;

   logic [`PA_WIDTH-1:0] r_ea, n_ea;
   logic [31:0] r_va, n_va;
   logic [1:0] r_level, n_level;
   logic [31:0] r_pte, n_pte;
   logic r_do_l1i, n_do_l1i;
   logic r_do_mark, n_do_mark;
   logic r_do_probe, n_do_probe;
   logic r_l1i_req, n_l1i_req;
   logic r_l1d_req, n_l1d_req;
   logic r_fault, n_fault;
   logic [2:0] r_ft, n_ft;
   logic r_mem_req, n_mem_req;
   logic r_mem_store, n_mem_store;
   logic r_lock, n_lock;
   logic r_l1i_rsp, n_l1i_rsp, r_l1d_rsp, n_l1d_rsp;

   /* ---- the walker's caches ----
    * Second-level TLB: level-3 (4KB) PTEs of completed walks, indexed by
    * VA[19:12] ^ ctx, tagged {ctx, VA[31:12]}.  Walk cache: level-2 PTDs (the
    * level-3 table's pointer), indexed by VA[22:18], tagged {ctx, VA[31:18]}.
    * Both are looked up in LOOKUP (the cycle after a request is taken: their
    * reads are registered); probes and mark walks skip them (a probe answers
    * from memory, as interpret.cc srmmu_probe; a mark walk must write M).
    * Invalidation (the TLB flush cases): every tlb_flush -- an ASI 3 store, a
    * control write that changes E or BM, a table-pointer write -- and reset
    * clear both.  A context write does not: entries carry their context.  A walk
    * in flight across a flush fills neither (r_nofill).  The walk's context is
    * latched when it starts (r_wctx). */
   localparam LG_L2T = `LG_L2TLB_ENTRIES;
   localparam LG_WC = `LG_WALKC_ENTRIES;
   localparam L2T_ON = (LG_L2T != 0);
   localparam WC_ON = (LG_WC != 0);
   localparam LG_L2T_A = L2T_ON ? LG_L2T : 1;
   localparam LG_WC_A = WC_ON ? LG_WC : 1;
   typedef struct packed {
      logic [`SRMMU_CTX_BITS-1:0] ctx;
      logic [19:0] 		  tag;    /* VA[31:12] */
      logic [31:0] 		  pte;
   } l2t_ent_t;
   typedef struct packed {
      logic [`SRMMU_CTX_BITS-1:0] ctx;
      logic [13:0] 		  tag;    /* VA[31:18] */
      logic [31:0] 		  ptd;
   } wc_ent_t;
   l2t_ent_t r_l2t[(1<<LG_L2T_A)-1:0];
   wc_ent_t r_wc[(1<<LG_WC_A)-1:0];
   l2t_ent_t r_l2t_q;
   wc_ent_t r_wc_q;
   logic [(1<<LG_L2T_A)-1:0] r_l2t_v;
   logic [(1<<LG_WC_A)-1:0] r_wc_v;
   logic [`SRMMU_CTX_BITS-1:0] r_wctx, n_wctx;
   logic r_nofill, n_nofill;
   logic t_l2t_wr, t_wc_wr;
   function automatic logic [LG_L2T_A-1:0] l2t_idx(input logic [31:0] va, input logic [`SRMMU_CTX_BITS-1:0] c);
      begin
	 l2t_idx = LG_L2T_A'(va[31:12]) ^ LG_L2T_A'(c);
      end
   endfunction
   function automatic logic [LG_WC_A-1:0] wc_idx(input logic [31:0] va);
      begin
	 wc_idx = LG_WC_A'(va[31:18]);
      end
   endfunction
   wire w_l2t_hit = L2T_ON & r_l2t_v[l2t_idx(r_va, r_wctx)] & (r_l2t_q.ctx == r_wctx) & (r_l2t_q.tag == r_va[31:12]);
   wire w_wc_hit = WC_ON & r_wc_v[wc_idx(r_va)] & (r_wc_q.ctx == r_wctx) & (r_wc_q.tag == r_va[31:18]);

   /* the PTE word at r_ea in a 128-bit line: bus word k holds the bytes at
    * line+4k little-endian, so the big-endian entry is that word byte-swapped */
   wire [31:0] w_bus_word = (r_ea[3:2] == 2'd0) ? mem_rsp_data[31:0] :
			    (r_ea[3:2] == 2'd1) ? mem_rsp_data[63:32] :
			    (r_ea[3:2] == 2'd2) ? mem_rsp_data[95:64] :
			    mem_rsp_data[127:96];
   wire [31:0] w_entry = {w_bus_word[7:0], w_bus_word[15:8], w_bus_word[23:16], w_bus_word[31:24]};
   wire [31:0] w_wr_word = {r_pte[7:0], r_pte[15:8], r_pte[23:16], r_pte[31:24]};

   /* the next table entry: (PTP << 4) + 4*index, the index from the VA bits of
    * the level being entered */
   wire [7:0] w_idx = (r_level == 2'd0) ? r_va[31:24] :
		      (r_level == 2'd1) ? {2'd0, r_va[23:18]} :
		      {2'd0, r_va[17:12]};
   /* SRMMU probe type va[11:8] -> the walk level it stops at: context 0,
    * region 1, segment 2, page/entire 3 (the leaf) */
   wire [3:0] w_probe_type = r_va[11:8];
   wire [1:0] w_probe_stop = (w_probe_type == 4'd3) ? 2'd0 :
			     (w_probe_type == 4'd2) ? 2'd1 :
			     (w_probe_type == 4'd1) ? 2'd2 :
			     2'd3;
   wire [`PA_WIDTH-1:0] w_next_ea = {w_entry[31:2], 6'd0} + {26'd0, w_idx, 2'd0};

   assign mem_req_valid = r_mem_req;
   assign mem_req_addr = {r_ea[`PA_WIDTH-1:4], 4'd0};
   assign mem_req_store = r_mem_store;
   assign mem_req_mask = 16'hf << {r_ea[3:2], 2'd0};
   assign mem_req_data = {w_wr_word, w_wr_word, w_wr_word, w_wr_word};
   assign mem_lock = r_lock;
   assign l1i_rsp_valid = r_l1i_rsp;
   assign l1d_rsp_valid = r_l1d_rsp;
   assign walk_pte = r_pte;

   always_comb
     begin
	page_walk_rsp.fault = r_fault;
	page_walk_rsp.ft = r_ft;
	page_walk_rsp.level = r_level;
	page_walk_rsp.ppn = r_pte[31:8];
	page_walk_rsp.c = r_pte[7];
	page_walk_rsp.m = r_pte[6];
	page_walk_rsp.acc = r_pte[4:2];
     end // always_comb

   always_comb
     begin
	n_state = r_state;
	n_ea = r_ea;
	n_va = r_va;
	n_level = r_level;
	n_pte = r_pte;
	n_do_l1i = r_do_l1i;
	n_do_mark = r_do_mark;
	n_do_probe = r_do_probe;
	n_l1i_req = r_l1i_req | l1i_req;
	n_l1d_req = r_l1d_req | l1d_req;
	n_fault = r_fault;
	n_ft = r_ft;
	n_mem_req = r_mem_req;
	n_mem_store = r_mem_store;
	n_lock = r_lock;
	n_l1i_rsp = 1'b0;
	n_l1d_rsp = 1'b0;
	n_wctx = r_wctx;
	n_nofill = r_nofill | r_tlb_flush;
	t_l2t_wr = 1'b0;
	t_wc_wr = 1'b0;
	if(mem_req_ack)
	  begin
	     n_mem_req = 1'b0;
	  end
	case(r_state)
	  IDLE:
	    begin
	       n_level = 2'd0;
	       n_fault = 1'b0;
	       n_ft = FT_NONE;
	       n_ea = {r_ctpr[31:2], 6'd0} + {{(`PA_WIDTH-`SRMMU_CTX_BITS-2){1'b0}}, r_ctx, 2'd0};
	       if(n_l1d_req)
		 begin
		    n_l1d_req = 1'b0;
		    n_do_mark = l1d_mark;
		    n_do_probe = l1d_probe;
		    n_do_l1i = 1'b0;
		    n_va = l1d_va;
		    n_wctx = r_ctx;
		    n_nofill = r_tlb_flush;
		    /* probes and mark walks go to memory */
		    n_state = (l1d_mark | l1d_probe) ? RD : LOOKUP;
		 end
	       else if(n_l1i_req)
		 begin
		    n_l1i_req = 1'b0;
		    n_do_mark = 1'b0;
		    n_do_probe = 1'b0;
		    n_do_l1i = 1'b1;
		    n_va = l1i_va;
		    n_wctx = r_ctx;
		    n_nofill = r_tlb_flush;
		    n_state = LOOKUP;
		 end
	    end
	  LOOKUP:
	    begin
	       /* r_l2t_q / r_wc_q were read with this walk's VA.  A flush since the
		* walk started (its valid bits clear a cycle later) is a miss */
	       if(w_l2t_hit & !(r_nofill | r_tlb_flush))
		 begin
		    n_pte = r_l2t_q.pte;
		    n_level = 2'd3;
		    n_state = DONE;
		 end
	       else if(w_wc_hit & !(r_nofill | r_tlb_flush))
		 begin
		    /* straight to the level-3 entry: PTD << 4 + 4 * VA[17:12] */
		    n_ea = {r_wc_q.ptd[31:2], 6'd0} + {26'd0, 2'd0, r_va[17:12], 2'd0};
		    n_level = 2'd3;
		    n_state = RD;
		 end
	       else
		 begin
		    n_state = RD;
		 end
	    end
	  RD:
	    begin
	       n_mem_req = 1'b1;
	       n_mem_store = 1'b0;
	       n_lock = 1'b1;
	       n_state = RD_WAIT;
	    end
	  RD_WAIT:
	    begin
	       if(mem_rsp_valid)
		 begin
		    n_pte = w_entry;
		    if(w_entry[1:0] == 2'd2)
		      begin
			 /* PTE: write back R (and, for a retire-side request, M) if
			  * either is missing; a probe only reads it (interpret.cc
			  * asi_load) */
			 n_pte = r_do_probe ? w_entry : (w_entry | 32'h20 | (r_do_mark ? 32'h40 : 32'h0));
			 n_state = (n_pte != w_entry) ? WR : DONE;
		      end
		    else if((w_entry[1:0] == 2'd1) && r_do_probe && (r_level == w_probe_stop) && (r_level != 2'd3))
		      begin
			 /* a probe stops at its type's level and answers with the
			  * PTD there (interpret.cc srmmu_probe) */
			 n_state = DONE;
		      end
		    else if((w_entry[1:0] == 2'd1) && (r_level != 2'd3))
		      begin
			 /* a level-2 PTD: the walk cache's entry for this 256KB */
			 t_wc_wr = WC_ON & (r_level == 2'd2) & !r_do_probe & !n_nofill;
			 n_ea = w_next_ea;
			 n_level = r_level + 2'd1;
			 n_lock = 1'b0;
			 n_state = RD;
		      end
		    else
		      begin
			 n_fault = 1'b1;
			 n_ft = (w_entry[1:0] == 2'd0) ? FT_INVALID : FT_TRANSLATION;
			 n_state = DONE;
		      end
		 end
	    end
	  WR:
	    begin
	       n_mem_req = 1'b1;
	       n_mem_store = 1'b1;
	       n_state = WR_WAIT;
	    end
	  WR_WAIT:
	    begin
	       if(mem_rsp_valid)
		 begin
		    n_state = DONE;
		 end
	    end
	  DONE:
	    begin
	       /* a completed 4KB translation (as written back: R, and M for a mark
		* walk) goes into the second-level TLB */
	       t_l2t_wr = L2T_ON & !r_fault & !r_do_probe & (r_level == 2'd3) & !n_nofill;
	       n_lock = 1'b0;
	       n_l1i_rsp = r_do_l1i;
	       n_l1d_rsp = !r_do_l1i;
	       n_state = IDLE;
	    end
	  default:
	    begin
	    end
	endcase // case (r_state)
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset | sys_reset)
	  begin
	     r_state <= IDLE;
	     r_l1i_req <= 1'b0;
	     r_l1d_req <= 1'b0;
	     r_mem_req <= 1'b0;
	     r_lock <= 1'b0;
	     r_l1i_rsp <= 1'b0;
	     r_l1d_rsp <= 1'b0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_l1i_req <= n_l1i_req;
	     r_l1d_req <= n_l1d_req;
	     r_mem_req <= n_mem_req;
	     r_lock <= n_lock;
	     r_l1i_rsp <= n_l1i_rsp;
	     r_l1d_rsp <= n_l1d_rsp;
	  end
	r_ea <= n_ea;
	r_va <= n_va;
	r_level <= n_level;
	r_pte <= n_pte;
	r_do_l1i <= n_do_l1i;
	r_do_mark <= n_do_mark;
	r_do_probe <= n_do_probe;
	r_wctx <= n_wctx;
	r_fault <= n_fault;
	r_ft <= n_ft;
	r_mem_store <= n_mem_store;
     end // always_ff@ (posedge clk)

   /* the walker caches: registered reads with the next VA (valid in LOOKUP),
    * one write port each; the valid bits are flops so a flush clears them at once */
   always_ff@(posedge clk)
     begin
	r_l2t_q <= r_l2t[l2t_idx(n_va, n_wctx)];
	r_wc_q <= r_wc[wc_idx(n_va)];
	if(t_l2t_wr)
	  begin
	     r_l2t[l2t_idx(r_va, r_wctx)] <= '{ctx: r_wctx, tag: r_va[31:12], pte: r_pte};
	  end
	if(t_wc_wr)
	  begin
	     r_wc[wc_idx(r_va)] <= '{ctx: r_wctx, tag: r_va[31:18], ptd: w_entry};
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(reset | sys_reset | r_tlb_flush)
	  begin
	     r_l2t_v <= 'd0;
	     r_wc_v <= 'd0;
	     r_nofill <= 1'b1;
	  end
	else
	  begin
	     r_nofill <= n_nofill;
	     if(t_l2t_wr)
	       begin
		  r_l2t_v[l2t_idx(r_va, r_wctx)] <= 1'b1;
	       end
	     if(t_wc_wr)
	       begin
		  r_wc_v[wc_idx(r_va)] <= 1'b1;
	       end
	  end
     end // always_ff@ (posedge clk)

`ifdef VERILATOR
   /* the checker mirrors a walk-time R write (a mark walk is for a store the
    * ISS executes, and it sets R and M itself) */
   always_ff@(posedge clk)
     begin
	if(!reset && (r_state == WR_WAIT) && mem_rsp_valid && !r_do_mark)
	  begin
	     mmu_set_ref(64'(r_ea), r_pte);
	  end
     end
`endif

`ifdef VERILATOR
   /* walker accounting (sim only): requests by side, how each was answered, the
    * memory reads they cost and the cycles the walker was busy */
   longint unsigned c_req_i, c_req_d, c_l2t_hit, c_wc_hit, c_full, c_rd, c_busy, c_probe_mark;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     c_req_i <= 0; c_req_d <= 0; c_l2t_hit <= 0; c_wc_hit <= 0; c_full <= 0; c_rd <= 0; c_busy <= 0; c_probe_mark <= 0;
	  end
	else
	  begin
	     if((r_state == IDLE) && (n_state != IDLE))
	       begin
		  if(n_do_l1i) c_req_i <= c_req_i + 1; else c_req_d <= c_req_d + 1;
		  if(n_state == RD) c_probe_mark <= c_probe_mark + 1;
	       end
	     if(r_state == LOOKUP)
	       begin
		  if(n_state == DONE) c_l2t_hit <= c_l2t_hit + 1;
		  else if(n_level == 2'd3) c_wc_hit <= c_wc_hit + 1;
		  else c_full <= c_full + 1;
	       end
	     if(r_state == RD) c_rd <= c_rd + 1;
	     if(r_state != IDLE) c_busy <= c_busy + 1;
	  end
     end
   final
     begin
	$display("[WALK] requests I %0d D %0d; L2TLB hits %0d, walk-cache hits %0d, full walks %0d, probe/mark %0d; PTE reads %0d; walker busy cycles %0d",
		 c_req_i, c_req_d, c_l2t_hit, c_wc_hit, c_full, c_probe_mark, c_rd, c_busy);
     end
`endif
endmodule // mmu
