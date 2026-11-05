`include "machine.vh"

/* SPARC V8 branch predecode, computed as a line fills the L1I.  The codes keep
 * the meanings l1i.sv's fetch steering was built on (from the MIPS port):
 *   0  not a control transfer, or one the front end does not steer (bn, bn,a,
 *      rett, Ticc): fetch runs on sequentially
 *   1  conditional Bicc/FBfcc, a=0: the PHT predicts it, the delay slot always runs
 *   2  conditional Bicc/FBfcc, a=1: the slot is annulled when NOT taken (MIPS
 *      branch-likely), so it is always predicted taken
 *   4  jmpl: indirect, target from the BTB / ITT
 *   5  call: direct, target pc + disp30*4, pushes the return stack
 *   6  jmpl with rd = %o7: an indirect call
 *   7  jmpl %i7+8 / %o7+8, rd = %g0 (ret / retl): target from the return stack
 *   8  ba / fba, a=0: always taken, with a delay slot
 *  10  ba,a / fba,a: always taken, the delay slot annulled -- a jump with no
 *      delay slot
 * The direct targets are relative to the branch's own pc (l1i.sv). */
module predecode(insn_, pd);
   input logic [31:0] insn_;
   output logic [3:0] pd;

   logic [31:0]       insn;

   wire [1:0]	      op = insn[31:30];
   wire [2:0]	      op2 = insn[24:22];
   wire [5:0]	      op3 = insn[24:19];
   wire [3:0]	      cond = insn[28:25];
   wire		      annul = insn[29];
   wire [4:0]	      rd = insn[29:25];
   wire [4:0]	      rs1 = insn[18:14];
   wire		      i = insn[13];
   wire [12:0]	      simm13 = insn[12:0];

   always_comb
     begin
	pd = 4'd0;
	insn = bswap32(insn_);
	if(op == 2'd1)
	  begin
	     pd = 4'd5;
	  end
	else if((op == 2'd0) && ((op2 == 3'd2) || (op2 == 3'd6)))
	  begin
	     if(cond == 4'd8)
	       begin
		  pd = annul ? 4'd10 : 4'd8;
	       end
	     else if(cond != 4'd0)
	       begin
		  pd = annul ? 4'd2 : 4'd1;
	       end
	  end
	else if((op == 2'd2) && (op3 == 6'h38))
	  begin
	     if((rd == 5'd0) && i && (simm13 == 13'd8) && ((rs1 == 5'd31) || (rs1 == 5'd15)))
	       begin
		  pd = 4'd7;
	       end
	     else
	       begin
		  pd = (rd == 5'd15) ? 4'd6 : 4'd4;
	       end
	  end
     end // always_comb
endmodule // predecode
