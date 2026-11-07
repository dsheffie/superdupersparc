`include "machine.vh"
`include "rob.vh"

/* SRMMU TLB (one per L1), after rv64core's tlb.sv: fully associative, outputs
 * registered (valid the cycle after req), round-robin replacement, filled from
 * the walker's response.  An entry is tagged by context and by the VA bits its
 * level translates: level 0 (a context-table PTE) maps all 4 GB, 1 = VA[31:24]
 * (16 MB), 2 = VA[31:18] (256 KB), 3 = VA[31:12] (4 KB).  The PA keeps the PTE's
 * PPN above the level's offset and the VA below it (interpret.cc pte_pa_of).
 * Permission checks (ACC vs supervisor) are the L1's: the TLB hands back ACC.
 * With the MMU off (active = 0) every lookup hits with PA = VA, cacheable. */
module tlb(clk,
	   reset,
	   clear,
	   active,
	   ctx,
	   req,
	   va,
	   pa,
	   hit,
	   acc,
	   level,
	   c,
	   m,
	   replace,
	   replace_va,
	   page_walk_rsp,
	   set_m,
	   set_m_va);

   input logic clk;
   input logic reset;
   input logic clear;
   input logic active;
   input logic [`SRMMU_CTX_BITS-1:0] ctx;
   input logic req;
   input logic [31:0] va;
   output logic [`PA_WIDTH-1:0] pa;
   output logic hit;
   output logic [2:0] acc;
   output logic [1:0] level;
   output logic c;
   output logic m;
   /* fill from a walk (the context is the current one) */
   input logic replace;
   input logic [31:0] replace_va;
   input page_walk_rsp_t page_walk_rsp;
   /* the walker set M in the PTE: set it in the entry that maps set_m_va */
   input logic set_m;
   input logic [31:0] set_m_va;

   parameter N = 8;
   parameter ID = 0;   /* the checker's name for it (top.cc tlb_fill): 0 dtlb, 1 itlb */
   localparam LG_N = $clog2(N);
