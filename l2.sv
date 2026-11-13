`include "machine.vh"

module l2(clk,
	  reset,
	  state,
	  rsp_state,
	  l1i_flush_req,
	  l1d_flush_req,

	  l1i_flush_complete,
	  l1d_flush_complete,
	  
	  flush_complete,

	  //l1 -> l2
	  l1_mem_req_valid,
	  l1_mem_req_ack,
	  l1_mem_req_addr,
	  l1_mem_req_cacheable,
	  l1_mem_req_mask,
	  l1_mem_req_store_data,
	  l1_mem_req_opcode,
	  l1_mem_req_from_d,
	  l1_mem_req_colour,
	  l1_mem_req_src,
	  l2_nocache,

	  //l2 -> l1
	  l1_mem_rsp_valid,
	  l1_mem_rsp_bad,
	  l1_mem_rsp_src,
	  l1_mem_load_data,

	  //l2 -> mem
	  mem_req_ack,
	  mem_req_valid, 
	  mem_req_addr, 
	  mem_req_store_data, 
	  mem_req_opcode,
	  mem_req_mask,
	  mem_req_uncached,
	  
	  //mem -> l2
	  mem_rsp_valid,
	  mem_rsp_bad,
	  mem_rsp_retry,
	  mem_rsp_load_data,

	  cache_hits,
	  cache_accesses,

	  // DMA-coherence snoop (from henry's snoop FIFO): invalidate one L2 line per request.
	  snoop_req_valid,
	  snoop_req_addr,
	  snoop_req_ack,
	  snoop_req_wbinv,
	  snoop_done,

	  // stage B: back-invalidate probe to the L1D
	  probe_req,
	  probe_addr,
	  probe_colour,
	  probe_ack,
	  probe_dirty,
	  probe_data,

	  // R10000 block op: invalidate the block in the L1I
	  l1i_blk_inv_req,
	  l1i_blk_inv_addr,
	  l1i_blk_inv_line,
	  l1i_blk_inv_done
	  );

   input logic clk;
   input logic reset;
   output logic [3:0] state;
   output logic [3:0] rsp_state;
   
   input logic l1i_flush_req;
   input logic l1d_flush_req;
   input logic l1i_flush_complete;
   input logic l1d_flush_complete;
   
   output logic flush_complete;

   input logic 	l1_mem_req_valid;
   output logic l1_mem_req_ack;
   input logic [`PA_WIDTH-1:0] l1_mem_req_addr;
   input logic	      l1_mem_req_cacheable;
   /* l2_nocache (driver-set BEFORE `go`, static during a run): entirely disable the L2 as a
    * cache.  Route cacheable DATA ops (loads/stores/line-fills, opcode < MEM_INVL=24) down the
    * uncached pass-through-to-DRAM path so the L2 NEVER fills a line -> holds nothing -> no stale
    * reservoir AND no inclusivity vs the L1D.  CACHE-management ops (>=24) stay cacheable so their
    * handlers still run (find an empty L2, ack/write through).  l2_nocache=0 => normal L2.  Set
    * before-go only, so no mid-run flush needed (no lines exist to go stale). Was `ENABLE_L2_NOCACHE. */
   wire w_l2_cacheable = l1_mem_req_cacheable & (~l2_nocache | (l1_mem_req_opcode >= 6'd24));
   /* L1I presence (pi, ipres_ram below): the L1I may hold this L2 line.  Kept so
    * that the L1I holds a line only while the L2 does, with pi set -- the L1I is
    * inclusive in the L2 -- so the L2 drops a line from the L1I (one line, every
    * L1I colour) exactly when it must:
    *  - before it replaces or invalidates an entry with pi set, for any reason (the
    *    tag RAM keeps the old tag when an entry is invalidated, so the drop names
    *    the right line even then; a flush leaves pi for the next access to drop);
    *  - before an uncached store or atomic writes around a line the L1I may hold
    *    (OBP patches code with the caches disabled, MCR.IE clear, and no FLUSH);
    *  - with ENABLE_COHERENT_L1I, before an L1D fill of such a line (a line lives
    *    in the L1I XOR the L1D).
    * A line the L2 does not hold, or holds with pi clear, is in no L1I: an L1D
    * miss on data no longer waits for an L1I walk. */
   input logic l2_nocache;
   input logic [15:0] l1_mem_req_mask;
   
   input logic [127:0] l1_mem_req_store_data;
   input logic [5:0] l1_mem_req_opcode;   /* mem_op_t; the memory side (mem_req_opcode) stays 5 bits */
   /* the granted request is the L1D's (the arbiter's address mux selects the L1D unless
    * it is in GNT_L1I) -- presence tracking only records L1D fills */
   input logic       l1_mem_req_from_d;
   /* stage C2: the L1D set colour (index bits above the page offset) the request's
    * line lives at in the VA-indexed L1D -- what pidx records */
   input logic [`L1D_N_COLOUR-1:0] l1_mem_req_colour;
   /* the requester (0 L1D, 1 L1I, 2 MMU, 3.. the L1D's second-miss engines): returned with its response, which the arbiter
    * routes by it -- with L2_HIT_UNDER_MISS a response need not be the last request's */
   input logic [2:0] l1_mem_req_src;

   output logic        l1_mem_rsp_valid;
   output logic        l1_mem_rsp_bad;     /* uncached load answered with a bus error */
   output logic [2:0]  l1_mem_rsp_src;
   output logic [127:0] l1_mem_load_data;
   
   input logic 	mem_req_ack;
   output logic mem_req_valid;
   output logic [`PA_WIDTH-1:0] mem_req_addr;
   output logic [127:0] mem_req_store_data;
   output logic [4:0] 	mem_req_opcode;
   output logic [15:0]	mem_req_mask;
   output logic 	mem_req_uncached;   /* this request is an uncached load/store (non-speculative) */
   
   input logic 		mem_rsp_valid;
   input logic		mem_rsp_bad;
   /* with mem_rsp_valid: the uncached load was NACKed (Kodiak's ARM-served device
    * window, when the ARM needs a snoop while it holds the load -- as an MBus
    * relinquish-and-retry): no data; the L2 serves snoops, then re-issues it */
   input logic		mem_rsp_retry;
   
   input logic [127:0] 	mem_rsp_load_data;

   output logic [63:0] cache_hits;
   output logic [63:0] cache_accesses;
   input logic 	       snoop_req_valid;
   input logic [`PA_WIDTH-1:0] snoop_req_addr;
   output logic        snoop_req_ack;
   /* snoop op: 0 = discard (MEM_SNOOP_INVL: drop the L2 copy, no writeback, no L1D
    * probe -- the DMA-in discard); 1 = WBINV: probe the L1D at pidx if pd, write any
    * dirty copy (L1D or L2) back to DRAM, invalidate.  WBINV is architecturally
    * invisible (it only evicts), so it can be injected at random as a stress. */
   input logic 	       snoop_req_wbinv;
   output logic        snoop_done;   /* pulses when a snoop has fully completed */
   /* inclusive-l2-v2 stage B: before evicting a line the L1D may hold (pd) on behalf of an
    * L1I miss, back-invalidate it in the L1D.  probe_req/probe_addr are held until
    * probe_ack; a dirty L1D copy comes back on probe_data and is what gets written back. */
   output logic 	      probe_req;
   output logic [`PA_WIDTH-1:0] probe_addr;
   output logic [`L1D_N_COLOUR-1:0] probe_colour;   /* the L1D set colour to probe (= pidx) */
   input logic 		      probe_ack;
   input logic 		      probe_dirty;
   input logic [127:0] 	      probe_data;
   /* the L1I is not covered by inclusion, so a block op also invalidates the block
    * there: a pulse with the block's address on accepting it, and the L1D's answer
    * waits for the L1I's done */
   output logic 	      l1i_blk_inv_req;
   output logic [`PA_WIDTH-1:0] l1i_blk_inv_addr;
   /* with l1i_blk_inv_req: drop only the line at l1i_blk_inv_addr (at every colour),
    * not its 128-byte block -- the coherence drop before an L1D fill or write-around,
    * which concerns one line (a block op still clears the block) */
   output logic 		      l1i_blk_inv_line;
   input logic 		      l1i_blk_inv_done;
   logic 		      r_probe_req, n_probe_req;
   logic [`PA_WIDTH-1:0]      r_probe_addr, n_probe_addr;
   logic [`L1D_N_COLOUR-1:0]  r_probe_colour, n_probe_colour;
   /* why the probe was sent (stats only): 0 L1I-miss eviction, 1 L1D-miss eviction of an
    * line (any colour), 2 alias on a fill, 3 alias on an INVL, 4 alias on a PGDROP,
    * 5 external WBINV snoop, 6 external DROP snoop, 7 R10000 block op, 8 uncached hit,
    * 9 coherent-L1I fill */
   logic [3:0] 		      r_probe_reason, n_probe_reason;
   logic 		      r_probed, n_probed;
   logic 		      r_probe_dirty, n_probe_dirty;
   logic [127:0] 	      r_probe_data, n_probe_data;
   assign probe_req = r_probe_req;
   assign probe_addr = r_probe_addr;
   assign probe_colour = r_probe_colour;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_probe_req <= 1'b0;
	     r_probe_addr <= 'd0;
	     r_probe_colour <= 'd0;
	     r_probe_reason <= 'd0;
	     r_probed <= 1'b0;
	     r_probe_dirty <= 1'b0;
	     r_probe_data <= 'd0;
	  end
	else
	  begin
	     r_probe_req <= n_probe_req;
	     r_probe_addr <= n_probe_addr;
	     r_probe_colour <= n_probe_colour;
	     r_probe_reason <= n_probe_reason;
	     r_probed <= n_probed;
	     r_probe_dirty <= n_probe_dirty;
	     r_probe_data <= n_probe_data;
	  end
     end
   logic 	       r_snoop_ack, n_snoop_ack;
   assign snoop_req_ack = r_snoop_ack;
   logic 	       r_snp_wbinv, n_snp_wbinv;
   logic 	       r_snoop_done, n_snoop_done;
   assign snoop_done = r_snoop_done;
   /* a NACKed uncached load waiting to be re-issued (from IDLE, after any snoop) */
   logic 	       r_rty_pend, n_rty_pend;
   logic [`PA_WIDTH-1:0] r_rty_addr, n_rty_addr;
   logic [4:0] 	       r_rty_mem_op, n_rty_mem_op;
   logic [15:0]        r_rty_mask, n_rty_mask;
   logic [127:0]       r_rty_data, n_rty_data;
   logic [5:0] 	       r_rty_opcode, n_rty_opcode;
   logic 	       r_rty_from_d, n_rty_from_d;
   /* R10000 block op (MEM_BLK_*): acked on arrival, then IDLE launches its eight 16-byte
    * lines one at a time and, once all eight are done and the L1I has invalidated the
    * block (r_blk_l1i_done), answers the L1D.  r_blk_cnt = the next line (8 = all
    * launched), r_blk_way = address bit 0, the index form's way select. */
   logic 	       r_blk_pend, n_blk_pend;
   logic [3:0] 	       r_blk_cnt, n_blk_cnt;
   logic 	       r_blk_l1i_req, n_blk_l1i_req;
   /* the CHECK_VALID_AND_TAG L1I drop (pi): requested and waiting, and done for
    * this request (as r_probe_req / r_probed for the L1D) */
   logic 	       r_idrop_wait, n_idrop_wait;
   logic 	       r_idropped, n_idropped;
   logic 	       r_blk_l1i_done, n_blk_l1i_done;
   assign l1i_blk_inv_req = r_blk_l1i_req;
   logic [`PA_WIDTH-1:7] r_blk_addr, n_blk_addr;
   logic [2:0] 	       r_ci_lsel, n_ci_lsel;   /* the coherence drop's line in r_blk_addr */
   logic 	       r_inv_line, n_inv_line;   /* the L1I drop in flight is that one line */
   assign l1i_blk_inv_addr = {r_blk_addr, r_inv_line ? r_ci_lsel : 3'd0, 4'd0};
   assign l1i_blk_inv_line = r_inv_line;
   logic [5:0] 	       r_blk_op, n_blk_op;
   logic 	       r_blk_way, n_blk_way;
   function automatic logic is_blkop(logic [5:0] op);
      begin
`ifdef ENABLE_R10000
	 is_blkop = (op == MEM_BLK_WBINV) | (op == MEM_BLK_INV) | (op == MEM_BLK_IDX);
`else
	 is_blkop = 1'b0;   /* never decoded: the sequencer synthesizes away */
`endif
      end
   endfunction
`ifdef VERILATOR
   logic [63:0]        r_snoop_hit, n_snoop_hit, r_snoop_dirty, n_snoop_dirty;
   logic [63:0]        r_pd_drop_n;   /* sim: [l2-pd-drop] print limiter */
`endif
   
   
   localparam LG_L2_LINES = `LG_L2_NUM_SETS;
   localparam L2_LINES = 1<<LG_L2_LINES;
   
   localparam TAG_BITS = `PA_WIDTH - (LG_L2_LINES + 4);
   /* L2_WAYS (machine.vh): LG_L2_LINES is the sets per way.  LG_WAYS is the width
    * of a way number, kept >= 1 so a one-way L2 still declares its counters. */
   localparam L2_WAYS = `L2_WAYS;
   localparam LG_WAYS = (L2_WAYS > 1) ? $clog2(L2_WAYS) : 1;
   localparam REPL = `L2_REPL;
   localparam RRIP = (REPL == `L2_REPL_SRRIP) || (REPL == `L2_REPL_BRRIP) || (REPL == `L2_REPL_DRRIP);
   /* per-set replacement state: an NRU bit, or a 2-bit RRPV, per way (RAND keeps none) */
   localparam REPL_W = RRIP ? (2 * L2_WAYS) : L2_WAYS;

   logic 		t_wr_dirty, t_wr_valid;
   logic 		t_wr_d0, t_wr_tag;
   
   logic 		t_valid, t_dirty;
   logic [LG_L2_LINES-1:0] t_idx, r_idx;
   logic [TAG_BITS-1:0]	   n_tag, r_tag;
   logic [`PA_WIDTH-1:0]	   n_addr, r_addr;
   logic [`PA_WIDTH-1:0]	   n_saveaddr, r_saveaddr;
   
   logic [5:0] 		   n_opcode, r_opcode;

   logic 		   r_mem_req, n_mem_req;
   logic [4:0] 		   r_mem_opcode, n_mem_opcode;
   logic 		   r_req_ack, n_req_ack;
   
   logic 		   r_rsp_valid, n_rsp_valid;
   logic 		   r_rsp_bad, n_rsp_bad;
   logic [127:0] 	   r_rsp_data, n_rsp_data;
   logic [127:0] 	   r_store_data, n_store_data;
   logic [15:0]		   r_store_mask, n_store_mask;
   logic			   n_is_uncache, r_is_uncache;
   logic [15:0]		   n_uncache_mask, r_uncache_mask;
   
   
   logic 		   r_reload, n_reload;
   
   typedef enum logic  {
			     WAIT_FOR_FLUSH,
			     WAIT_FOR_L1_FLUSH_DONE
			     } flush_state_t;

   logic 	r_need_l1i,n_need_l1i,r_need_l1d,n_need_l1d;
   /* An L1I-only flush (the I-side CACHE op) must NOT walk every L2 line -- the
    * I-cache is read-only and the D-side already writes its lines through to DRAM,
    * so the O(L2_size) writeback walk was pure waste (dominated the boot on a large
    * L2; TIP charged 95% of cycles to the cache-op PC). r_had_l1d = did THIS flush
    * sequence involve an L1D flush (-> a real L2 writeback is needed); r_flush_skip =
    * the pending flush should complete WITHOUT the walk. */
   logic 	r_had_l1d, n_had_l1d;
   logic 	t_l2_skip_walk;
   logic 	r_flush_skip, n_flush_skip;
   logic 	t_l2_flush_req;
   
   flush_state_t n_flush_state, r_flush_state;
   
   
   typedef enum 	logic [3:0] {
				     INITIALIZE = 'd0,
				     IDLE = 'd1,
				     WAIT_FOR_RAM = 'd2,
				     CHECK_VALID_AND_TAG = 'd3,
				     CLEAN_RELOAD = 'd4,
				     DIRTY_STORE = 'd5,
				     STORE_TURNAROUND = 'd6,
				     WAIT_CLEAN_RELOAD = 'd7,
				     WAIT_STORE_IDLE = 'd8,
				     FLUSH_STORE = 'd9,
				     FLUSH_WAIT = 'd10,
				     FLUSH_TRIAGE = 'd11,
				     UNCACHE_STORE = 'd12,
				     UNCACHE_LOAD = 'd13,
				     UNCACHE_WB_TURNAROUND = 'd14,   /* was GAMEOVER (dead): mem_req gap after WB drain */
				     UNCACHE_WB_DRAIN = 'd15
				     } state_t;

   state_t n_state, r_state;


   logic 		n_flush_complete, r_flush_complete;
   logic 		r_flush_req, n_flush_req;
   logic [127:0] 	r_mem_req_store_data, n_mem_req_store_data;
   logic [63:0] 	r_cache_hits, n_cache_hits, r_cache_accesses, n_cache_accesses;

   logic		n_got_mem_rsp_valid,r_got_mem_rsp_valid;

   state_t r_rsp_state;
   assign state = r_state;
   assign rsp_state = r_rsp_state;
   
   always@(posedge clk)
     begin
	if(n_got_mem_rsp_valid & (r_got_mem_rsp_valid==1'b0))
	  begin
	     r_rsp_state <= r_state;
	  end
     end

   
   
   assign flush_complete = r_flush_complete;
   assign mem_req_addr = r_fp ? r_fp_addr : r_addr;
   assign mem_req_valid = r_mem_req;
   assign mem_req_opcode = r_fp ? 5'd4 : r_mem_opcode;
   /* An uncached op issues only from UNCACHE_LOAD/UNCACHE_STORE (MEM_WB reuses
    * UNCACHE_STORE for a cached writeback-through).  Everything else -- fills,
    * evictions, CACHE-op writebacks -- is cached traffic, and a cached fill can be
    * for a wrong-path load, so the SoC must not raise errors on it. */
   assign mem_req_uncached = (r_state == UNCACHE_LOAD) |
			     ((r_state == UNCACHE_STORE) & (r_opcode != MEM_WB));
   assign mem_req_store_data = r_mem_req_store_data;
   assign mem_req_mask = r_fp ? 16'hffff : r_store_mask;
   
   assign l1_mem_rsp_valid = r_rsp_valid;
   assign l1_mem_rsp_bad = r_rsp_bad;
   assign l1_mem_load_data = r_rsp_data;
   assign l1_mem_rsp_src = r_rsp_src;
   /* combinational: the arbiter moves to its next request the cycle after an accept */
   assign l1_mem_req_ack = n_req_ack;
   
   assign cache_hits = r_cache_hits;
   assign cache_accesses = r_cache_accesses;
   
     
   logic [127:0] 	t_d0;
      
   /* the line the state machine works on: the selected way's (see t_sel) */
   wire [127:0] 	w_d0;
   wire [TAG_BITS-1:0] 	w_tag;
   wire 		w_valid, w_dirty;

   
   /* L2_PIPE: the hit pipeline.  A cacheable LW or SW is accepted in IDLE (S0, the
    * read issues) without the state machine leaving IDLE, waits out the RAM read
    * (S1) and is looked up in S2.  A load hit that needs no probe and no L1I drop,
    * and an L1D writeback hit, finish there (one per cycle); anything else goes on
    * to the state machine through the handoff queue (r_ho*), which runs it as if
    * it had just been accepted.  Requests to one L2 set never overlap (sdsparc_nb.m
    * P1): S0 does not take a request to a set in S1, S2, the parked fill or the
    * deferred request.  The state machine leaves IDLE, or writes the RAMs in IDLE,
    * only once its writes can no longer meet a pipeline write.  A writeback is
    * answered in S2 whichever way it goes. */
`ifdef L2_PIPE
   localparam PIPE = 1'b1;
`else
   localparam PIPE = 1'b0;
`endif
   typedef struct packed {
      logic [`PA_WIDTH-1:0] 	addr;
      logic [5:0] 		opcode;
      logic 			from_d;
      logic [`L1D_N_COLOUR-1:0] colour;
      logic [2:0] 		src;
      logic [127:0] 		store_data;
   } l2_preq_t;
   logic 		r_s1_v, r_s2_v;
   l2_preq_t 		r_s1, r_s2, t_s0_req;
   logic 		t_s0_accept;
   l2_preq_t 		r_ho0, r_ho1, t_ho_req;
   logic [1:0] 		r_ho_n;
   logic 		t_ho_pop;
   logic 		t_p_fast, t_p_slow, t_p_rsp, t_p_park, t_ho_direct;
   logic 		t_p_wr_d0, t_p_wr_dirty, t_p_wr_pres, t_p_wr_ipres;
   logic [127:0] 	t_p_d0;
   wire [LG_L2_LINES-1:0] w_s2_set = r_s2.addr[LG_L2_LINES+3:4];
   wire 		w_p_wr = t_p_wr_d0 | t_p_wr_dirty | t_p_wr_pres | t_p_wr_ipres;
   /* the RAMs read at t_idx (in IDLE, the offered request's set: S0); a pipeline
    * write in S2 takes the write port, which the state machine is then not using */
   wire [LG_L2_LINES-1:0] t_wr_idx = w_p_wr ? w_s2_set : t_idx;

   /* L1D presence + colour per L2 line (inclusive-l2-v2 stage A).  pd = "the L1D may hold
    * this line", pidx = the L1D index colour it was filled at (the index bits above the
    * page offset).  The L1D is VA-indexed (stage C2b), so the colour comes with each
    * L1D request (mem_req_colour) and is not derivable from the PA.
    * Set on an L1D fill, cleared on an L1D writeback and on every L2 valid-bit write
    * (refill, drop, flush, init).  Conservative: a silent clean L1D eviction leaves pd set. */
   localparam L1D_IDX_STOP = `LG_L1D_CL_LEN + `LG_L1D_NUM_SETS;
   localparam N_PIDX = (L1D_IDX_STOP > `LG_PG_SZ) ? (L1D_IDX_STOP - `LG_PG_SZ) : 1;
   logic 		r_from_d, n_from_d;
   logic [`L1D_N_COLOUR-1:0] r_req_colour, n_req_colour;
   logic [N_PIDX:0] 	t_pres, w_pres;
   logic 		t_wr_pres;
   /* stage C2: the colour comes WITH the request (the L1D is VA-indexed, so it is no
    * longer a function of the PA) */
   wire [N_PIDX-1:0] 	w_req_pidx = r_req_colour;

   logic [N_PIDX:0] 	t_p_pres;

   /* L1I presence (pi, see w_l2_cacheable's comment above): set by an L1I fill,
    * cleared by the L1I drop that precedes anything else the line meets */
   logic 		t_ipres, w_ipres, t_wr_ipres;
   /* ---- L2_WAYS: one set of the RAMs above per way ----
    * Every way reads t_idx and writes t_wr_idx; the write enables are gated by
    * t_wr_way, so a write goes to the selected way only (INITIALIZE: to all).  The
    * state machine is unchanged: it sees one line (w_d0, w_tag, w_valid, w_dirty,
    * w_pres, w_ipres), the selected way's, picked by t_sel (one-hot, so any way count
    * works):
    *  - INITIALIZE writes every way at once;
    *  - the flush walk (FLUSH_*) visits every way of a set in turn (r_fway);
    *  - in IDLE, the parked fill (L2_HIT_UNDER_MISS) installs into r_fp_way, the
    *    victim its CHECK_VALID_AND_TAG picked (the RAM outputs in IDLE are another
    *    set's, so the victim cannot be picked there);
    *  - otherwise (a request, snoop, flush-by-address, walk read, block op: anything
    *    through CHECK_VALID_AND_TAG, which looks up r_tag) the way that hits, else
    *    the victim (t_vict).  Its first CHECK_VALID_AND_TAG cycle latches the choice
    *    (r_way) and holds it while it stays there (probes, L1I drops) and through a
    *    miss's DIRTY_STORE .. CLEAN_RELOAD: the fill must land in the way whose line
    *    was written back, and the replacement state (updated as the miss leaves
    *    CHECK) would by then name another victim.  A miss that is not a fill (an
    *    INVL, a snoop, ..) changes nothing, so its "victim" only names the line the
    *    L1I-drop/probe arms already treat as the resident one.
    * The victim feeds only the miss side of the select: a hit's way is its tag match. */
   logic [127:0] 	w_d0_w[L2_WAYS-1:0];
   logic [TAG_BITS-1:0] w_tag_w[L2_WAYS-1:0];
   logic [N_PIDX:0] 	w_pres_w[L2_WAYS-1:0];
   logic [L2_WAYS-1:0] 	w_valid_w, w_dirty_w, w_ipres_w;
   logic [L2_WAYS-1:0] 	t_sel, t_wr_way, t_hitv, t_vict, t_fsel;
   logic [L2_WAYS-1:0] 	r_way, r_fp_way, t_pick;
   /* L2_SEL_STAGE (machine.vh): the lookup's pick (t_pick: the hit way, else the
    * victim) and its hit go into r_way / r_hit on the first CHECK_VALID_AND_TAG
    * cycle, which does nothing else; from the next cycle only those flops drive the
    * way muxes, the write enables and w_hit, so the N-way tag compare and the
    * 128-bit way mux sit in different cycles.  Every lookup reaches CHECK through
    * WAIT_FOR_RAM and holds t_idx (= r_idx) there, so the RAM outputs stay put over
    * the extra cycle.  The other selects (INITIALIZE, the flush walk's r_fway, the
    * parked fill's r_fp_way in IDLE) are already flops: no compare in front. */
`ifdef L2_SEL_STAGE
   localparam SEL = 1'b1;
`else
   localparam SEL = 1'b0;
`endif
   logic 		r_hit;
   logic 		r_way_lock, n_way_lock;
   logic [LG_WAYS-1:0] 	r_fway, n_fway;
   logic [127:0] 	t_way_d0;
   logic [TAG_BITS-1:0] t_way_tag;
   logic [N_PIDX:0] 	t_way_pres;
   logic 		t_way_valid, t_way_dirty, t_way_ipres;
   genvar 		g;
   generate
      for(g = 0; g < L2_WAYS; g = g + 1)
	begin : g_way
	   reg_ram1r1w #(.WIDTH(128), .LG_DEPTH(LG_L2_LINES)) data_ram0
	     (.clk(clk),
	      .rd_addr(t_idx),
	      .wr_addr(t_wr_idx),
	      .wr_data(t_p_wr_d0 ? t_p_d0 : t_d0),
	      .wr_en((t_wr_d0 | t_p_wr_d0) & t_wr_way[g]),
	      .rd_data(w_d0_w[g]));
	   reg_ram1r1w #(.WIDTH(TAG_BITS), .LG_DEPTH(LG_L2_LINES)) tag_ram
	     (.clk(clk),
	      .rd_addr(t_idx),
	      .wr_addr(t_wr_idx),
	      .wr_data(t_wtag),
	      .wr_en(t_wr_tag & t_wr_way[g]),
	      .rd_data(w_tag_w[g]));
	   reg_ram1r1w #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) valid_ram
	     (.clk(clk),
	      .rd_addr(t_idx),
	      .wr_addr(t_wr_idx),
	      .wr_data(t_valid),
	      .wr_en(t_wr_valid & t_wr_way[g]),
	      .rd_data(w_valid_w[g]));
	   reg_ram1r1w #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) dirty_ram
	     (.clk(clk),
	      .rd_addr(t_idx),
	      .wr_addr(t_wr_idx),
	      .wr_data(t_p_wr_dirty ? 1'b1 : t_dirty),
	      .wr_en((t_wr_dirty | t_p_wr_dirty) & t_wr_way[g]),
	      .rd_data(w_dirty_w[g]));
	   reg_ram1r1w #(.WIDTH(N_PIDX+1), .LG_DEPTH(LG_L2_LINES)) pres_ram
	     (.clk(clk),
	      .rd_addr(t_idx),
	      .wr_addr(t_wr_idx),
	      .wr_data(t_p_wr_pres ? t_p_pres : t_pres),
	      .wr_en((t_wr_pres | t_p_wr_pres) & t_wr_way[g]),
	      .rd_data(w_pres_w[g]));
	   reg_ram1r1w #(.WIDTH(1), .LG_DEPTH(LG_L2_LINES)) ipres_ram
	     (.clk(clk),
	      .rd_addr(t_idx),
	      .wr_addr(t_wr_idx),
	      .wr_data(t_p_wr_ipres ? 1'b1 : t_ipres),
	      .wr_en((t_wr_ipres | t_p_wr_ipres) & t_wr_way[g]),
	      .rd_data(w_ipres_w[g]));
	end // block: g_way
      /* L2_PIPE's S2 lookup reads w_* in IDLE as the one line of its set */
      if(PIPE && (L2_WAYS > 1))
	begin : g_pipe_needs_one_way
	   $error("L2_PIPE requires L2_WAYS == 1");
	end
      /* nor the registered select: S2 compares and muxes in one cycle */
      if(PIPE && SEL)
	begin : g_pipe_no_sel_stage
	   $error("L2_PIPE excludes L2_SEL_STAGE");
	end
`ifdef ENABLE_R10000
      /* the block op's index form names a line by set + address bit 0, not by way */
      if(L2_WAYS > 1)
	begin : g_blk_idx_needs_one_way
	   $error("ENABLE_R10000 (MEM_BLK_IDX) requires L2_WAYS == 1");
	end
`endif
   endgenerate

   /* replacement state, one word per set beside the tags (read at t_idx with them);
    * handled 2 bits per way whatever the policy (NRU uses the low L2_WAYS) */
   localparam REPL_W2 = 2 * L2_WAYS;
   logic [REPL_W2-1:0] 	w_repl, t_repl_hit, t_repl_fill, t_repl_wdata;
   logic 		t_repl_upd, t_repl_ins, t_wr_repl;
   generate
      if((L2_WAYS > 1) && (REPL != `L2_REPL_RAND))
	begin : g_repl
	   logic [REPL_W-1:0] w_rd;
	   reg_ram1r1w #(.WIDTH(REPL_W), .LG_DEPTH(LG_L2_LINES)) repl_ram
	     (.clk(clk),
	      .rd_addr(t_idx),
	      .wr_addr(t_wr_idx),
	      .wr_data(t_repl_wdata[REPL_W-1:0]),
	      .wr_en(t_wr_repl),
	      .rd_data(w_rd));
	   assign w_repl = REPL_W2'(w_rd);
	end
      else
	begin : g_no_repl
	   assign w_repl = '0;
	end
   endgenerate

   /* RAND: a free-running 16-bit LFSR (x^16+x^14+x^13+x^11+1), scaled to
    * [0, L2_WAYS) by a multiply-high -- for a way count that is not a power of
    * two the bias is at most L2_WAYS/65535 */
   logic [15:0] 	r_lfsr;
   logic [31:0] 	t_rnd;
   /* BRRIP's 1-in-32 insertion at RRPV 2, and DRRIP's PSEL (high: BRRIP's leader
    * sets miss less, so the followers insert as BRRIP) */
   logic [4:0] 		r_bip_cnt;
   logic [9:0] 		r_psel;
   localparam LDR = (LG_L2_LINES >= 10) ? 5 : (LG_L2_LINES / 2);
   logic 		t_ldr_sr, t_ldr_br, t_vfound, t_anyinv;
   logic [1:0] 		t_rmax, t_rrpv, t_bip, t_ins;
   always_comb
     begin
	t_hitv = '0;
	t_fsel = '0;
	for(integer i = 0; i < L2_WAYS; i = i + 1)
	  begin
	     t_hitv[i] = w_valid_w[i] && (w_tag_w[i] == r_tag);
	     t_fsel[i] = (int'(r_fway) == i);
	  end

	/* the victim: the first invalid way, else the policy's choice */
	t_rnd = 32'(r_lfsr) * L2_WAYS;
	t_rmax = 2'd0;
	for(integer i = 0; i < L2_WAYS; i = i + 1)
	  begin
	     t_rrpv = w_repl[2*i +: 2];
	     if(RRIP && (t_rrpv > t_rmax))
	       begin
		  t_rmax = t_rrpv;
	       end
	  end
	t_vict = '0;
	t_vfound = 1'b0;
	for(integer i = 0; i < L2_WAYS; i = i + 1)
	  begin
	     if(!t_vfound && !w_valid_w[i])
	       begin
		  t_vict[i] = 1'b1;
		  t_vfound = 1'b1;
	       end
	  end
	t_anyinv = t_vfound;
	for(integer i = 0; i < L2_WAYS; i = i + 1)
	  begin
	     /* RRIP: the first way at the highest RRPV is the first at 3 once the set
	      * is aged by (3 - max), which the fill below writes back */
	     if(!t_vfound && (RRIP ? (w_repl[2*i +: 2] == t_rmax) :
			      (REPL == `L2_REPL_RAND) ? (int'(t_rnd[31:16]) == i) :
			      !w_repl[i]))
	       begin
		  t_vict[i] = 1'b1;
		  t_vfound = 1'b1;
	       end
	  end
	if(!t_vfound)
	  begin
	     t_vict[0] = 1'b1;   /* unreachable: NRU always leaves a bit clear */
	  end

	t_pick = (t_hitv != '0) ? t_hitv : t_vict;
	if(L2_WAYS == 1)
	  begin
	     t_sel = '1;
	  end
	else if(r_state == IDLE)
	  begin
	     t_sel = r_fp_way;
	  end
	else if((r_state == FLUSH_WAIT) || (r_state == FLUSH_TRIAGE) || (r_state == FLUSH_STORE))
	  begin
	     t_sel = t_fsel;
	  end
	else if(r_way_lock || SEL)
	  begin
	     /* L2_SEL_STAGE: only the registered pick reaches the muxes */
	     t_sel = r_way;
	  end
	else
	  begin
	     t_sel = t_pick;
	  end
	t_wr_way = (r_state == INITIALIZE) ? '1 : t_sel;

	t_way_d0 = '0;
	t_way_tag = '0;
	t_way_pres = '0;
	t_way_valid = 1'b0;
	t_way_dirty = 1'b0;
	t_way_ipres = 1'b0;
	for(integer i = 0; i < L2_WAYS; i = i + 1)
	  begin
	     if(t_sel[i])
	       begin
		  t_way_d0 = t_way_d0 | w_d0_w[i];
		  t_way_tag = t_way_tag | w_tag_w[i];
		  t_way_pres = t_way_pres | w_pres_w[i];
		  t_way_valid = t_way_valid | w_valid_w[i];
		  t_way_dirty = t_way_dirty | w_dirty_w[i];
		  t_way_ipres = t_way_ipres | w_ipres_w[i];
	       end
	  end

	/* the replacement state after a hit in, or a fill of, way t_sel.  NRU: set
	 * its bit, clearing the others once all are set.  RRIP: a hit goes to 0; a
	 * fill goes in at t_ins, and when the set had no invalid way the others age
	 * by (3 - max), so the victim was the first at 3 (Jaleel et al.) */
	t_bip = (r_bip_cnt == 5'd0) ? 2'd2 : 2'd3;
	t_ldr_sr = (r_idx[LG_L2_LINES-1:LG_L2_LINES-LDR] == r_idx[LDR-1:0]);
	t_ldr_br = (r_idx[LG_L2_LINES-1:LG_L2_LINES-LDR] == ~r_idx[LDR-1:0]);
	t_ins = (REPL == `L2_REPL_SRRIP) ? 2'd2 :
		(REPL == `L2_REPL_BRRIP) ? t_bip :
		t_ldr_sr ? 2'd2 :
		t_ldr_br ? t_bip :
		r_psel[9] ? t_bip :
		2'd2;
	t_repl_hit = w_repl | REPL_W2'(t_sel);
	if(t_repl_hit[L2_WAYS-1:0] == '1)
	  begin
	     t_repl_hit = REPL_W2'(t_sel);
	  end
	t_repl_fill = t_repl_hit;
	if(RRIP)
	  begin
	     for(integer i = 0; i < L2_WAYS; i = i + 1)
	       begin
		  t_rrpv = w_repl[2*i +: 2];
		  t_repl_hit[2*i +: 2] = t_sel[i] ? 2'd0 : t_rrpv;
		  t_repl_fill[2*i +: 2] = t_sel[i] ? t_ins : (t_anyinv ? t_rrpv : (t_rrpv + (2'd3 - t_rmax)));
	       end
	  end
     end // always_comb
   /* apart from the select above: the state machine's t_repl_* depend on t_sel */
   always_comb
     begin
	/* INITIALIZE: NRU bits clear, RRPVs at 3 (all ways invalid anyway) */
	t_wr_repl = t_repl_upd | t_repl_ins | (r_state == INITIALIZE);
	t_repl_wdata = (r_state == INITIALIZE) ? (RRIP ? '1 : '0) : (t_repl_ins ? t_repl_fill : t_repl_hit);
     end // always_comb
   assign w_d0 = t_way_d0;
   assign w_tag = t_way_tag;
   assign w_valid = t_way_valid;
   assign w_dirty = t_way_dirty;
   assign w_pres = t_way_pres;
   assign w_ipres = t_way_ipres;

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_way <= 'd0;
	     r_hit <= 1'b0;
	     r_way_lock <= 1'b0;
	     r_fway <= 'd0;
	     r_fp_way <= 'd0;
	     r_lfsr <= 16'hace1;
	     r_bip_cnt <= 5'd0;
	     r_psel <= 10'd511;
	  end
	else
	  begin
	     r_way <= r_way_lock ? r_way : t_pick;
	     r_hit <= r_way_lock ? r_hit : (t_hitv != '0);
	     r_way_lock <= n_way_lock;
	     r_fway <= n_fway;
	     if(t_fp_save | t_p_park)
	       begin
		  r_fp_way <= t_sel;
	       end
	     r_lfsr <= {r_lfsr[14:0], r_lfsr[15] ^ r_lfsr[13] ^ r_lfsr[12] ^ r_lfsr[10]};
	     if(t_repl_ins)
	       begin
		  r_bip_cnt <= r_bip_cnt + 5'd1;
		  if((REPL == `L2_REPL_DRRIP) && t_ldr_sr && (r_psel != 10'd1023))
		    begin
		       r_psel <= r_psel + 10'd1;
		    end
		  else if((REPL == `L2_REPL_DRRIP) && t_ldr_br && (r_psel != 10'd0))
		    begin
		       r_psel <= r_psel - 10'd1;
		    end
	       end
	  end
     end // always_ff@ (posedge clk)
`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
	if(!reset && (r_state == CHECK_VALID_AND_TAG) && !$onehot0(t_hitv))
	  begin
	     $display("L2: a line in two ways of set %x (hits %b)", r_idx, t_hitv);
	     $stop();
	  end
     end
   /* sim-only mirror of every way's valid, tag and presence RAMs for the PRESCHK
    * inclusion checker (core_l1d_l1i.sv), which cannot index g_way[] by a variable.
    * It takes the RAM's write a cycle late, as reg_ram1r1w does, so it equals r_ram. */
   logic [L2_WAYS-1:0] 	r_dbg_wv, r_dbg_wt, r_dbg_wp;
   logic [LG_L2_LINES-1:0] r_dbg_widx;
   logic 		r_dbg_v;
   logic [TAG_BITS-1:0] r_dbg_t;
   logic [N_PIDX:0] 	r_dbg_p;
   bit 			dbg_valid [L2_WAYS][1 << LG_L2_LINES];
   logic [TAG_BITS-1:0] dbg_tag [L2_WAYS][1 << LG_L2_LINES];
   logic [N_PIDX:0] 	dbg_pres [L2_WAYS][1 << LG_L2_LINES];
   always_ff@(posedge clk)
     begin
	r_dbg_wv <= {L2_WAYS{t_wr_valid}} & t_wr_way;
	r_dbg_wt <= {L2_WAYS{t_wr_tag}} & t_wr_way;
	r_dbg_wp <= {L2_WAYS{t_wr_pres | t_p_wr_pres}} & t_wr_way;
	r_dbg_widx <= t_wr_idx;
	r_dbg_v <= t_valid;
	r_dbg_t <= t_wtag;
	r_dbg_p <= t_p_wr_pres ? t_p_pres : t_pres;
	for(integer i = 0; i < L2_WAYS; i = i + 1)
	  begin
	     if(r_dbg_wv[i])
	       begin
		  dbg_valid[i][r_dbg_widx] <= r_dbg_v;
	       end
	     if(r_dbg_wt[i])
	       begin
		  dbg_tag[i][r_dbg_widx] <= r_dbg_t;
	       end
	     if(r_dbg_wp[i])
	       begin
		  dbg_pres[i][r_dbg_widx] <= r_dbg_p;
	       end
	  end
     end // always_ff@ (posedge clk)
`endif

`ifdef VERILATOR
   /* sim-only per-index history, read by the PRESCHK inclusion checker: the last
    * valid/tag write and the last presence write of each L2 index */
   int unsigned dbg_v_cyc [1 << LG_L2_LINES];
   int 	        dbg_v_state [1 << LG_L2_LINES];
   int 	        dbg_v_op [1 << LG_L2_LINES];
   bit 	        dbg_v_oldval [1 << LG_L2_LINES];
   longint unsigned dbg_v_oldtag [1 << LG_L2_LINES];
   bit 	        dbg_v_newval [1 << LG_L2_LINES];
   longint unsigned dbg_v_newtag [1 << LG_L2_LINES];
   int 	        dbg_v_pres [1 << LG_L2_LINES];
   bit 	        dbg_v_probed [1 << LG_L2_LINES];
   bit 	        dbg_v_unc [1 << LG_L2_LINES];
   int unsigned dbg_p_cyc [1 << LG_L2_LINES];
   int 	        dbg_p_op [1 << LG_L2_LINES];
   int 	        dbg_p_val [1 << LG_L2_LINES];
`endif
   wire 		w_hit = SEL ? r_hit : (w_valid ? (r_tag == w_tag) : 1'b0);
   /* a table walk read (source 2, mmu.sv): an ordinary cached read, except that the
    * walker keeps no copy -- any L1D copy is probed out first (it may be dirty, and
    * the read may update the line), the L1I copy is dropped, and no presence bit is
    * set.  r_store_data holds the PTE bits to set, in the entry's bus word. */
   wire 		w_mmu_rd = (r_src == 3'd2) && !r_is_uncache && (r_opcode == 6'd4);
   /* drop the resident line from the L1I first (pi): for anything but an L1I fill
    * that hits it (which keeps it) and a block op (which clears the whole block in
    * the L1I itself); without ENABLE_COHERENT_L1I an L1D fill may share it too */
   wire 		w_idrop_need = w_ipres && !r_idropped && !is_blkop(r_opcode) &&
			       !(!r_from_d && !r_is_uncache && w_hit && (r_opcode == 6'd4))
`ifndef ENABLE_COHERENT_L1I
			       && !(r_from_d && !w_mmu_rd && !r_is_uncache && w_hit && (r_opcode == 6'd4))
`endif
			       ;
   /* stage C2 alias (push, the R10000 PIdx scheme): an L1D request for a line the L1D
    * holds at a DIFFERENT colour -- probe that copy out first (it comes back if dirty).
    * Only for ops whose line the L1D did not supply itself: a fill (LW), an invalidate
    * (INVL) and a page drop (PGDROP); WB/SW carry the L1D's own copy (colour == pidx).
    * C2_NO_ALIAS_PROBE (sim only) is the negative control: synonyms then duplicate. */
`ifdef C2_NO_ALIAS_PROBE
   wire w_alias = 1'b0;
`else
   wire w_alias = r_from_d && !r_is_uncache && w_hit && w_pres[N_PIDX] &&
		  (w_mmu_rd || (w_pres[N_PIDX-1:0] != w_req_pidx)) &&
		  ((r_opcode == 6'd4) || (r_opcode == MEM_INVL) || (r_opcode == MEM_PGDROP));
`endif
   /* an L1I fill of a line the L1D may hold (pd): probe it out of the L1D first,
    * so a dirty copy -- an instruction the kernel just patched (SPARC flush) --
    * is what the L1I gets.  (r9999's IRIX wrote the D-cache back in software.) */
   wire w_ifill_pd = !r_from_d && !r_is_uncache && w_hit && w_pres[N_PIDX] && (r_opcode == 6'd4);
   wire 		w_need_wb = w_valid ? w_dirty : 1'b0;
   /* a walk read's R/M update: OR the requested bits into the entry's bus word
    * (the big-endian entry byte-swapped, so ET = bits 25:24) if it is a PTE */
   function automatic logic [31:0] pte_set(input logic [31:0] w, input logic [31:0] b);
      begin
	 pte_set = ((b != 32'd0) && (w[25:24] == 2'd2)) ? (w | b) : w;
      end
   endfunction
   wire [127:0] 	w_mmu_old = r_probe_dirty ? r_probe_data : w_d0;
   wire [127:0] 	w_mmu_new = {pte_set(w_mmu_old[127:96], r_store_data[127:96]),
				     pte_set(w_mmu_old[95:64], r_store_data[95:64]),
				     pte_set(w_mmu_old[63:32], r_store_data[63:32]),
				     pte_set(w_mmu_old[31:0], r_store_data[31:0])};
   /* the block op's current line; the index form takes whatever line sits at the set */
   wire [`PA_WIDTH-1:0] w_blk_line = {r_blk_addr, r_blk_cnt[2:0], 4'd0};
   wire 		w_blk_hit = (r_opcode == MEM_BLK_IDX) ? w_valid : w_hit;

   /* L2_HIT_UNDER_MISS: one clean reload (an L1 LW or SW miss) may PARK.  CHECK_VALID_AND_TAG
    * issues its DRAM read from r_fp_* (which drive the DRAM port until the response) and
    * returns to IDLE, where the L2 keeps serving other requesters' LW/SW to OTHER sets
    * (one transaction per L2 set: formal/murphi/sdsparc_nb.m P1).  One DRAM transaction at
    * a time: a request that misses meanwhile is DEFERRED (r_def_*) on its first CHECK
    * visit, before it probes or changes anything, and replayed once the fill is done;
    * flushes, snoops, retries, block ops, uncached and CACHE ops wait in IDLE.  The fill
    * installs from IDLE (r_fp_data) and re-enters CHECK through WAIT_CLEAN_RELOAD, exactly
    * as a CLEAN_RELOAD would, answering its requester (r_fp_src) through the hit arm. */
`ifdef L2_HIT_UNDER_MISS
   localparam HUM = 1'b1;
`else
   localparam HUM = 1'b0;
`endif
   logic [2:0] r_src, n_src, r_rsp_src;
   logic [`PA_WIDTH-(LG_L2_LINES+4)-1:0] t_wtag;
   logic       t_fp_save, t_fp_restore, t_def_save, t_def_restore;
   logic       r_fp, r_fp_done, r_def;
   logic [127:0] r_fp_data;
   logic [`PA_WIDTH-1:0] r_fp_addr, r_def_addr;
   logic [5:0] 		 r_fp_opcode, r_def_opcode;
   logic 		 r_fp_from_d, r_def_from_d, r_fp_probed, r_fp_idropped;
   logic [`L1D_N_COLOUR-1:0] r_fp_colour, r_def_colour;
   logic [127:0] 	     r_fp_store_data, r_def_store_data;
   logic [2:0] 		     r_fp_src, r_def_src;
   wire [LG_L2_LINES-1:0]    w_fp_set = r_fp_addr[LG_L2_LINES+3:4];
   wire [LG_L2_LINES-1:0]    w_def_set = r_def_addr[LG_L2_LINES+3:4];
   always_ff@(posedge clk)
     begin
	r_src <= reset ? 3'd0 : n_src;
	r_rsp_src <= reset ? 3'd0 : (t_p_rsp ? r_s2.src : (n_rsp_valid ? n_src : r_rsp_src));
	r_fp <= reset ? 1'b0 : ((t_fp_save | t_p_park) ? 1'b1 : (t_fp_restore ? 1'b0 : r_fp));
	r_fp_done <= reset ? 1'b0 : ((t_fp_save | t_p_park) ? 1'b0 : ((r_fp & mem_rsp_valid) ? 1'b1 : r_fp_done));
	r_def <= reset ? 1'b0 : (t_def_save ? 1'b1 : (t_def_restore ? 1'b0 : r_def));
	if(r_fp & mem_rsp_valid)
	  begin
	     r_fp_data <= mem_rsp_load_data;
	  end
	if(t_fp_save)
	  begin
	     r_fp_addr <= r_addr;
	     r_fp_opcode <= r_opcode;
	     r_fp_from_d <= r_from_d;
	     r_fp_colour <= r_req_colour;
	     r_fp_probed <= r_probed;
	     r_fp_idropped <= r_idropped;
	     r_fp_store_data <= r_store_data;
	     r_fp_src <= r_src;
	  end
	else if(t_p_park)
	  begin
	     /* L2_PIPE: a clean miss parks straight from S2 */
	     r_fp_addr <= r_s2.addr;
	     r_fp_opcode <= r_s2.opcode;
	     r_fp_from_d <= r_s2.from_d;
	     r_fp_colour <= r_s2.colour;
	     r_fp_probed <= 1'b0;
	     r_fp_idropped <= 1'b0;
	     r_fp_store_data <= r_s2.store_data;
	     r_fp_src <= r_s2.src;
	  end
	if(t_def_save)
	  begin
	     r_def_addr <= r_addr;
	     r_def_opcode <= r_opcode;
	     r_def_from_d <= r_from_d;
	     r_def_colour <= r_req_colour;
	     r_def_store_data <= r_store_data;
	     r_def_src <= r_src;
	  end
     end // always_ff@ (posedge clk)
`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
	if(!reset && r_fp && mem_rsp_valid && r_fp_done)
	  begin
	     $display("L2: second DRAM response while a parked fill is complete");
	     $stop();
	  end
	if(!reset && t_def_save && r_def)
	  begin
	     $display("L2: second deferred request");
	     $stop();
	  end
     end // always_ff@ (negedge clk)
   /* how often a fill parks, a request is taken under it, and one is deferred */
   longint unsigned c_hum_park, c_hum_take, c_hum_def;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     c_hum_park <= 0;
	     c_hum_take <= 0;
	     c_hum_def <= 0;
	  end
	else
	  begin
	     c_hum_park <= c_hum_park + ((t_fp_save | t_p_park) ? 1 : 0);
	     c_hum_take <= c_hum_take + ((r_state == IDLE) && (r_fp || r_def) && n_req_ack ? 1 : 0);
	     c_hum_def <= c_hum_def + (t_def_save ? 1 : 0);
	  end
     end
   final
     begin
	if(HUM)
	  begin
	     $display("[L2HUM] parked %0d taken-under-miss %0d deferred %0d", c_hum_park, c_hum_take, c_hum_def);
	  end
     end
`endif

   /* ---- L2_PIPE (see the RAMs above) ---- */
   wire [LG_L2_LINES-1:0] w_s0_set = l1_mem_req_addr[LG_L2_LINES+3:4];
   wire 		  w_s0_fast = PIPE && w_l2_cacheable &&
			  ((l1_mem_req_opcode == 6'd4) || (l1_mem_req_opcode == 6'd7));
   wire 		  w_pipe_empty = !r_s1_v && !r_s2_v;
   /* S0 may take the offered request: nothing waits for the state machine, and no
    * request in flight is to its set */
   wire 		  w_s0_ok = l1_mem_req_valid && w_s0_fast && (r_ho_n == 2'd0) && !t_p_slow &&
			  !(r_s1_v && (r_s1.addr[LG_L2_LINES+3:4] == w_s0_set)) &&
			  !(r_s2_v && (w_s2_set == w_s0_set)) &&
			  !(r_fp && ((w_fp_set == w_s0_set) || (l1_mem_req_src == r_fp_src))) &&
			  !(r_def && (w_def_set == w_s0_set));
   always_comb
     begin
	t_s0_req.addr = {l1_mem_req_addr[`PA_WIDTH-1:4], 4'd0};
	t_s0_req.opcode = l1_mem_req_opcode;
	t_s0_req.from_d = l1_mem_req_from_d;
	t_s0_req.colour = l1_mem_req_colour;
	t_s0_req.src = l1_mem_req_src;
	t_s0_req.store_data = l1_mem_req_store_data;
     end

   /* S2: the lookup, with the conditions the state machine's CHECK_VALID_AND_TAG
    * applies, restricted to the cases that finish in its plain hit arm */
   wire [TAG_BITS-1:0] 	  w_s2_tag = r_s2.addr[`PA_WIDTH-1:LG_L2_LINES+4];
   wire [N_PIDX-1:0] 	  w_s2_pidx = r_s2.colour;
   wire 		  w_s2_lw = (r_s2.opcode == 6'd4);
   wire 		  w_s2_sw = (r_s2.opcode == 6'd7);
   wire 		  w_s2_mmu = (r_s2.src == 3'd2) && w_s2_lw;
   wire 		  w_s2_hit = r_s2_v && w_valid && (w_tag == w_s2_tag);
   /* the L1I copy must go first (w_idrop_need) */
   wire 		  w_s2_idrop = w_ipres && !(!r_s2.from_d && w_s2_lw)
`ifndef ENABLE_COHERENT_L1I
			  && !(r_s2.from_d && !w_s2_mmu && w_s2_lw)
`endif
			  ;
   /* an L1D copy must be probed out first: another colour (w_alias), any colour for
    * a walk read, or an L1I fill (w_ifill_pd) */
`ifdef C2_NO_ALIAS_PROBE
   wire 		  w_s2_probe = w_pres[N_PIDX] && !r_s2.from_d;
`else
   wire 		  w_s2_probe = w_pres[N_PIDX] &&
			  (w_s2_mmu || !r_s2.from_d || (w_pres[N_PIDX-1:0] != w_s2_pidx));
`endif
   wire [127:0] 	  w_s2_mmu_new = {pte_set(w_d0[127:96], r_s2.store_data[127:96]),
					  pte_set(w_d0[95:64], r_s2.store_data[95:64]),
					  pte_set(w_d0[63:32], r_s2.store_data[63:32]),
					  pte_set(w_d0[31:0], r_s2.store_data[31:0])};
   always_comb
     begin
	t_p_fast = w_s2_hit && ((w_s2_lw && !w_s2_idrop && !w_s2_probe) || (w_s2_sw && !w_ipres));
	/* a miss whose victim needs nothing (invalid, or clean in neither L1) parks its
	 * fill from here, as CHECK_VALID_AND_TAG's clean-reload arm would, when no
	 * fill is out and the DRAM port is free: its DRAM read issues as early as
	 * through the state machine */
	t_p_park = HUM && r_s2_v && !w_s2_hit && !r_fp && !r_mem_req &&
		   (!w_valid || (!w_dirty && !w_pres[N_PIDX] && !w_ipres));
	t_p_slow = r_s2_v && !t_p_fast && !t_p_park;
	t_p_rsp = r_s2_v && (w_s2_sw || t_p_fast);
	/* an L1D fill records where the L1D holds the line; an L1D writeback gave it up */
	t_p_wr_pres = t_p_fast && r_s2.from_d && !w_s2_mmu;
	t_p_pres = w_s2_sw ? '0 : {1'b1, w_s2_pidx};
	t_p_wr_ipres = t_p_fast && w_s2_lw && !r_s2.from_d;
	/* a writeback's data, or a walk read's R/M update */
	t_p_d0 = w_s2_sw ? r_s2.store_data : w_s2_mmu_new;
	t_p_wr_d0 = t_p_fast && (w_s2_sw || (w_s2_mmu && (w_s2_mmu_new != w_d0)));
	t_p_wr_dirty = t_p_wr_d0;
     end // always_comb

   always_ff@(posedge clk)
     begin
	r_s1_v <= reset ? 1'b0 : t_s0_accept;
	r_s2_v <= reset ? 1'b0 : r_s1_v;
	if(t_s0_accept)
	  begin
	     r_s1 <= t_s0_req;
	  end
	r_s2 <= r_s1;
	r_ho_n <= reset ? 2'd0 : (r_ho_n + ((t_p_slow & !t_ho_direct) ? 2'd1 : 2'd0) - (t_ho_pop ? 2'd1 : 2'd0));
	if(t_ho_pop)
	  begin
	     r_ho0 <= (r_ho_n == 2'd1) ? r_s2 : r_ho1;
	     r_ho1 <= r_s2;
	  end
	else if(t_p_slow & !t_ho_direct)
	  begin
	     if(r_ho_n == 2'd0)
	       begin
		  r_ho0 <= r_s2;
	       end
	     else
	       begin
		  r_ho1 <= r_s2;
	       end
	  end
     end // always_ff@ (posedge clk)
`ifdef VERILATOR
   always_ff@(negedge clk)
     begin
	if(!reset && w_p_wr && (t_wr_d0 | t_wr_tag | t_wr_valid | t_wr_dirty | t_wr_pres | t_wr_ipres))
	  begin
	     $display("L2: pipeline and state machine write the RAMs in one cycle");
	     $stop();
	  end
	if(!reset && t_p_rsp && n_rsp_valid)
	  begin
	     $display("L2: pipeline and state machine answer in one cycle");
	     $stop();
	  end
	if(!reset && t_p_slow && !t_ho_direct && !t_ho_pop && (r_ho_n == 2'd2))
	  begin
	     $display("L2: handoff queue overflow");
	     $stop();
	  end
	if(!reset && t_s0_accept && (r_state != IDLE))
	  begin
	     $display("L2: pipeline accept outside IDLE");
	     $stop();
	  end
     end // always_ff@ (negedge clk)
   longint unsigned c_p_acc, c_p_fast, c_p_slow, c_p_park;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     c_p_acc <= 0;
	     c_p_fast <= 0;
	     c_p_slow <= 0;
	     c_p_park <= 0;
	  end
	else
	  begin
	     c_p_acc <= c_p_acc + (t_s0_accept ? 1 : 0);
	     c_p_fast <= c_p_fast + (t_p_fast ? 1 : 0);
	     c_p_slow <= c_p_slow + (t_p_slow ? 1 : 0);
	     c_p_park <= c_p_park + (t_p_park ? 1 : 0);
	  end
     end
   final
     begin
	if(PIPE)
	  begin
	     $display("[L2PIPE] accepted %0d finished in S2 %0d parked from S2 %0d handed off %0d", c_p_acc, c_p_fast, c_p_park, c_p_slow);
	  end
     end
`endif

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= INITIALIZE;
	     r_flush_state <= WAIT_FOR_FLUSH;
	     r_flush_complete <= 1'b0;
	     r_idx <= 'd0;
	     r_tag <= 'd0;
	     r_opcode <= 6'd0;
	     r_from_d <= 1'b0;
	     r_req_colour <= 'd0;
	     r_addr <= 'd0;
	     r_saveaddr <= 'd0;
	     r_mem_req <= 1'b0;
	     r_mem_opcode <= 5'd0;
	     r_rsp_data <= 'd0;
	     r_rsp_valid <= 1'b0;
	     r_rsp_bad <= 1'b0;
	     r_reload <= 1'b0;
	     r_req_ack <= 1'b0;
	     r_snoop_ack <= 1'b0;
	     r_snp_wbinv <= 1'b0;
	     r_snoop_done <= 1'b0;
	     r_rty_pend <= 1'b0;
	     r_rty_addr <= 'd0;
	     r_rty_mem_op <= 5'd0;
	     r_rty_mask <= 16'd0;
	     r_rty_data <= 128'd0;
	     r_rty_opcode <= 6'd0;
	     r_rty_from_d <= 1'b0;
	     r_blk_pend <= 1'b0;
	     r_blk_cnt <= 'd0;
	     r_blk_addr <= 'd0;
	     r_blk_op <= 6'd0;
	     r_blk_way <= 1'b0;
	     r_blk_l1i_req <= 1'b0;
	     r_blk_l1i_done <= 1'b0;
	     r_idrop_wait <= 1'b0;
	     r_idropped <= 1'b0;
	     r_ci_lsel <= 3'd0;
	     r_inv_line <= 1'b0;
`ifdef VERILATOR
	     r_snoop_hit <= 64'd0;
	     r_snoop_dirty <= 64'd0;
	     r_pd_drop_n <= 64'd0;
`endif
	     r_store_data <= 'd0;
	     r_store_mask <= 'd0;	     
	     r_is_uncache <= 1'b0;
	     r_uncache_mask <= 'd0;
	     r_flush_req <= 1'b0;
	     r_need_l1d <= 1'b0;
	     r_need_l1i <= 1'b0;
	     r_had_l1d <= 1'b0;
	     r_flush_skip <= 1'b0;
	     r_got_mem_rsp_valid <= 1'b0;
	     r_cache_hits <= 'd0;
	     r_cache_accesses <= 'd0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_flush_state <= n_flush_state;
	     r_flush_complete <= n_flush_complete;
	     r_idx <= t_idx;
	     r_tag <= n_tag;
	     r_opcode <= n_opcode;
	     r_from_d <= n_from_d;
	     r_req_colour <= n_req_colour;
	     r_addr <= n_addr;
	     r_saveaddr <= n_saveaddr;
	     r_mem_req <= n_mem_req;
	     r_mem_opcode <= n_mem_opcode;
	     r_rsp_data <= t_p_rsp ? w_d0 : n_rsp_data;
	     r_rsp_valid <= n_rsp_valid | t_p_rsp;
	     r_rsp_bad <= t_p_rsp ? 1'b0 : n_rsp_bad;
	     r_reload <= n_reload;
	     r_req_ack <= n_req_ack;
	     r_snoop_ack <= n_snoop_ack;
	     r_snp_wbinv <= n_snp_wbinv;
	     r_snoop_done <= n_snoop_done;
	     r_rty_pend <= n_rty_pend;
	     r_rty_addr <= n_rty_addr;
	     r_rty_mem_op <= n_rty_mem_op;
	     r_rty_mask <= n_rty_mask;
	     r_rty_data <= n_rty_data;
	     r_rty_opcode <= n_rty_opcode;
	     r_rty_from_d <= n_rty_from_d;
	     r_blk_pend <= n_blk_pend;
	     r_blk_cnt <= n_blk_cnt;
	     r_blk_addr <= n_blk_addr;
	     r_blk_op <= n_blk_op;
	     r_blk_way <= n_blk_way;
	     r_blk_l1i_req <= n_blk_l1i_req;
	     r_blk_l1i_done <= n_blk_l1i_done;
	     r_idrop_wait <= n_idrop_wait;
	     r_idropped <= n_idropped;
	     r_ci_lsel <= n_ci_lsel;
	     r_inv_line <= n_inv_line;
`ifdef VERILATOR
	     r_snoop_hit <= n_snoop_hit;
	     r_snoop_dirty <= n_snoop_dirty;
	     if(t_wr_valid | t_wr_tag)
	       begin
		  dbg_v_cyc[t_idx] <= r_cycle;
		  dbg_v_state[t_idx] <= int'(r_state);
		  dbg_v_op[t_idx] <= int'(r_opcode);
		  dbg_v_oldval[t_idx] <= w_valid;
		  dbg_v_oldtag[t_idx] <= longint'(w_tag);
		  dbg_v_newval[t_idx] <= t_wr_valid ? t_valid : w_valid;
		  dbg_v_newtag[t_idx] <= t_wr_tag ? longint'(r_tag) : longint'(w_tag);
		  dbg_v_pres[t_idx] <= int'(w_pres);
		  dbg_v_probed[t_idx] <= r_probed;
		  dbg_v_unc[t_idx] <= r_is_uncache;
	       end
	     if(t_wr_pres)
	       begin
		  dbg_p_cyc[t_idx] <= r_cycle;
		  dbg_p_op[t_idx] <= int'(r_opcode);
		  dbg_p_val[t_idx] <= int'(t_pres);
	       end
	     /* inclusion invariant (sim): a line the L1D may hold (pd) must not be
	      * dropped or replaced unless this op already probed it out */
	     /* MEM_WB/MEM_SW carry the L1D's own copy, which the L1D invalidated (pd is
	      * conservative), so they are exempt; so is a same-colour L1D INVL/PGDROP */
	     if(t_wr_valid && w_valid && w_pres[N_PIDX] && !r_probed &&
		(r_opcode != MEM_WB) && (r_opcode != 6'd7) &&
		/* an L1D INVL/PGDROP at the line's own colour: the L1D just looked
		 * there, so pd is merely stale (conservative) */
		!(((r_opcode == MEM_INVL) || (r_opcode == MEM_PGDROP)) && r_from_d &&
		  (w_pres[N_PIDX-1:0] == w_req_pidx)) &&
		((!t_valid && w_hit) || (t_wr_tag && (r_tag != w_tag))) && (r_pd_drop_n < 64'd40))
	       begin
		  $display("[l2-pd-drop] cyc=%0d state=%0d opcode=%0d uncache=%b idx=%x tag=%x pres=%b valid<=%b",
			   r_cycle, r_state, r_opcode, r_is_uncache, t_idx, w_tag, w_pres, t_valid);
		  r_pd_drop_n <= r_pd_drop_n + 64'd1;
	       end
	     if((r_cycle[23:0] == 24'd0) & ((r_snoop_hit != 64'd0) | (r_snoop_dirty != 64'd0)))
	       $display("[snoopstat] cyc=%0d snoop_hits=%0d dirty=%0d", r_cycle, r_snoop_hit, r_snoop_dirty);
`endif
	     r_store_data <= n_store_data;
	     r_store_mask <= n_store_mask;
	     r_is_uncache <= n_is_uncache;
	     r_uncache_mask <= n_uncache_mask;
	     r_flush_req <= n_flush_req;
	     r_need_l1i <= n_need_l1i;
	     r_need_l1d <= n_need_l1d;
	     r_had_l1d <= n_had_l1d;
	     r_flush_skip <= n_flush_skip;
	     r_got_mem_rsp_valid <= n_got_mem_rsp_valid;
	     r_cache_hits <= n_cache_hits;
	     r_cache_accesses <= n_cache_accesses;	     
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	r_mem_req_store_data <= n_mem_req_store_data;
     end
   
   //always_ff@(negedge clk)
   //begin
	//$display("l1i_flush_req = %b", l1i_flush_req);
	//$display("l1d_flush_req = %b", l1d_flush_req);
	
   //if((l1d_flush_complete||l1i_flush_complete) && (r_flush_state == WAIT_FOR_FLUSH)) 
   //$stop();
   //end
   
   always_comb
     begin
	n_flush_state = r_flush_state;
	n_need_l1d = r_need_l1d | l1d_flush_req;
	n_need_l1i = r_need_l1i | l1i_flush_req;
	n_had_l1d = r_had_l1d | l1d_flush_req;   /* sticky over the sequence */
	t_l2_flush_req = 1'b0;
	t_l2_skip_walk = 1'b0;
	case(r_flush_state)
	  WAIT_FOR_FLUSH:
	    begin
	       if(n_need_l1i | n_need_l1d)
		 begin
		    n_flush_state = WAIT_FOR_L1_FLUSH_DONE;
		    //$display("-> got flush req at cycle %d, n_need_l1d = %b, n_need_l1i = %b", r_cycle, n_need_l1d, n_need_l1i);
		 end
	    end
	  WAIT_FOR_L1_FLUSH_DONE:
	    begin
	       if(r_need_l1d && l1d_flush_complete)
		 begin
		    //$display("-> l1d flush complete at cycle %d", r_cycle);
		    n_need_l1d = 1'b0;
		 end
	       if(r_need_l1i && l1i_flush_complete)
		 begin
		    //$display("-> l1i flush complete at cycle %d", r_cycle);
		    n_need_l1i = 1'b0;
		 end
	       
	       if((n_need_l1d==1'b0) && (n_need_l1i==1'b0))
		 begin
		    //$display("-> firing l2 flush at cycle %d", r_cycle);
		    n_flush_state = WAIT_FOR_FLUSH;
		    t_l2_flush_req = 1'b1;
		    t_l2_skip_walk = ~n_had_l1d;   /* L1I-only -> skip the O(L2_size) walk */
		    n_had_l1d = 1'b0;              /* reset for the next sequence */
		 end
	    end
	endcase
     end // always_comb


   logic [31:0] r_cycle;
   always_ff@(posedge clk)
     begin
	r_cycle <= reset ? 'd0 : (r_cycle + 'd1);
     end

`ifdef VERILATOR
   // L2 line tracer (L2DBG): watch every boundary of the SCSI-descriptor cache
   // line 0x083e4000 -- L1D->L2 stores/writebacks in (side 0), L2 fills from DRAM
   // (side 2), and L2->DRAM evictions out (side 1).  Lets us see whether the L2
   // faithfully passes the line or corrupts it between in and out.
   import "DPI-C" function void l2_line_log(input int side,
					    input longint unsigned pa,
					    input longint unsigned d0,
					    input longint unsigned d1,
					    input int op,
					    input int mask);
   // decision log at CHECK_VALID_AND_TAG for the descriptor line: shows whether the
   // op hit, whether the held line is dirty, and its current content w_d0.
   import "DPI-C" function void l2_chk_log(input longint unsigned pa,
					   input int whit, input int wvalid, input int wdirty,
					   input int op,
					   input longint unsigned d0lo, input longint unsigned d0hi);
   reg r_l2wb_prev;
   always_ff@(posedge clk)
     begin
	r_l2wb_prev <= reset ? 1'b0 : r_mem_req;
     end
   always_ff@(negedge clk)
     begin
	if(l1_mem_req_valid & r_req_ack & (l1_mem_req_addr[31:4] == 28'h083e400))
	  begin
	     l2_line_log(0, {{(64-`PA_WIDTH){1'b0}}, l1_mem_req_addr},
			 l1_mem_req_store_data[63:0], l1_mem_req_store_data[127:64],
			 {26'd0, l1_mem_req_opcode}, {16'd0, l1_mem_req_mask});
	  end
	if(r_mem_req & ~r_l2wb_prev & (r_addr[31:4] == 28'h083e400))
	  begin
	     l2_line_log(1, {{(64-`PA_WIDTH){1'b0}}, r_addr},
			 r_mem_req_store_data[63:0], r_mem_req_store_data[127:64],
			 {27'd0, r_mem_opcode}, {16'd0, r_store_mask});
	  end
	if(mem_rsp_valid & (r_addr[31:4] == 28'h083e400))
	  begin
	     l2_line_log(2, {{(64-`PA_WIDTH){1'b0}}, r_addr},
			 mem_rsp_load_data[63:0], mem_rsp_load_data[127:64], 32'd0, 32'd0);
	  end
	if((r_state == CHECK_VALID_AND_TAG) & (r_saveaddr[31:4] == 28'h083e400))
	  begin
	     l2_chk_log({{(64-`PA_WIDTH){1'b0}}, r_saveaddr},
			{31'd0, w_hit}, {31'd0, w_valid}, {31'd0, w_dirty},
			{26'd0, r_opcode}, w_d0[63:0], w_d0[127:64]);
	  end
     end // always_ff
`endif

`ifdef VERILATOR
   /* R10000 block-op statistics (sim): ops by kind, and what their lines found in the
    * L2 -- a line hit, written back (its own dirty copy, or the L1D's via the probe),
    * or dirty data discarded by Hit Invalidate S.  Probes are [BISTAT] block_op. */
   logic [63:0] r_bs_wbinv, r_bs_inv, r_bs_idx, r_bs_hit, r_bs_wb_l2, r_bs_wb_l1d, r_bs_drop_dirty;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_bs_wbinv <= 'd0;
	     r_bs_inv <= 'd0;
	     r_bs_idx <= 'd0;
	     r_bs_hit <= 'd0;
	     r_bs_wb_l2 <= 'd0;
	     r_bs_wb_l1d <= 'd0;
	     r_bs_drop_dirty <= 'd0;
	  end
	else
	  begin
	     if(r_blk_l1i_req)
	       begin
		  r_bs_wbinv <= r_bs_wbinv + ((r_blk_op == MEM_BLK_WBINV) ? 64'd1 : 64'd0);
		  r_bs_inv <= r_bs_inv + ((r_blk_op == MEM_BLK_INV) ? 64'd1 : 64'd0);
		  r_bs_idx <= r_bs_idx + ((r_blk_op == MEM_BLK_IDX) ? 64'd1 : 64'd0);
	       end
	     if((r_state == CHECK_VALID_AND_TAG) && is_blkop(r_opcode) && t_wr_valid)
	       begin
		  r_bs_hit <= r_bs_hit + 64'd1;
		  if(n_state == UNCACHE_WB_DRAIN)
		    begin
		       r_bs_wb_l1d <= r_bs_wb_l1d + (r_probe_dirty ? 64'd1 : 64'd0);
		       r_bs_wb_l2 <= r_bs_wb_l2 + (r_probe_dirty ? 64'd0 : 64'd1);
		    end
		  else if(w_dirty || r_probe_dirty)
		    begin
		       r_bs_drop_dirty <= r_bs_drop_dirty + 64'd1;
		    end
	       end
	  end
     end // always_ff
   final
     begin
	if((r_bs_wbinv | r_bs_inv | r_bs_idx) != 64'd0)
	  begin
	     $display("[BLKSTAT] ops: 0x17 hit-wbinv %0d, 0x13 hit-inv %0d, 0x03 index-wbinv %0d",
		      r_bs_wbinv, r_bs_inv, r_bs_idx);
	     $display("[BLKSTAT] lines: L2 hit %0d, written back %0d from the L2 + %0d from the L1D, dirty discarded (0x13) %0d",
		      r_bs_hit, r_bs_wb_l2, r_bs_wb_l1d, r_bs_drop_dirty);
	  end
     end
`endif

`ifdef PRESEVICT_LOG
   /* (sim only, opt-in: ~1M lines per 100M Linux insns) log every L2 replacement of a line
    * the L1D may still hold: after its probe (L1I miss) or at once (L1D miss -- a stale pd,
    * the L1D already gave the line up).  Clocked, so it sees settled values and fires once
    * per event. */
   always_ff@(posedge clk)
     begin
	if(!reset && (r_state == CHECK_VALID_AND_TAG) && !r_is_uncache &&
	   ((r_opcode == 6'd4) || (r_opcode == 6'd7)) && !w_hit && w_valid && w_pres[N_PIDX] &&
	   (r_from_d || r_probed))   /* once per eviction: after the probe (L1I) or at once (L1D) */
	  begin
	     $display("[PRESEVICT] cyc=%0d evict pa %x (pidx %0d) for %s req pa %x",
		      r_cycle, {w_tag, t_idx, 4'd0}, w_pres[N_PIDX-1:0],
		      r_from_d ? "L1D" : "L1I", r_saveaddr);
	  end
     end
`endif
   state_t r_last_state;
   always_ff@(posedge clk)
     begin
	r_last_state <= r_state;
     end
   always_ff@(negedge clk)
     begin
	/* a parked fill (L2_HIT_UNDER_MISS) legitimately holds mem_req in IDLE */
	if((r_state == IDLE) & (r_mem_req) & !r_fp)
	  begin
	     $display("l2 protocol busted, last state %d", r_last_state);
	     `ifdef VERILATOR $stop(); `endif
	  end
     end
   

   always_comb
     begin
	n_state = r_state;
	n_flush_complete = 1'b0;
	t_wr_valid = 1'b0;
	t_wr_pres = 1'b0;
	t_pres = 'd0;
	t_wr_dirty = 1'b0;
	t_wr_d0 = 1'b0;
	t_wr_tag = 1'b0;
	
	t_idx = r_idx;
	n_tag = r_tag;
	n_opcode = r_opcode;
	n_from_d = r_from_d;
	n_req_colour = r_req_colour;
	n_addr = r_addr;
	n_saveaddr = r_saveaddr;
	n_src = r_src;
	t_wtag = r_tag;
	t_fp_save = 1'b0;
	t_fp_restore = 1'b0;
	t_def_save = 1'b0;
	t_def_restore = 1'b0;
	t_repl_upd = 1'b0;
	t_repl_ins = 1'b0;
	n_fway = r_fway;
	
	n_req_ack = 1'b0;
	t_s0_accept = 1'b0;
	t_ho_pop = 1'b0;
	t_ho_direct = 1'b0;
	t_ho_req = r_ho0;
	n_snoop_ack = 1'b0;
	n_snp_wbinv = r_snp_wbinv;
	n_snoop_done = 1'b0;
	n_rty_pend = r_rty_pend;
	n_rty_addr = r_rty_addr;
	n_rty_mem_op = r_rty_mem_op;
	n_rty_mask = r_rty_mask;
	n_rty_data = r_rty_data;
	n_rty_opcode = r_rty_opcode;
	n_rty_from_d = r_rty_from_d;
	n_blk_pend = r_blk_pend;
	n_blk_cnt = r_blk_cnt;
	n_blk_addr = r_blk_addr;
	n_blk_op = r_blk_op;
	n_blk_way = r_blk_way;
	n_blk_l1i_req = 1'b0;
	n_blk_l1i_done = r_blk_l1i_done | l1i_blk_inv_done;
	n_idrop_wait = r_idrop_wait;
	n_idropped = r_idropped;
	t_wr_ipres = 1'b0;
	t_ipres = 1'b0;
	n_ci_lsel = r_ci_lsel;
	n_inv_line = r_inv_line;
	n_probe_req = r_probe_req;
	n_probe_addr = r_probe_addr;
	n_probe_colour = r_probe_colour;
	n_probe_reason = r_probe_reason;
	n_probed = r_probed;
	n_probe_dirty = r_probe_dirty;
	n_probe_data = r_probe_data;
`ifdef VERILATOR
	n_snoop_hit = r_snoop_hit;
	n_snoop_dirty = r_snoop_dirty;
`endif
	n_mem_req = r_mem_req;
	n_mem_opcode = r_mem_opcode;
		
	t_valid = 1'b0;
	t_dirty = 1'b0;

	t_d0 = mem_rsp_load_data[127:0];

	n_rsp_data = r_rsp_data;
	n_rsp_valid = 1'b0;
	n_rsp_bad = 1'b0;

	n_reload = r_reload;
	n_store_data = r_store_data;
	n_store_mask = r_store_mask;
	n_is_uncache = r_is_uncache;
	n_uncache_mask = r_uncache_mask;
	n_flush_req = r_flush_req | t_l2_flush_req;
	n_flush_skip = r_flush_skip | (t_l2_flush_req & t_l2_skip_walk);
	n_mem_req_store_data = r_mem_req_store_data;

	n_cache_hits = r_cache_hits;
	n_cache_accesses = r_cache_accesses;

	n_got_mem_rsp_valid = r_got_mem_rsp_valid | mem_rsp_valid;
	
	
	case(r_state)
	  INITIALIZE:
	    begin
	       t_valid = 1'b0;
	       t_dirty = 1'b0;
	       
	       t_wr_valid = 1'b1;
	       t_wr_dirty = 1'b1;
	       t_wr_ipres = 1'b1;
	       t_ipres = 1'b0;
	       
	       t_idx = r_idx + 'd1;
	       if(r_idx == (L2_LINES-1))
		 begin
		    n_state = IDLE;
		    n_flush_complete = 1'b1;
		 end
	    end // case: INITIALIZE
	  IDLE:
	    begin
	       t_idx = l1_mem_req_addr[LG_L2_LINES+3:4];
	       n_tag = l1_mem_req_addr[`PA_WIDTH-1:LG_L2_LINES+4];
	       n_addr = {l1_mem_req_addr[`PA_WIDTH-1:4], 4'd0};
	       n_saveaddr = {l1_mem_req_addr[`PA_WIDTH-1:4], 4'd0};
	       n_opcode = l1_mem_req_opcode;
	       n_from_d = l1_mem_req_from_d;
	       n_req_colour = l1_mem_req_colour;
	       n_probed = 1'b0;
	       n_idropped = 1'b0;
	       n_probe_dirty = 1'b0;
	       n_store_data = l1_mem_req_store_data;
	       n_store_mask = 16'h0;

	       //if(r_mem_req)
	       ///begin
	       //    $stop();
	       //end
	       
	       if(HUM && r_fp && (r_fp_done || mem_rsp_valid) && r_s2_v)
		 begin
		    /* the fill installs here, in IDLE: let S2's write go first (the data
		     * waits in r_fp_data); S0 takes nothing meanwhile */
		 end
	       else if(HUM && r_fp && (r_fp_done || mem_rsp_valid))
		 begin
		    /* the parked fill's data is here: install it (as CLEAN_RELOAD would)
		     * and re-enter CHECK_VALID_AND_TAG with its request, which now hits */
		    t_fp_restore = 1'b1;
		    t_idx = w_fp_set;
		    n_tag = r_fp_addr[`PA_WIDTH-1:LG_L2_LINES+4];
		    t_wtag = r_fp_addr[`PA_WIDTH-1:LG_L2_LINES+4];
		    n_addr = r_fp_addr;
		    n_saveaddr = r_fp_addr;
		    n_opcode = r_fp_opcode;
		    n_from_d = r_fp_from_d;
		    n_req_colour = r_fp_colour;
		    n_probed = r_fp_probed;
		    n_idropped = r_fp_idropped;
		    n_store_data = r_fp_store_data;
		    n_store_mask = 16'hffff;
		    n_src = r_fp_src;
		    n_is_uncache = 1'b0;
		    n_reload = 1'b1;
		    t_valid = 1'b1;
		    t_wr_valid = 1'b1;
		    t_dirty = 1'b0;
		    t_wr_dirty = 1'b1;
		    t_wr_tag = 1'b1;
		    t_d0 = r_fp_done ? r_fp_data : mem_rsp_load_data;   /* or straight off DRAM */
		    t_wr_d0 = 1'b1;
		    n_state = WAIT_CLEAN_RELOAD;
		 end
	       else if(HUM && r_def && !r_fp)
		 begin
		    /* replay the request deferred while the fill was out (already acked) */
		    t_def_restore = 1'b1;
		    t_idx = w_def_set;
		    n_tag = r_def_addr[`PA_WIDTH-1:LG_L2_LINES+4];
		    n_addr = r_def_addr;
		    n_saveaddr = r_def_addr;
		    n_opcode = r_def_opcode;
		    n_from_d = r_def_from_d;
		    n_req_colour = r_def_colour;
		    n_store_data = r_def_store_data;
		    n_src = r_def_src;
		    n_is_uncache = 1'b0;
		    n_state = WAIT_FOR_RAM;
		 end
	       else if((r_ho_n != 2'd0) || t_p_slow)
		 begin
		    /* L2_PIPE: run the oldest request S2 could not finish -- from the
		     * handoff queue, or straight from S2 when the queue is empty -- as if
		     * just accepted (already acked; a writeback already answered).  With
		     * a fill parked and a request deferred it might need DRAM: wait. */
		    if(!(r_fp && r_def))
		      begin
			 t_ho_pop = (r_ho_n != 2'd0);
			 t_ho_direct = (r_ho_n == 2'd0);
			 t_ho_req = (r_ho_n != 2'd0) ? r_ho0 : r_s2;
			 t_idx = t_ho_req.addr[LG_L2_LINES+3:4];
			 n_tag = t_ho_req.addr[`PA_WIDTH-1:LG_L2_LINES+4];
			 n_addr = t_ho_req.addr;
			 n_saveaddr = t_ho_req.addr;
			 n_opcode = t_ho_req.opcode;
			 n_from_d = t_ho_req.from_d;
			 n_req_colour = t_ho_req.colour;
			 n_store_data = t_ho_req.store_data;
			 n_src = t_ho_req.src;
			 n_is_uncache = 1'b0;
			 n_state = WAIT_FOR_RAM;
		      end
		 end
	       else if(PIPE && HUM && (r_fp || r_def))
		 begin
		    /* a fill is parked: the pipeline takes other requesters' LW/SW to
		     * other sets (w_s0_ok); everything else waits for the fill */
		    if(w_s0_ok)
		      begin
			 t_s0_accept = 1'b1;
			 n_req_ack = 1'b1;
			 n_cache_accesses = r_cache_accesses + 64'd1;
			 n_cache_hits = r_cache_hits + 64'd1;
		      end
		 end
	       else if(HUM && (r_fp || r_def))
		 begin
		    /* a fill is parked: take only another requester's cacheable LW/SW to
		     * another set; everything else waits for the fill */
		    if(l1_mem_req_valid && !r_def && w_l2_cacheable &&
		       ((l1_mem_req_opcode == 6'd4) || (l1_mem_req_opcode == 6'd7)) &&
		       (l1_mem_req_src != r_fp_src) &&
		       (l1_mem_req_addr[LG_L2_LINES+3:4] != w_fp_set))
		      begin
			 n_src = l1_mem_req_src;
			 n_req_ack = 1'b1;
			 n_state = WAIT_FOR_RAM;
			 n_rsp_valid = (l1_mem_req_opcode == 6'd7);
			 n_is_uncache = 1'b0;
			 n_cache_accesses = r_cache_accesses + 64'd1;
			 n_cache_hits = r_cache_hits + 64'd1;
		      end
		 end
	       else if(!w_pipe_empty && (n_flush_req || snoop_req_valid || r_rty_pend || r_blk_pend ||
					 (l1_mem_req_valid && !w_s0_fast)))
		 begin
		    /* L2_PIPE: the pipeline empties before the state machine takes
		     * anything but a pipeline request (a DMA snoop: sdsparc_nb.m
		     * DMA_QUIESCE) */
		 end
	       else if(n_flush_req & n_flush_skip)
		 begin
		    /* L1I-only flush: nothing to write back from L2 (I-cache read-only;
		     * the D-side already wrote its lines through to DRAM). Complete the
		     * handshake WITHOUT walking every L2 line. */
		    n_flush_complete = 1'b1;
		    n_flush_req = 1'b0;
		    n_flush_skip = 1'b0;
		 end
	       else if(n_flush_req)
		 begin
		    t_idx = 'd0;
		    n_fway = 'd0;
		    n_state = FLUSH_WAIT;
		    n_store_mask = 16'hffff;
		    //$display("GOT FLUSH REQUEST at cycle %d", r_cycle);
		 end
	       else if(snoop_req_valid)
		 begin
		    /* DMA-coherence snoop: the SCSI DMA engine wrote this line to DRAM
		     * behind the CPU caches, and IRIX can't invalidate r9999's (hidden)
		     * L2.  Synthesize a MEM_INVL so CHECK_VALID_AND_TAG drops the now-
		     * stale L2 copy (a subsequent L1 miss then refetches fresh DRAM).
		     * Priority above the L1 request; the L1 holds its req one more cycle. */
		    t_idx = snoop_req_addr[LG_L2_LINES+3:4];
		    n_tag = snoop_req_addr[`PA_WIDTH-1:LG_L2_LINES+4];
		    n_addr = {snoop_req_addr[`PA_WIDTH-1:4], 4'd0};
		    n_saveaddr = {snoop_req_addr[`PA_WIDTH-1:4], 4'd0};
		    n_opcode = MEM_SNOOP_INVL;
		    n_snoop_ack = 1'b1;
		    n_snp_wbinv = snoop_req_wbinv;
		    /* a snoop is nobody's L1 request: no requester colour, no probe yet */
		    n_from_d = 1'b0;
		    n_probed = 1'b0;
		    n_probe_dirty = 1'b0;
		    /* IDLE presents t_idx to the SYNCHRONOUS tag/valid/dirty RAMs; their
		     * output is valid only NEXT cycle.  Go through WAIT_FOR_RAM (as the
		     * CPU path does) so CHECK_VALID_AND_TAG sees w_hit/w_dirty for THIS
		     * line -- skipping it reads the prior index and invalidates the wrong
		     * line (the boot wedge). */
		    n_state = WAIT_FOR_RAM;
		 end
	       else if(r_rty_pend)
		 begin
		    /* re-issue the NACKed uncached load (any snoop went first, above);
		     * a snoop reused r_opcode/r_from_d, so put the load's back */
		    n_addr = r_rty_addr;
		    n_saveaddr = r_rty_addr;
		    n_mem_opcode = r_rty_mem_op;
		    n_store_mask = r_rty_mask;
		    n_mem_req_store_data = r_rty_data;
		    n_opcode = r_rty_opcode;
		    n_from_d = r_rty_from_d;
		    n_mem_req = 1'b1;
		    n_got_mem_rsp_valid = 1'b0;
		    n_rty_pend = 1'b0;
		    n_state = UNCACHE_LOAD;
		 end
	       else if(r_blk_pend && r_blk_cnt[3])
		 begin
		    /* all eight lines done: answer once the L1I has the block invalidated */
		    if(r_blk_l1i_done)
		      begin
			 n_blk_pend = 1'b0;
			 n_rsp_valid = 1'b1;
		      end
		 end
	       else if(r_blk_pend)
		 begin
		    /* the next line of a block op.  The index form (0x03) names a set, not
		     * a line: the way bit stands in for the top index bit, so the kernel's
		     * sweep of both ways over half the reported size covers every set as
		     * long as Config reports at least this L2's size. */
		    t_idx = (r_blk_op == MEM_BLK_IDX) ? {r_blk_way, w_blk_line[LG_L2_LINES+2:4]} :
			    w_blk_line[LG_L2_LINES+3:4];
		    n_tag = w_blk_line[`PA_WIDTH-1:LG_L2_LINES+4];
		    n_addr = w_blk_line;
		    n_saveaddr = w_blk_line;
		    n_opcode = r_blk_op;
		    n_from_d = 1'b0;
		    n_blk_cnt = r_blk_cnt + 4'd1;
		    n_state = WAIT_FOR_RAM;
		 end
	       else if(l1_mem_req_valid && w_s0_fast)
		 begin
		    if(w_s0_ok)
		      begin
			 t_s0_accept = 1'b1;
			 n_req_ack = 1'b1;
			 n_cache_accesses = r_cache_accesses + 64'd1;
			 n_cache_hits = r_cache_hits + 64'd1;
		      end
		 end
	       else if(l1_mem_req_valid)
		 begin
		    /* only an accepted request names the requester (a NACK retry keeps its own) */
		    n_src = l1_mem_req_src;
		    if(is_blkop(l1_mem_req_opcode))
		      begin
			 /* R10000 block op: take it; the r_blk_pend arm above runs its lines */
			 n_req_ack = 1'b1;
			 n_blk_pend = 1'b1;
			 n_blk_cnt = 4'd0;
			 n_blk_l1i_req = 1'b1;
			 n_blk_l1i_done = 1'b0;
			 n_blk_addr = l1_mem_req_addr[`PA_WIDTH-1:7];
			 n_inv_line = 1'b0;   /* a block op clears the whole block */
			 n_blk_way = l1_mem_req_addr[0];
			 n_blk_op = l1_mem_req_opcode;
		      end
		    else if(w_l2_cacheable == 1'b0)
		      begin
			 /* L2 inclusive of L1: always look the line up first; on an
			  * uncached hit, evict (write back if dirty) + invalidate before
			  * the uncached op so s->mem is authoritative. */
			 n_uncache_mask = l1_mem_req_mask;
			 n_store_mask = l1_mem_req_mask;
			 n_mem_opcode = l1_mem_req_opcode[4:0];   /* uncached data ops are < 24 */
			 n_mem_req_store_data = l1_mem_req_store_data;
			 n_req_ack = 1'b1;
			 n_is_uncache = 1'b1;
			 n_state = WAIT_FOR_RAM;
		      end
		    else
		      begin
			 n_req_ack = 1'b1;
			 n_state = WAIT_FOR_RAM;
			 n_rsp_valid = (l1_mem_req_opcode == 6'd7);
			 n_is_uncache = 1'b0;
			 n_cache_accesses = r_cache_accesses + 64'd1;
			 n_cache_hits = r_cache_hits + 64'd1;
		      end
		 end
	    end
	  WAIT_FOR_RAM:
	    begin
	       n_state = CHECK_VALID_AND_TAG;
	    end
	
	  CHECK_VALID_AND_TAG:
	    begin
	       //load hit
	       if(SEL && !r_way_lock)
		 begin
		    /* L2_SEL_STAGE: this cycle registers the way pick (r_way, r_hit);
		     * stay here (t_idx holds), which also sets r_way_lock */
		 end
	       else if(HUM && r_fp && !w_hit && !r_probed)
		 begin
		    /* a miss while a fill is parked: one DRAM transaction at a time --
		     * set it aside untouched, replay it once the fill is done */
		    t_def_save = 1'b1;
		    n_state = IDLE;
		 end
	       else if(w_idrop_need)
		 begin
		    /* the L1I may hold the resident line (pi) and this request may not
		     * leave it there: drop it from the L1I (one line, every colour) and
		     * clear pi, holding here (t_idx holds) until the L1I is done */
		    if(!r_idrop_wait)
		      begin
			 n_blk_l1i_req = 1'b1;
			 n_blk_addr = {w_tag, t_idx[LG_L2_LINES-1:3]};
			 n_ci_lsel = t_idx[2:0];
			 n_inv_line = 1'b1;
			 n_idrop_wait = 1'b1;
		      end
		    else if(l1i_blk_inv_done)
		      begin
			 n_idrop_wait = 1'b0;
			 n_idropped = 1'b1;
			 t_wr_ipres = 1'b1;
			 t_ipres = 1'b0;
		      end
		 end
	       else if(r_is_uncache && w_hit && w_pres[N_PIDX] && !r_probed)
		 begin
		    /* an uncached access to a line the L1D may hold (pd): probe it out first,
		     * as before any other drop -- else the L2 drops a line the L1D keeps
		     * (inclusion broken: a later block op or snoop never finds it) and a
		     * dirty L1D copy is not what the uncached op sees.  The arm below then
		     * writes back whichever copy is dirty.  Stay put until the ack. */
		    n_probe_req = 1'b1;
		    n_probe_addr = {w_tag, t_idx, 4'd0};
		    n_probe_colour = w_pres[N_PIDX-1:0];
		    n_probe_reason = 4'd8;
		    if(r_probe_req && probe_ack)
		      begin
			 n_probe_req = 1'b0;
			 n_probed = 1'b1;
			 n_probe_dirty = probe_dirty;
			 n_probe_data = probe_data;
		      end
		 end
	       else if(r_is_uncache)
		 begin
		    n_is_uncache = 1'b0;
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
			 t_wr_dirty = 1'b1; t_dirty = 1'b0;
			 if(w_dirty || r_probe_dirty)
			   begin
			      /* a dirty L1D copy (the probe above) is the newest data */
			      n_mem_req_store_data = r_probe_dirty ? r_probe_data : w_d0;
			      n_addr = {w_tag, t_idx, 4'd0};
			      n_mem_opcode = 5'd7;
			      n_store_mask = 16'hffff;
			      n_mem_req = 1'b1;
			      n_got_mem_rsp_valid = 1'b0;
			      n_state = UNCACHE_WB_DRAIN;
			   end
			 else
			   begin
			      n_addr = r_saveaddr;
			      n_mem_opcode = r_opcode[4:0];   /* an uncached data op (< 24) */
			      n_store_mask = r_uncache_mask;
			      n_mem_req_store_data = r_store_data;
			      n_mem_req = 1'b1;
			      n_got_mem_rsp_valid = 1'b0;
			      n_state = (r_opcode == 6'd7) ? UNCACHE_STORE : UNCACHE_LOAD;
			   end
		      end
		    else
		      begin
			 n_addr = r_saveaddr;
			 n_mem_opcode = r_opcode[4:0];   /* an uncached data op (< 24) */
			 n_store_mask = r_uncache_mask;
			 n_mem_req_store_data = r_store_data;
			 n_mem_req = 1'b1;
			 n_got_mem_rsp_valid = 1'b0;
			 n_state = (r_opcode == 6'd7) ? UNCACHE_STORE : UNCACHE_LOAD;
		      end
		 end
	       else if((w_alias || w_ifill_pd) && !r_probed)
		 begin
		    /* stage C2: probe the other-colour copy out of the L1D; the arms below
		     * then run with r_probed set and use r_probe_data if it was dirty.
		     * Stay in CHECK_VALID_AND_TAG (t_idx holds, so w_* stay put). */
		    n_probe_req = 1'b1;
		    n_probe_addr = {w_tag, t_idx, 4'd0};
		    n_probe_colour = w_pres[N_PIDX-1:0];
		    n_probe_reason = w_ifill_pd ? 4'd9 : (r_opcode == 6'd4) ? 4'd2 : (r_opcode == MEM_INVL) ? 4'd3 : 4'd4;
		    if(r_probe_req && probe_ack)
		      begin
			 n_probe_req = 1'b0;
			 n_probed = 1'b1;
			 n_probe_dirty = probe_dirty;
			 n_probe_data = probe_data;
		      end
		 end
	       else if(is_blkop(r_opcode))
		 begin
		    /* one line of a block op: the WBINV snoop (0x17, 0x03) or the DROP
		     * snoop (0x13) below -- probe out any L1D copy, write back a dirty
		     * line unless dropping, invalidate -- then back to IDLE for the next
		     * line (IDLE answers the L1D after the last). */
		    if(w_blk_hit && w_pres[N_PIDX] && !r_probed)
		      begin
			 n_probe_req = 1'b1;
			 n_probe_addr = {w_tag, t_idx, 4'd0};
			 n_probe_colour = w_pres[N_PIDX-1:0];
			 n_probe_reason = 4'd7;
			 if(r_probe_req && probe_ack)
			   begin
			      n_probe_req = 1'b0;
			      n_probed = 1'b1;
			      n_probe_dirty = probe_dirty;
			      n_probe_data = probe_data;
			   end
		      end
		    else if(w_blk_hit && (r_opcode != MEM_BLK_INV) && (w_dirty || r_probe_dirty))
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
			 t_wr_dirty = 1'b1; t_dirty = 1'b0;
			 n_mem_req_store_data = r_probe_dirty ? r_probe_data : w_d0;
			 n_addr = {w_tag, t_idx, 4'd0};
			 n_mem_opcode = 5'd7;
			 n_store_mask = 16'hffff;
			 n_mem_req = 1'b1;
			 n_got_mem_rsp_valid = 1'b0;
			 n_state = UNCACHE_WB_DRAIN;   /* drain + turnaround, then the next line */
		      end
		    else
		      begin
			 if(w_blk_hit)
			   begin
			      t_wr_valid = 1'b1; t_valid = 1'b0;
			      t_wr_dirty = 1'b1; t_dirty = 1'b0;
			   end
			 n_state = IDLE;
		      end
		 end
	       else if(r_opcode == MEM_INVL)
		 begin
		    /* CACHE-Invalidate: drop the L2 line if present, then ack.
		     * FIX (a): if the L2 line is DIRTY, WRITE IT BACK TO DRAM FIRST.
		     * A dirty L2 line means an L1D eviction (MEM_SW) landed valid data
		     * here that never reached DRAM; a bare drop loses it (copy_page's
		     * VIPT same-set eviction + a coherence CHWBINV whose L1D line was
		     * already evicted -> plain INVL -> init SIGSEGV).  Flush w_d0 to
		     * DRAM, then ack.  Route the writeback through UNCACHE_WB_DRAIN
		     * (NOT straight to a store) so the mem_req turnaround gap runs --
		     * without it the AXI master's WAIT can't fall to IDLE and the bus
		     * DEADLOCKS on silicon (the wirepda class; henry_tb DRAM acks
		     * instantly so sim missed it).  UNCACHE_WB_TURNAROUND acks when
		     * r_opcode==MEM_INVL. */
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
			 t_wr_dirty = 1'b1; t_dirty = 1'b0;
			 if(w_dirty || r_probe_dirty)
			   begin
			      /* a dirty other-colour L1D copy (alias probe) is the newest data */
			      n_mem_req_store_data = r_probe_dirty ? r_probe_data : w_d0;
			      n_addr = {w_tag, t_idx, 4'd0};
			      n_mem_opcode = 5'd7;
			      n_store_mask = 16'hffff;
			      n_mem_req = 1'b1;
			      n_got_mem_rsp_valid = 1'b0;
			      n_state = UNCACHE_WB_DRAIN;   /* drain+turnaround, then ack */
			   end
			 else
			   begin
			      n_state = IDLE;
			      n_rsp_valid = 1'b1;
			   end
		      end
		    else
		      begin
			 n_state = IDLE;
			 n_rsp_valid = 1'b1;
		      end
		 end
	       else if(r_opcode == MEM_PGDROP)
		 begin
		    /* injected page drop (L1D page walk, XPG_INV): the DMA deposit is in
		     * DRAM, so drop the L2 copy WITHOUT a writeback (a writeback would
		     * clobber the deposit).  Report a dirty hit in rsp_data[0]: the
		     * pre-transfer XPG_WBINV cleaned the page, so dirty here is a bug. */
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
			 t_wr_dirty = 1'b1; t_dirty = 1'b0;
		      end
		    n_rsp_data = {127'd0, w_hit & (w_dirty | r_probe_dirty)};
		    n_state = IDLE;
		    n_rsp_valid = 1'b1;
		 end
	       else if((r_opcode == MEM_SNOOP_INVL) && r_snp_wbinv)
		 begin
		    /* WBINV snoop (inclusive L2): if the L1D may hold the line, probe it out
		     * at pidx first (rule 1 of the protocol, for an external requester);
		     * then write back whichever copy is dirty and invalidate. */
		    if(w_hit && w_pres[N_PIDX] && !r_probed)
		      begin
			 n_probe_req = 1'b1;
			 n_probe_addr = {w_tag, t_idx, 4'd0};
			 n_probe_colour = w_pres[N_PIDX-1:0];
			 n_probe_reason = 4'd5;
			 if(r_probe_req && probe_ack)
			   begin
			      n_probe_req = 1'b0;
			      n_probed = 1'b1;
			      n_probe_dirty = probe_dirty;
			      n_probe_data = probe_data;
			   end
		      end
		    else if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
			 t_wr_dirty = 1'b1; t_dirty = 1'b0;
			 if(w_dirty || r_probe_dirty)
			   begin
			      n_mem_req_store_data = r_probe_dirty ? r_probe_data : w_d0;
			      n_addr = {w_tag, t_idx, 4'd0};
			      n_mem_opcode = 5'd7;
			      n_store_mask = 16'hffff;
			      n_mem_req = 1'b1;
			      n_got_mem_rsp_valid = 1'b0;
			      n_state = UNCACHE_WB_DRAIN;   /* drain + turnaround, then done */
			   end
			 else
			   begin
			      n_state = IDLE;
			      n_snoop_done = 1'b1;
			   end
		      end
		    else
		      begin
			 n_state = IDLE;   /* not in the L2 -> not in the L1D (inclusion) */
			 n_snoop_done = 1'b1;
		      end
		 end
	       else if((r_opcode == MEM_SNOOP_INVL) && w_hit && w_pres[N_PIDX] && !r_probed)
		 begin
		    /* DROP snoop (the DMA-in post-drop) on a line the L1D may hold: the L2 is
		     * inclusive, so the L1D copy goes too -- probe it out at pidx; whatever
		     * comes back (even dirty) is discarded with the L2 copy below. */
		    n_probe_req = 1'b1;
		    n_probe_addr = {w_tag, t_idx, 4'd0};
		    n_probe_colour = w_pres[N_PIDX-1:0];
		    n_probe_reason = 4'd6;
		    if(r_probe_req && probe_ack)
		      begin
			 n_probe_req = 1'b0;
			 n_probed = 1'b1;
			 n_probe_dirty = probe_dirty;
			 n_probe_data = probe_data;
		      end
		 end
	       else if(r_opcode == MEM_SNOOP_INVL)
		 begin
		    /* DMA-coherence snoop discard: the SCSI DMA overwrote DRAM for this
		     * line behind the caches, and IRIX (in-order R4x00 model) never issues
		     * a CACHE op for a buffer it didn't touch -- so a speculatively-cached
		     * stale L2 copy would survive.  Drop it WITHOUT a writeback: DRAM now
		     * holds the fresh DMA data, so writing a stale L2 copy back (as MEM_INVL
		     * does) would clobber it.  A dirty stale copy is a recycled prior-owner
		     * page, never live data.  No L1 response (FIFO acked in IDLE). */
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
			 t_wr_dirty = 1'b1; t_dirty = 1'b0;   /* no stale dirty bit left behind */
		      end
`ifdef VERILATOR
		    if(w_hit)
		      begin
			 n_snoop_hit  = r_snoop_hit  + 64'd1;
			 n_snoop_dirty = r_snoop_dirty + (w_dirty ? 64'd1 : 64'd0);
			 if(w_dirty & (r_snoop_dirty < 64'd40))
			   $display("[snoopdirty] cyc=%0d snoop_pa=%x tag=%x idx=%x d0=%x",
				    r_cycle, r_saveaddr, w_tag, t_idx, w_d0[31:0]);
		      end
`endif
		    n_state = IDLE;
		    n_snoop_done = 1'b1;
		 end
	       else if(r_opcode == MEM_WB)
		 begin
		    /* CACHE writeback-through: r_store_data is the latest (L1D dirty)
		     * line. Write it straight to DRAM; if L2 also holds the line, drop
		     * the now-stale L2 copy. Reuse UNCACHE_STORE to wait for the DRAM
		     * ack, then ack the L1. */
		    n_mem_req_store_data = r_store_data;
		    n_addr = r_saveaddr;
		    n_mem_opcode = 5'd7;
		    n_store_mask = 16'hffff;
		    n_mem_req = 1'b1;
		    if(w_hit)
		      begin
			 t_wr_valid = 1'b1; t_valid = 1'b0;
		      end
		    n_state = UNCACHE_STORE;
		 end
`ifdef ENABLE_COHERENT_L1I
	       else if(w_hit && (r_opcode == 6'd4) && !r_from_d && w_pres[N_PIDX] && !r_probed)
		 begin
		    /* coherent L1I: an L1I fill of a line the L1D may hold -- probe it out of
		     * the L1D first; a dirty copy comes back and is what the L1I gets (the
		     * arm below serves r_probe_data and keeps it here, dirty) */
		    n_probe_req = 1'b1;
		    n_probe_addr = {w_tag, t_idx, 4'd0};
		    n_probe_colour = w_pres[N_PIDX-1:0];
		    n_probe_reason = 4'd9;
		    if(r_probe_req && probe_ack)
		      begin
			 n_probe_req = 1'b0;
			 n_probed = 1'b1;
			 n_probe_dirty = probe_dirty;
			 n_probe_data = probe_data;
		      end
		 end
`endif
	       else if(w_hit)
		 begin
		    n_reload = 1'b0;
		    /* a hit promotes the line; not the hit that follows its own fill, which
		     * keeps the insertion state the fill gave it (r_reload: CLEAN_RELOAD or
		     * the parked fill's install brought it here) */
		    t_repl_upd = !r_reload && ((r_opcode == 6'd4) || (r_opcode == 6'd7));
		    if(r_opcode == 6'd4)
		      begin
			 /* an L1D fill: record that the L1D holds the line, and where
			  * (a walk read holds no copy: the alias probe took any L1D copy,
			  * and the arm below clears pd) */
			 if(r_from_d && !w_mmu_rd)
			   begin
			      t_wr_pres = 1'b1;
			      t_pres = {1'b1, w_req_pidx};
			   end
			 else if(r_probed)
			   begin
			      /* an L1I fill or a walk read: the probe took it out of the L1D */
			      t_wr_pres = 1'b1;
			      t_pres = 'd0;
			   end
			 if(!r_from_d)
			   begin
			      /* an L1I fill: the L1I may now hold the line */
			      t_wr_ipres = 1'b1;
			      t_ipres = 1'b1;
			   end
			 n_rsp_data =  w_d0;
			 if(r_probe_dirty)
			   begin
			      /* the alias probe returned the L1D's dirty copy: it is the
			       * newest data -- serve it and keep it here, dirty */
			      n_rsp_data = r_probe_data;
			      t_d0 = r_probe_data;
			      t_wr_d0 = 1'b1;
			      t_wr_dirty = 1'b1;
			      t_dirty = 1'b1;
			   end
			 if(w_mmu_rd && (w_mmu_new != w_mmu_old))
			   begin
			      /* the walk's R/M update, atomic with its read; the walker
			       * gets the line as it was and applies the bits itself */
			      t_d0 = w_mmu_new;
			      t_wr_d0 = 1'b1;
			      t_wr_dirty = 1'b1;
			      t_dirty = 1'b1;
			   end
			 n_state = IDLE;
			 n_rsp_valid = 1'b1;
			 //n_cache_hits = r_cache_hits + 64'd1;			 
		      end
		    else if(r_opcode == 6'd7)
		      begin
			 /* an L1D writeback (victim / alias / flush): it gave the line up */
			 if(r_from_d)
			   begin
			      t_wr_pres = 1'b1;
			      t_pres = 'd0;
			   end
			 t_wr_dirty = 1'b1;
			 t_dirty = 1'b1;
			 n_state = WAIT_STORE_IDLE;
			 //n_cache_hits = r_cache_hits + 64'd1;			 
			 t_d0 = r_store_data;
			 t_wr_d0 = 1'b1;
		      end
		 end
	       else if(w_valid && w_pres[N_PIDX] && !r_probed)
		 begin
		    /* rule 1: before evicting a line the L1D may hold (pd), back-invalidate it
		     * there at pidx -- whoever caused the eviction (L1I miss, or an L1D miss at
		     * any colour: with a VA-indexed L1D the victim can sit in another set).
		     * Stay in CHECK_VALID_AND_TAG (t_idx holds, so w_* stay put) until the ack;
		     * a dirty copy comes back and is what gets written back. */
		    n_probe_req = 1'b1;
		    n_probe_addr = {w_tag, t_idx, 4'd0};
		    n_probe_colour = w_pres[N_PIDX-1:0];
		    n_probe_reason = r_from_d ? 4'd1 : 4'd0;
		    if(r_probe_req && probe_ack)
		      begin
			 n_probe_req = 1'b0;
			 n_probed = 1'b1;
			 n_probe_dirty = probe_dirty;
			 n_probe_data = probe_data;
		      end
		 end
	       else
		 begin
		    n_cache_hits = r_cache_hits - 64'd1;
		    /* the fill will install into this way (t_sel, the victim): give it the
		     * insertion state now, while the set's state is in hand; nothing else
		     * touches the set before the fill lands */
		    t_repl_ins = 1'b1;
		    /* Evict the resident line only if it is BOTH valid and dirty
		     * (w_need_wb). A bare w_dirty test wrote back lines that a prior
		     * MEM_WB left valid=0/dirty=1 (MEM_WB clears valid but not dirty,
		     * unlike MEM_INVL) -> a stale copy clobbered the SCSI-DMA descriptor
		     * in DRAM (armed {08398f80,0x40} regressed to {883e4800,0}) -> IRIX
		     * XFS panic. The CLEAN_RELOAD fill site already defends the same leak. */
		    if(w_need_wb || r_probe_dirty)
		      begin
			 /* a dirty L1D copy (returned by the probe) is newer than the L2's */
			 n_mem_req_store_data = r_probe_dirty ? r_probe_data : w_d0;
			 /* consumed: the reload re-enters CHECK_VALID_AND_TAG and HITS, and the
			  * fill arm must not mistake this victim's data for an alias copy of the
			  * line being filled (it served D's data as T's code to the L1I) */
			 n_probe_dirty = 1'b0;
			 n_addr = {w_tag, t_idx, 4'd0};
			 n_mem_opcode = 5'd7;
			 n_store_mask = 16'hffff;
			 
			 n_mem_req = 1'b1;
			 n_got_mem_rsp_valid = 1'b0;			 
			 n_state = DIRTY_STORE;			 
		      end
		    else //invalid or clean
		      begin
`ifdef VERILATOR
			 if(r_reload)
			   $stop();
`endif
			 n_reload = 1'b1;
			 n_state = CLEAN_RELOAD;
			 n_mem_opcode = 5'd4; //load
			 n_store_mask = 16'hffff;			 
			 n_mem_req = 1'b1;
			 n_got_mem_rsp_valid = 1'b0;			 
			 if(HUM && !r_is_uncache && ((r_opcode == 6'd4) || (r_opcode == 6'd7)))
			   begin
			      /* park it: the DRAM read runs from r_fp_*; serve others meanwhile */
			      t_fp_save = 1'b1;
			      n_reload = 1'b0;
			      n_state = IDLE;
			   end
		      end
		 end
	    end // case: CHECK_VALID_AND_TAG
	  DIRTY_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;		    
		 end
	       if(mem_rsp_valid)
		 begin
		    n_addr = r_saveaddr;
		    n_mem_opcode = 5'd4; //load
		    n_store_mask = 16'hffff;
		    n_state = STORE_TURNAROUND;
		    n_mem_req = 1'b0;		    
		 end
	    end // case: DIRTY_STORE
	  STORE_TURNAROUND:
	    begin
	       n_state = CLEAN_RELOAD;
	       n_reload = 1'b1;
	       n_mem_req = 1'b1;
	       n_got_mem_rsp_valid = 1'b0;		       
	    end
	  CLEAN_RELOAD:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end
	       if(mem_rsp_valid)
		 begin
		    n_mem_req = 1'b0;
		    t_valid = 1'b1;
		    t_wr_valid = 1'b1;
		    /* a clean DRAM fill MUST be marked NOT-dirty: otherwise a stale
		     * dirty bit (left over from a prior invalidate/eviction that cleared
		     * valid but not dirty) rides into the reloaded line and later writes
		     * back garbage over a DMA'd buffer (the SCSI INQUIRY clobber). */
		    t_dirty = 1'b0;
		    t_wr_dirty = 1'b1;
		    t_wr_tag = 1'b1;
		    t_wr_d0 = 1'b1;
		    n_state = WAIT_CLEAN_RELOAD;
		 end
	    end // case: CLEAN_RELOAD
	  WAIT_CLEAN_RELOAD: /* need a cycle to turn around */
	    begin
	       n_state = WAIT_FOR_RAM;
	    end
	  WAIT_STORE_IDLE:
	    begin
	       n_state = IDLE;
	    end
	  FLUSH_WAIT:
	    begin
	       n_state = FLUSH_TRIAGE;
	       t_valid = 1'b0;
	       t_dirty = 1'b0;
	       t_wr_valid = 1'b1;
	       t_wr_dirty = 1'b1;
	    end
	  FLUSH_TRIAGE:
	    begin
	       //$display("r_idx = %d, w_need_wb %b", r_idx, w_need_wb);
	       
	       if(w_need_wb)
		 begin
		    n_mem_req_store_data = w_d0;
		    n_addr = {w_tag, t_idx, 4'd0};
		    n_mem_opcode = 5'd7; 
		    n_mem_req = 1'b1;
		    n_got_mem_rsp_valid = 1'b0;			 
		    n_state = FLUSH_STORE;
		 end
	       else
		 begin
		    if(int'(r_fway) != (L2_WAYS-1))
		      begin
			 /* the next way of this set */
			 n_fway = r_fway + 'd1;
			 n_state = FLUSH_WAIT;
		      end
		    else
		      begin
			 n_fway = 'd0;
			 t_idx = r_idx + 'd1;
			 if(r_idx == (L2_LINES-1))
			   begin
			      n_state = IDLE;
			      //$display("L2 flush complete at cycle %d", r_cycle);
			      n_flush_complete = 1'b1;
			      n_flush_req = 1'b0;
			   end
			 else
			   begin
			      n_state = FLUSH_WAIT;
			   end
		      end
		 end
	    end // case: FLUSH_TRIAGE
	  FLUSH_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;		    
		 end
	       
	       if(mem_rsp_valid)
		 begin
		    n_mem_req = 1'b0;
		    if(int'(r_fway) != (L2_WAYS-1))
		      begin
			 n_fway = r_fway + 'd1;
			 n_state = FLUSH_WAIT;
		      end
		    else
		      begin
			 n_fway = 'd0;
			 t_idx = r_idx + 'd1;
			 if(r_idx == (L2_LINES-1))
			   begin
			      n_state = IDLE;
			      //$display("L2 flush complete at cycle %d", r_cycle);
			      n_flush_complete = 1'b1;
			      n_flush_req = 1'b0;
			   end
			 else
			   begin
			      n_state = FLUSH_WAIT;
			   end
		      end
		 end
	    end // case: FLUSH_STORE
	  UNCACHE_STORE:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end	       
	       if(mem_rsp_valid)
		 begin
		    n_state = IDLE;
		    n_rsp_valid = 1'b1;
		    n_mem_req = 1'b0;		    
		 end
	    end
	  UNCACHE_LOAD:
	    begin
	       if(mem_req_ack)
		 begin
		    n_mem_req = 1'b0;
		 end	       
	       if(mem_rsp_valid & mem_rsp_retry)
		 begin
		    /* NACKed: no answer to the L1; back to IDLE (snoops are taken there)
		     * and re-issue it from there */
		    n_rty_pend = 1'b1;
		    n_rty_addr = r_addr;
		    n_rty_mem_op = r_mem_opcode;
		    n_rty_mask = r_store_mask;
		    n_rty_data = r_mem_req_store_data;
		    n_rty_opcode = r_opcode;
		    n_rty_from_d = r_from_d;
		    n_state = IDLE;
		    n_mem_req = 1'b0;
		 end
	       else if(mem_rsp_valid)
		 begin
		    n_rsp_valid = 1'b1;
		    n_rsp_data = mem_rsp_load_data;
		    n_rsp_bad = mem_rsp_bad;      /* e.g. an MC GIO time-out: the load takes DBE */
		    n_state = IDLE;
		    n_mem_req = 1'b0;
		 end
	    end
	  UNCACHE_WB_DRAIN:
	    begin
	       if(mem_req_ack)
		 n_mem_req = 1'b0;
	       if(mem_rsp_valid)
		 begin
		    /* writeback done: drop mem_req for a turnaround cycle so the AXI
		     * master's WAIT state can fall back to IDLE before we issue the
		     * uncached store/load (it gates WAIT->IDLE on mem_req dropping).
		     * Without the gap the back-to-back req deadlocks the AXI WAIT. */
		    n_mem_req = 1'b0;
		    n_got_mem_rsp_valid = 1'b0;
		    n_state = UNCACHE_WB_TURNAROUND;
		 end
	    end
	  UNCACHE_WB_TURNAROUND:
	    begin
	       /* the mem_req turnaround gap is now satisfied. */
	       if(r_opcode == MEM_INVL)
		 begin
		    /* dirty-INVL writeback drained -- just ack the L1 (no uncached op
		     * follows the invalidate). */
		    n_state = IDLE;
		    n_rsp_valid = 1'b1;
		 end
	       else if(r_opcode == MEM_SNOOP_INVL)
		 begin
		    /* WBINV snoop writeback drained: no L1 response, signal completion */
		    n_state = IDLE;
		    n_snoop_done = 1'b1;
		 end
	       else if(is_blkop(r_opcode))
		 begin
		    /* a block op line's writeback drained: IDLE runs the next line, or answers */
		    n_state = IDLE;
		 end
	       else
		 begin
		    /* re-issue the uncached op that the dirty-evict writeback preceded */
		    n_addr = r_saveaddr;
		    n_mem_opcode = r_opcode[4:0];   /* an uncached data op (< 24) */
		    n_store_mask = r_uncache_mask;
		    n_mem_req_store_data = r_store_data;
		    n_mem_req = 1'b1;
		    n_state = (r_opcode == 6'd7) ? UNCACHE_STORE : UNCACHE_LOAD;
		 end
	    end
	  default:
	    begin
	    end
	endcase
	/* a parked fill holds the DRAM request until its response */
	if(HUM && (r_fp || t_fp_save || t_p_park))
	  begin
	     /* r_fp_done is stale (the previous fill's) until r_fp: only count it while parked */
	     n_mem_req = !(r_fp && (r_fp_done || mem_rsp_valid));
	  end
	if(t_p_park)
	  begin
	     /* the S0 accept counted it as a hit */
	     n_cache_hits = n_cache_hits - 64'd1;
	  end
	if(t_wr_valid && !t_wr_pres)
	  begin
	     t_wr_pres = 1'b1;
	     t_pres = 'd0;
	  end
	/* L2_WAYS: hold the way CHECK_VALID_AND_TAG picked while it stays there and
	 * through a miss's writeback and fill (see t_sel) */
	n_way_lock = ((r_state == CHECK_VALID_AND_TAG) || r_way_lock) &&
		     ((n_state == CHECK_VALID_AND_TAG) || (n_state == DIRTY_STORE) ||
		      (n_state == STORE_TURNAROUND) || (n_state == CLEAN_RELOAD));
     end // always_comb

`ifdef DESC_TRACE
   // TEMP sim-only trace: the IRIX t1/L0 INQUIRY descriptor page (PA 0x0841d000).
   // Gated behind DESC_TRACE (was always-on under VERILATOR and spammed the boot).
   always_ff @(posedge clk) begin
      if(l1_mem_req_valid & (l1_mem_req_addr[35:12] == 24'h00841d))
        $display("[desc l1->l2] op=%2d addr=%09x data=%08x", l1_mem_req_opcode,
                 l1_mem_req_addr, l1_mem_req_store_data[31:0]);
      if(mem_req_valid & (mem_req_addr[35:12] == 24'h00841d))
        $display("[desc l2->dram] op=%2d addr=%09x data=%08x", mem_req_opcode,
                 mem_req_addr, mem_req_store_data[31:0]);
   end
`endif
`ifdef VERILATOR
   /* sim-only: cycles the L2 spends in each state, and how many times each is
    * entered (where an L1 request's latency goes) */
   longint unsigned c_l2_cyc[16], c_l2_ent[16];
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     for(integer i = 0; i < 16; i = i + 1)
	       begin
		  c_l2_cyc[i] <= 0;
		  c_l2_ent[i] <= 0;
	       end
	  end
	else
	  begin
	     c_l2_cyc[r_state] <= c_l2_cyc[r_state] + 1;
	     if(n_state != r_state)
	       begin
		  c_l2_ent[n_state] <= c_l2_ent[n_state] + 1;
	       end
	  end
     end
   final
     begin
	for(integer i = 0; i < 16; i = i + 1)
	  begin
	     if(c_l2_cyc[i] != 0)
	       begin
		  $display("[L2STATE] %0d cycles %0d entries %0d", i, c_l2_cyc[i], c_l2_ent[i]);
	       end
	  end
     end
`endif
endmodule
