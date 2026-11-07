// free_fifo -- one pool of the integer free list, as a circular queue of free
// physical register numbers (the R10000 free list).  core.sv keeps four: the
// ALU and MEM halves of the PRF, each split by parity, so a rename slot pops
// at most one register from a pool per cycle.
//
// Pointers (one wrap bit above the LG_Q index bits):
//   r_head     the next register to allocate (rename pops here)
//   r_tail     where a freed register is written (retire pushes here)
//   r_ret_head r_head as of the last retired allocation: the entries in
//              [r_ret_head, r_head) went to in-flight instructions.  Recovery
//              (every flush in this core is at retirement) sets r_head back to
//              r_ret_head, which returns them -- no ROB walk, no second copy.
//
// The registers in [r_ret_head, r_tail) are distinct members of this pool, so
// the queue never holds more than Q of them and a push never overwrites a live
// entry.  The storage is banked by position parity: the two pushes of a cycle
// land at consecutive positions (push 0 first), one per bank, so each bank has
// a single write port (LUTRAM).
module free_fifo(clk,
		 reset,
		 push0,
		 push0_val,
		 push1,
		 push1_val,
		 pop,
		 commit,
		 recover,
		 head_val,
		 empty,
		 count);
   parameter LG_Q = 6;
   parameter W = 8;
   localparam Q = 1 << LG_Q;
   input logic clk;
   input logic reset;
   input logic push0;
   input logic [W-1:0] push0_val;
   input logic push1;
   input logic [W-1:0] push1_val;
   input logic pop;
   input logic [1:0] commit;     /* retired allocations from this pool, 0..2 */
   input logic recover;          /* r_head = r_ret_head (before this cycle's pop) */
   output logic [W-1:0] head_val;
   output logic empty;
   output logic [LG_Q:0] count;  /* free entries, [r_head, r_tail) */

   logic [LG_Q:0] r_head, n_head, r_tail, n_tail, r_ret_head, n_ret_head;
   logic [W-1:0]  r_bank0[(Q/2)-1:0];
   logic [W-1:0]  r_bank1[(Q/2)-1:0];

   wire [LG_Q:0]  w_pos1 = r_tail + {{LG_Q{1'b0}}, push0};   /* push 1's position */

   assign head_val = r_head[0] ? r_bank1[r_head[LG_Q-1:1]] : r_bank0[r_head[LG_Q-1:1]];
   assign empty = (r_head == r_tail);
   assign count = r_tail - r_head;

   always_comb
     begin
	n_head = (recover ? r_ret_head : r_head) + {{LG_Q{1'b0}}, pop};
	n_ret_head = r_ret_head + {{(LG_Q-1){1'b0}}, commit};
	n_tail = r_tail + {{LG_Q{1'b0}}, push0} + {{LG_Q{1'b0}}, push1};
     end

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_head <= 'd0;
	     r_tail <= 'd0;
	     r_ret_head <= 'd0;
	  end
	else
	  begin
	     r_head <= n_head;
	     r_tail <= n_tail;
	     r_ret_head <= n_ret_head;
	  end
     end // always_ff@ (posedge clk)

   /* one write per bank per cycle: push 0 at r_tail, push 1 at the next position */
   always_ff@(posedge clk)
     begin
	if(push0 && !r_tail[0])
	  begin
	     r_bank0[r_tail[LG_Q-1:1]] <= push0_val;
	  end
	else if(push1 && !w_pos1[0])
	  begin
	     r_bank0[w_pos1[LG_Q-1:1]] <= push1_val;
	  end
     end // always_ff@ (posedge clk)

   always_ff@(posedge clk)
     begin
	if(push0 && r_tail[0])
	  begin
	     r_bank1[r_tail[LG_Q-1:1]] <= push0_val;
	  end
	else if(push1 && w_pos1[0])
	  begin
	     r_bank1[w_pos1[LG_Q-1:1]] <= push1_val;
	  end
     end // always_ff@ (posedge clk)

`ifdef VERILATOR
   /* debug only: a push of a register still live after this cycle's commits,
    * in [n_ret_head, r_tail), is a double free (a %g0 writer frees the pdst it
    * commits this cycle); more than Q live entries means the pool's accounting broke */
   function automatic logic [W-1:0] entry(input logic [LG_Q:0] p);
      begin
	 entry = p[0] ? r_bank1[p[LG_Q-1:1]] : r_bank0[p[LG_Q-1:1]];
      end
   endfunction // entry

   /* the registers free in this pool, [r_head, r_tail): read by core.sv's
    * ownership check.  A duplicate entry shows up as fewer bits than count. */
   logic [(1<<W)-1:0] w_dbg_free;
   always_comb
     begin
	w_dbg_free = 'd0;
	for(integer i = 0; i < Q; i = i + 1)
	  begin
	     if((LG_Q+1)'(i) < count)
	       begin
		  w_dbg_free[entry(r_head + (LG_Q+1)'(i))] = 1'b1;
	       end
	  end
     end // always_comb

   always_ff@(negedge clk)
     begin
	if(!reset)
	  begin
	     if(32'($countones(w_dbg_free)) != 32'(count))
	       begin
		  $display("[FREEQ] %m a register is queued twice (%0d entries, %0d distinct)", count, $countones(w_dbg_free));
	       end
	     for(integer i = 0; i < Q; i = i + 1)
	       begin
		  if((LG_Q+1)'(i) < (r_tail - n_ret_head))
		    begin
		       if(push0 && (entry(n_ret_head + (LG_Q+1)'(i)) == push0_val))
			 begin
			    $display("[FREEQ] %m p%0d pushed while already queued", push0_val);
			 end
		       if(push1 && (entry(n_ret_head + (LG_Q+1)'(i)) == push1_val))
			 begin
			    $display("[FREEQ] %m p%0d pushed while already queued", push1_val);
			 end
		    end
	       end
	     if(push0 && push1 && (push0_val == push1_val))
	       begin
		  $display("[FREEQ] %m p%0d pushed twice in one cycle", push0_val);
	       end
	     if((r_tail - r_ret_head) > (LG_Q+1)'(Q))
	       begin
		  $display("[FREEQ] %m %0d live entries, more than %0d", r_tail - r_ret_head, Q);
	       end
	     if(pop && empty)
	       begin
		  $display("[FREEQ] %m pop while empty");
	       end
	     if(pop && recover && (r_head != r_ret_head))
	       begin
		  $display("[FREEQ] %m pop in a recovery cycle with in-flight entries");
	       end
	  end
     end // always_ff@ (negedge clk)
`endif

endmodule // free_fifo
