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
	   ctrl_e,
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
   output logic ctrl_e;
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
		  n_tlb_flush = 1'b1;
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
	if(fault_valid)
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
	     r_ctrl <= 32'h00000800;   /* MCR_MMODE: MBus mode */
	     r_ctpr <= 32'd0;
	     r_ctx <= 'd0;
`endif
	     r_fsr <= 32'd0;
	     r_far <= 32'd0;
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
		    n_state = RD;
		 end
	       else if(n_l1i_req)
		 begin
		    n_l1i_req = 1'b0;
		    n_do_mark = 1'b0;
		    n_do_probe = 1'b0;
		    n_do_l1i = 1'b1;
		    n_va = l1i_va;
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
		    else if((w_entry[1:0] == 2'd1) && (r_level != 2'd3))
		      begin
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
	if(reset)
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
	r_fault <= n_fault;
	r_ft <= n_ft;
	r_mem_store <= n_mem_store;
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

endmodule // mmu