`ifdef VERILATOR
   /* every fill, for the checker: it walks the same VA and context in the ISS's
    * memory and reports a translation that differs (a stale or mis-tagged entry
    * shows where it is made, not at the load that finally uses it) */
   import "DPI-C" function void tlb_fill(input int id, input int va, input int ctx, input int ppn,
					  input int level, input int c, input int acc);
   always_ff@(posedge clk)
     begin
	if(!reset && replace && !page_walk_rsp.fault)
	  begin
	     tlb_fill(ID, int'(replace_va), int'(ctx), int'(page_walk_rsp.ppn), int'(page_walk_rsp.level),
		      int'(page_walk_rsp.c), int'(page_walk_rsp.acc));
	  end
     end
`endif

   logic [N-1:0] r_valid;
   logic [N-1:0] r_c;
   logic [N-1:0] r_m;
   logic [2:0]	 r_acc[N-1:0];
   logic [1:0]	 r_level[N-1:0];
   logic [19:0]	 r_va_tag[N-1:0];   /* VA[31:12]; the level picks how much compares */
   logic [`SRMMU_CTX_BITS-1:0] r_ctx[N-1:0];
   logic [23:0]	 r_ppn[N-1:0];

   function automatic logic tag_match(input logic [1:0] level, input logic [19:0] tag, input logic [31:0] v);
      tag_match = (level == 2'd0) ? 1'b1 :
		  (level == 2'd1) ? (tag[19:12] == v[31:24]) :
		  (level == 2'd2) ? (tag[19:6] == v[31:18]) :
		  (tag == v[31:12]);
   endfunction // tag_match

   logic [N-1:0] w_hits, w_m_hits, w_rep_hits;
   always_comb
     begin
	for(integer i = 0; i < N; i = i + 1)
	  begin
	     w_hits[i] = r_valid[i] & (r_ctx[i] == ctx) & tag_match(r_level[i], r_va_tag[i], va);
	     w_m_hits[i] = r_valid[i] & (r_ctx[i] == ctx) & tag_match(r_level[i], r_va_tag[i], set_m_va);
	     w_rep_hits[i] = r_valid[i] & (r_ctx[i] == ctx) & tag_match(r_level[i], r_va_tag[i], replace_va);
	  end
     end // always_comb

   /* hit -> index.  A VA should match one entry (a fill that already hits
    * replaces that entry, below), but take the lowest anyway: the old one-hot OR
    * turned a double hit (the I-side filling the same page twice) into a third,
    * unrelated entry's translation -- the fetch then read another page's code. */
   logic [LG_N-1:0] t_idx;
   always_comb
     begin
	t_idx = 'd0;
	for(integer i = N - 1; i >= 0; i = i - 1)
	  begin
	     if(w_hits[i])
	       begin
		  t_idx = LG_N'(i);
	       end
	  end
     end // always_comb

   /* a fill goes over the entry that already maps replace_va, if any, else the
    * round-robin victim */
   logic [LG_N-1:0] t_rep_idx;
   always_comb
     begin
	t_rep_idx = r_replace;
	for(integer i = N - 1; i >= 0; i = i - 1)
	  begin
	     if(w_rep_hits[i])
	       begin
		  t_rep_idx = LG_N'(i);
	       end
	  end
     end // always_comb

`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
	if(!reset && active && req && ($countones(w_hits) > 1))
	  begin
	     $display("[TLB] N=%0d multiple hits %b for va %x", N, w_hits, va);
	     $stop();
	  end
     end
`endif

   wire [1:0]  w_level = r_level[t_idx];
   wire [23:0] w_ppn = r_ppn[t_idx];
   wire [`PA_WIDTH-1:0] w_pa = (w_level == 2'd0) ? {w_ppn[23:20], va[31:0]} :
			       (w_level == 2'd1) ? {w_ppn[23:12], va[23:0]} :
			       (w_level == 2'd2) ? {w_ppn[23:6], va[17:0]} :
			       {w_ppn, va[11:0]};

   always_ff@(posedge clk)
     begin
	hit <= reset ? 1'b0 : (active ? (req & (|w_hits)) : 1'b1);
	pa <= active ? w_pa : `PA_WIDTH'(va);
	acc <= r_acc[t_idx];
	level <= w_level;
	c <= active ? r_c[t_idx] : 1'b1;
	m <= active ? r_m[t_idx] : 1'b1;
     end // always_ff@ (posedge clk)

   logic [LG_N-1:0] r_replace, n_replace;
   always_comb
     begin
	n_replace = r_replace;
	if(replace && (w_rep_hits == 'd0))
	  begin
	     n_replace = ({1'b0, r_replace} == (N-1)) ? 'd0 : (r_replace + 'd1);
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	r_replace <= reset ? 'd0 : n_replace;
     end

   always_ff@(posedge clk)
     begin
	if(reset || clear)
	  begin
	     r_valid <= 'd0;
	  end
	else if(replace)
	  begin
	     r_valid[t_rep_idx] <= 1'b1;
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(replace)
	  begin
	     r_c[t_rep_idx] <= page_walk_rsp.c;
	     r_acc[t_rep_idx] <= page_walk_rsp.acc;
	     r_level[t_rep_idx] <= page_walk_rsp.level;
	     r_va_tag[t_rep_idx] <= replace_va[31:12];
	     r_ctx[t_rep_idx] <= ctx;
	     r_ppn[t_rep_idx] <= page_walk_rsp.ppn;
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	for(integer i = 0; i < N; i = i + 1)
	  begin
	     if(replace && (t_rep_idx == LG_N'(i)))
	       begin
		  r_m[i] <= page_walk_rsp.m;
	       end
	     else if(set_m && w_m_hits[i])
	       begin
		  r_m[i] <= 1'b1;
	       end
	  end
     end // always_ff@ (posedge clk)

endmodule // tlb
