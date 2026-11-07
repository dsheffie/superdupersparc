`include "machine.vh"
`include "rob.vh"
`include "uop.vh"

/* SPARC V8 decode: one instruction -> one uop (uop.vh S_* conventions).
 *
 * Register windows (SPARC_V8_PLAN.md section 2, the naive scheme): every integer
 * specifier leaves decode as a flat architectural index,
 *   r0..r7  -> 0..7,   r8..r31 -> 8 + ((r - 8) + 16*CWP) mod (16*NWINDOWS)
 * the same mapping as interpret.hh widx().  cwp is the decode-time (speculative)
 * window; next_cwp is the window the NEXT instruction decodes in, so the second
 * decoder of a pair chains off the first.  SAVE/RESTORE read their sources in the
 * old window and write rd in the new one.  WIM is stable at decode (WRWIM
 * serializes), so a SAVE/RESTORE whose new window is invalid becomes a decode
 * fault here, as does RETT's.
 *
 * Decode-time traps (illegal / privileged / fp_disabled / cp_disabled / window
 * overflow+underflow, and the fetch faults) leave as op II with the trap type in
 * imm[7:0].  The checks and their order follow interpret.cc execSparc exactly
 * (tb_decode_sparc.cc holds the two to that).  Operand-dependent traps (alignment,
 * tag overflow, division by zero, Ticc, WRPSR's CWP range, the FP exceptions) are
 * the execution units'.
 *
 * Not yet handled here: the jmpl;rett
 * couple, and every other DCTI couple. */
/* the ASIs that reach memory: 8/9 user/supervisor instruction, 0xa/0xb
 * user/supervisor data (translated), 0x20-0x2f MMU bypass (interpret.cc
 * asi_is_memory) */
function automatic logic asi_is_memory(input logic [7:0] asi);
   asi_is_memory = (asi == 8'h08) | (asi == 8'h09) | (asi == 8'h0a) | (asi == 8'h0b) | (asi[7:4] == 4'h2);
endfunction

module decode_sparc(
		    s,
		    et,
		    ef,
		    cwp,
		    wim,
		    irq,
		    irq_level,
		    iacc_exc,
		    iacc_mmu,
		    iacc_err,
		    insn,
		    pc,
		    insn_pred,
		    bpu_idx,
		    insn_pred_target,
`ifdef ENABLE_CYCLE_ACCOUNTING
		    fetch_cycle,
`endif
		    uop,
		    next_cwp);
   input logic			s;     /* PSR.S */
   input logic			et;    /* PSR.ET */
   input logic			ef;    /* PSR.EF */
   input logic [`LG_NWINDOWS-1:0] cwp;
   input logic [`NWINDOWS-1:0]	wim;
   input logic			irq;
   input logic [3:0]		irq_level;   /* with irq: the interrupt level taken (1..15) */
   input logic			iacc_exc;   /* instruction_access_exception (MMU fault on fetch) */
   input 			mmu_fault_t iacc_mmu;   /* its fault status fields (for the trap) */
   input logic			iacc_err;   /* instruction_access_error (bus error on fetch) */
   input logic [31:0]		insn;
   input logic [`M_WIDTH-1:0]	pc;
   input logic			insn_pred;
   input logic [`LG_BPU_TBL_SZ-1:0] bpu_idx;
   input logic [`M_WIDTH-1:0]	insn_pred_target;
`ifdef ENABLE_CYCLE_ACCOUNTING
   input logic [63:0]		fetch_cycle;
`endif
   output			uop_t uop;
   output logic [`LG_NWINDOWS-1:0] next_cwp;

   localparam LG_NW = `LG_NWINDOWS;
   localparam ARCH_REGS = 8 + 16 * `NWINDOWS;

   /* trap types (interpret.hh trap_type) */
   localparam logic [7:0] TT_IACCESS = 8'h01;
   localparam logic [7:0] TT_ILLEGAL = 8'h02;
   localparam logic [7:0] TT_PRIVILEGED = 8'h03;
   localparam logic [7:0] TT_FP_DISABLED = 8'h04;
   localparam logic [7:0] TT_WIN_OVERFLOW = 8'h05;
   localparam logic [7:0] TT_WIN_UNDERFLOW = 8'h06;
   localparam logic [7:0] TT_IACCESS_ERROR = 8'h21;
   localparam logic [7:0] TT_CP_DISABLED = 8'h24;
   localparam logic [7:0] TT_FP_EXCEPTION = 8'h08;

   generate
      if((1 << `LG_PRF_ENTRIES) < ARCH_REGS)
	begin
	   $error("decode_sparc: LG_PRF_ENTRIES too small for the windowed arch registers");
	end
      if(`M_WIDTH < 32)
	begin
	   $error("decode_sparc: M_WIDTH must be at least 32");
	end
   endgenerate

   /* flat arch index of r in window w (interpret.hh widx); the (LG_NW+4)-bit sum
    * wraps mod 16*NWINDOWS by itself */
   function automatic logic [`LG_PRF_ENTRIES-1:0] widx(input logic [LG_NW-1:0] w, input logic [4:0] r);
      logic [LG_NW+3:0] t;
      begin
	 t = {w, 4'b0000} + {{(LG_NW-1){1'b0}}, r - 5'd8};
	 if(r < 5'd8)
	   begin
	      widx = {{(`LG_PRF_ENTRIES-5){1'b0}}, r};
	   end
	 else
	   begin
	      widx = 'd8 + {{(`LG_PRF_ENTRIES-LG_NW-4){1'b0}}, t};
	   end
      end
   endfunction // widx

   /* FP register r (5-bit field) as an FP arch index: the 64-bit pair holding it.
    * d[2k] is f[2k] (the high word) : f[2k+1] (the low word), so a single is half
    * of a pair and a double's low bit is ignored.  Only the even arch indices are
    * used. */
   function automatic logic [`LG_PRF_ENTRIES-1:0] fidx(input logic [4:0] r);
      begin
	 fidx = {{(`LG_PRF_ENTRIES-5){1'b0}}, r[4:1], 1'b0};
      end
   endfunction // fidx

   /* which part of its pair an FP operand is (exec.sv FP issue, in jmp_imm):
    * FSEL_FULL a double, FSEL_LO / FSEL_HI a single (f[2k+1] / f[2k]) */
   localparam logic [1:0] FSEL_FULL = 2'd0;
   localparam logic [1:0] FSEL_LO = 2'd1;
   localparam logic [1:0] FSEL_HI = 2'd2;
   function automatic logic [1:0] fsel(input logic [4:0] r, input logic dbl);
      begin
	 fsel = dbl ? FSEL_FULL : (r[0] ? FSEL_LO : FSEL_HI);
      end
   endfunction // fsel

   wire [1:0]			op = insn[31:30];
   wire [2:0]			op2 = insn[24:22];
   wire [5:0]			op3 = insn[24:19];
   wire [4:0]			rd = insn[29:25];
   wire [4:0]			rs1 = insn[18:14];
   wire [4:0]			rs2 = insn[4:0];
   wire				i = insn[13];
   wire [3:0]			cond = insn[28:25];
   wire				annul = insn[29];
   wire [8:0]			opf = insn[13:5];

   wire [LG_NW-1:0]		w_cwp_save = cwp - 'd1;
   wire [LG_NW-1:0]		w_cwp_restore = cwp + 'd1;
   wire				w_wim_save = wim[w_cwp_save];
   wire				w_wim_restore = wim[w_cwp_restore];

   wire [`LG_PRF_ENTRIES-1:0]	w_rs1 = widx(cwp, rs1);
   wire [`LG_PRF_ENTRIES-1:0]	w_rs2 = widx(cwp, rs2);
   wire [`LG_PRF_ENTRIES-1:0]	w_rd = widx(cwp, rd);
   wire [`LG_PRF_ENTRIES-1:0]	w_rd_save = widx(w_cwp_save, rd);
   wire [`LG_PRF_ENTRIES-1:0]	w_rd_restore = widx(w_cwp_restore, rd);
   wire [`LG_PRF_ENTRIES-1:0]	w_o7 = widx(cwp, 5'd15);
   wire [`LG_PRF_ENTRIES-1:0]	w_rd_num = {{(`LG_PRF_ENTRIES-5){1'b0}}, rd};

   /* operand 2 is a register only for i=0 with rs2 != %g0: `rs1 + %g0' becomes
    * `rs1 + 0' (no read of the zero register) */
   wire				w_op2_reg = !i & (rs2 != 5'd0);
   /* cond ba/bn (and Ticc ta/tn) do not look at the condition codes */
   wire				w_cond_reads_cc = (cond[2:0] != 3'd0);
   /* op=2 ALU icc writers (the cc forms, 0x10-0x1f, and the tagged 0x20-0x23)
    * and readers (addx/subx and their cc forms) */
   wire				w_alu_icc_wr = op3[4] | (op3[5:2] == 4'b1000);
   wire				w_alu_icc_rd = (op3 == 6'h08) | (op3 == 6'h0c) | (op3 == 6'h18) | (op3 == 6'h1c);

   logic [31:0]			t_imm32;
   always_comb
     begin
	if(op == 2'd1)
	  begin
	     t_imm32 = {insn[29:0], 2'b00};
	  end
	else if((op == 2'd0) && (op2 == 3'd4))
	  begin
	     t_imm32 = {insn[21:0], 10'd0};
	  end
	else if(op == 2'd0)
	  begin
	     t_imm32 = {{8{insn[21]}}, insn[21:0], 2'b00};
	  end
	else
	  begin
	     t_imm32 = i ? {{19{insn[12]}}, insn[12:0]} : 32'd0;
	  end
     end // always_comb

   /* {jmp_imm, imm} holds the immediate sign-extended to M_WIDTH */
   wire [`M_WIDTH-17:0]		w_imm_hi;
   generate
      if(`M_WIDTH > 32)
	begin
	   assign w_imm_hi = {{(`M_WIDTH-32){t_imm32[31]}}, t_imm32[31:16]};
	end
      else
	begin
	   assign w_imm_hi = t_imm32[31:16];
	end
   endgenerate

   /* the integer ALU ops of op=2, op3 0x00-0x1f (illegal encodings: II) */
   function automatic opcode_t alu_op(input logic [5:0] o);
      begin
	 case(o)
	   6'h00: alu_op = S_ADD;
	   6'h01: alu_op = S_AND;
	   6'h02: alu_op = S_OR;
	   6'h03: alu_op = S_XOR;
	   6'h04: alu_op = S_SUB;
	   6'h05: alu_op = S_ANDN;
	   6'h06: alu_op = S_ORN;
	   6'h07: alu_op = S_XNOR;
	   6'h08: alu_op = S_ADDX;
	   6'h0a: alu_op = S_UMUL;
	   6'h0b: alu_op = S_SMUL;
	   6'h0c: alu_op = S_SUBX;
	   6'h0e: alu_op = S_UDIV;
	   6'h0f: alu_op = S_SDIV;
	   6'h10: alu_op = S_ADDCC;
	   6'h11: alu_op = S_ANDCC;
	   6'h12: alu_op = S_ORCC;
	   6'h13: alu_op = S_XORCC;
	   6'h14: alu_op = S_SUBCC;
	   6'h15: alu_op = S_ANDNCC;
	   6'h16: alu_op = S_ORNCC;
	   6'h17: alu_op = S_XNORCC;
	   6'h18: alu_op = S_ADDXCC;
	   6'h1a: alu_op = S_UMULCC;
	   6'h1b: alu_op = S_SMULCC;
	   6'h1c: alu_op = S_SUBXCC;
	   6'h1e: alu_op = S_UDIVCC;
	   6'h1f: alu_op = S_SDIVCC;
	   6'h20: alu_op = S_TADDCC;
	   6'h21: alu_op = S_TSUBCC;
	   6'h22: alu_op = S_TADDCCTV;
	   6'h23: alu_op = S_TSUBCCTV;
	   6'h25: alu_op = S_SLL;
	   6'h26: alu_op = S_SRL;
	   6'h27: alu_op = S_SRA;
	   default: alu_op = II;
	 endcase // case (o)
      end
   endfunction // alu_op

   /* FPop1 (op3 0x34) by opf; anything else (quad, reserved) is FP_UNIMPL, which
    * the FPU answers with an unimplemented_FPop fp_exception */
   function automatic opcode_t fpop1_op(input logic [8:0] f);
      begin
	 case(f)
	   9'h001: fpop1_op = SP_MOV;
	   9'h005: fpop1_op = SP_NEG;
	   9'h009: fpop1_op = SP_ABS;
	   9'h029: fpop1_op = SP_SQRT;
	   9'h02a: fpop1_op = DP_SQRT;
	   9'h041: fpop1_op = SP_ADD;
	   9'h042: fpop1_op = DP_ADD;
	   9'h045: fpop1_op = SP_SUB;
	   9'h046: fpop1_op = DP_SUB;
	   9'h049: fpop1_op = SP_MUL;
	   9'h04a: fpop1_op = DP_MUL;
	   9'h04d: fpop1_op = SP_DIV;
	   9'h04e: fpop1_op = DP_DIV;
	   9'h069: fpop1_op = S_FSMULD;
	   9'h0c4: fpop1_op = CVT_S_W;    /* fitos */
	   9'h0c8: fpop1_op = CVT_D_W;    /* fitod */
	   9'h0c9: fpop1_op = CVT_D_S;    /* fstod */
	   9'h0c6: fpop1_op = CVT_S_D;    /* fdtos */
	   9'h0d1: fpop1_op = TRUNC_W_S;  /* fstoi */
	   9'h0d2: fpop1_op = TRUNC_W_D;  /* fdtoi */
	   default: fpop1_op = FP_UNIMPL;
	 endcase // case (f)
      end
   endfunction // fpop1_op

   /* FPop1 shapes: which operands are doubles, and whether rs1 is read */
   wire				w_fp_src_dbl = (opf == 9'h02a) | (opf == 9'h042) | (opf == 9'h046) |
				(opf == 9'h04a) | (opf == 9'h04e) | (opf == 9'h0c6) | (opf == 9'h0d2);
   wire				w_fp_dst_dbl = (opf == 9'h02a) | (opf == 9'h042) | (opf == 9'h046) |
				(opf == 9'h04a) | (opf == 9'h04e) | (opf == 9'h069) | (opf == 9'h0c8) |
				(opf == 9'h0c9);
   wire				w_fp_unary = (opf == 9'h001) | (opf == 9'h005) | (opf == 9'h009) |
				(opf == 9'h029) | (opf == 9'h02a) | (opf[8:4] == 5'h0c) | (opf[8:4] == 5'h0d);
   wire				w_fcmp_dbl = (opf == 9'h052) | (opf == 9'h056);
   wire				w_fcmp = (opf == 9'h051) | (opf == 9'h052) | (opf == 9'h055) | (opf == 9'h056);

   /* op=3 */
   wire				w_mem_int = (op3[5] == 1'b0);
   wire				w_mem_alt = w_mem_int & op3[4];
   wire [3:0]			w_mem_base = op3[3:0];

   always_comb
     begin
	uop.op = II;
`ifdef VERILATOR
	uop.raw_insn = insn;
	uop.clear_id = 'd0;
`endif
`ifdef ENABLE_EXC_RING
	uop.insn = insn;
`endif
	uop.srcA = 'd0;
	uop.srcB = 'd0;
	uop.dst = 'd0;
	uop.srcA_valid = 1'b0;
	uop.srcB_valid = 1'b0;
	uop.fp_srcA_valid = 1'b0;
	uop.fp_srcB_valid = 1'b0;
	uop.srcC = 'd0;
	uop.srcC_valid = 1'b0;
	uop.fp_srcC_valid = 1'b0;
	uop.fcr_src_valid = 1'b0;
	uop.hilo_dst_valid = 1'b0;
	uop.hilo_src_valid = 1'b0;
	uop.hilo_dst = 'd0;
	uop.hilo_src = 'd0;
	uop.dst_valid = 1'b0;
	uop.fp_dst_valid = 1'b0;
	uop.fcr_dst_valid = 1'b0;
	uop.flags_src_valid = 1'b0;
	uop.flags_dst_valid = 1'b0;
	uop.cond = 4'd0;
	uop.dst2 = 'd0;
	uop.dst2_valid = 1'b0;
	uop.srcD = 'd0;
	uop.srcD_valid = 1'b0;
	uop.is_call = 1'b0;
	uop.is_ret = 1'b0;
	uop.is_fp = 1'b0;
	uop.has_delay_slot = 1'b0;
	uop.has_nullifying_delay_slot = 1'b0;
	uop.imm = t_imm32[15:0];
	uop.jmp_imm = w_imm_hi;
	uop.pc = pc;
	uop.pred_target = insn_pred_target;
	uop.serializing_op = 1'b0;
	uop.must_restart = 1'b0;
	uop.oldest_first = 1'b0;
	uop.rob_ptr = 'd0;
	uop.br_pred = 1'b0;
	uop.is_br = 1'b0;
	uop.bpu_idx = bpu_idx;
	uop.is_mem = 1'b0;
	uop.is_int = 1'b0;
	uop.is_store = 1'b0;
	uop.is_cache = 1'b0;
	uop.cache_act = CA_NONE;
	uop.asi = s ? 8'h0b : 8'h0a;
	uop.mmu = '0;
`ifdef ENABLE_CYCLE_ACCOUNTING
	uop.fetch_cycle = fetch_cycle;
`endif
	next_cwp = cwp;

	/* `trap(tt)': op stays II, the trap type rides imm */
	if(irq)
	  begin
	     /* an external interrupt: the instruction does not execute; it traps
	      * like a decode trap with tt = interrupt_level_n (0x10 + n), so PC/nPC
	      * are its own -- the precise SPARC interrupt point */
	     uop.op = II;
	     uop.imm = {8'd0, 4'h1, irq_level};
	  end
	else if(iacc_exc)
	  begin
	     uop.imm = {8'd0, TT_IACCESS};
	     uop.mmu = iacc_mmu;
	  end
	else if(iacc_err)
	  begin
	     uop.imm = {8'd0, TT_IACCESS_ERROR};
	  end
	else
	  begin
	     case(op)
	       2'd0:
		 begin
		    if(op2 == 3'd4) /* sethi; any sethi to %g0 is a nop */
		      begin
			 uop.op = (rd == 5'd0) ? NOP : S_SETHI;
			 uop.dst = w_rd;
			 uop.dst_valid = (rd != 5'd0);
			 uop.is_int = 1'b1;
		      end
		    else if(op2 == 3'd7) /* CBccc */
		      begin
			 uop.imm = {8'd0, TT_CP_DISABLED};
		      end
		    else if((op2 != 3'd2) && (op2 != 3'd6)) /* unimp + the V9 encodings */
		      begin
			 uop.imm = {8'd0, TT_ILLEGAL};
		      end
		    else if((op2 == 3'd6) && !ef)
		      begin
			 uop.imm = {8'd0, TT_FP_DISABLED};
		      end
		    else if((cond == 4'd0) && !annul) /* bn / fbn: the delay slot just runs */
		      begin
			 uop.op = NOP;
			 uop.is_int = 1'b1;
		      end
		    else
		      begin
			 uop.op = (op2 == 3'd2) ? S_BICC : S_FBFCC;
			 uop.cond = cond;
			 uop.flags_src_valid = (op2 == 3'd2) & w_cond_reads_cc;
			 uop.srcC_valid = (op2 == 3'd2) & w_cond_reads_cc;
			 uop.fcr_src_valid = (op2 == 3'd6) & w_cond_reads_cc;
			 uop.br_pred = insn_pred;
			 uop.is_br = 1'b1;
			 uop.is_int = 1'b1;
			 if(cond == 4'd8)
			   begin
			      /* ba: always taken; ba,a also annuls the slot -- a jump
			       * with no delay slot */
			      uop.has_delay_slot = !annul;
			   end
			 else if(cond == 4'd0)
			   begin
			      /* bn,a: never taken and the slot annulled == an always-
			       * taken jump to pc+8 with no delay slot */
			      uop.op = S_BICC;
			      uop.cond = 4'd8;
			      uop.imm = 16'd8;
			      uop.jmp_imm = 'd0;
			   end
			 else
			   begin
			      /* conditional: a=1 annuls the slot when not taken, which
			       * is MIPS branch-likely */
			      uop.has_delay_slot = 1'b1;
			      uop.has_nullifying_delay_slot = annul;
			   end
		      end
		 end // case: 2'd0
	       2'd1: /* call */
		 begin
		    uop.op = S_CALL;
		    uop.is_call = 1'b1;
		    uop.dst = w_o7;
		    uop.dst_valid = 1'b1;
		    uop.has_delay_slot = 1'b1;
		    uop.br_pred = 1'b1;
		    uop.is_br = 1'b1;
		    uop.is_int = 1'b1;
		 end
	       2'd2:
		 begin
		    /* the common shape: rd = rs1 op operand 2 */
		    uop.srcA = w_rs1;
		    uop.srcA_valid = 1'b1;
		    uop.srcB = w_rs2;
		    uop.srcB_valid = w_op2_reg;
		    uop.dst = w_rd;
		    uop.dst_valid = (rd != 5'd0);
		    uop.is_int = 1'b1;
		    if(op3 <= 6'h27 && op3 != 6'h24)
		      begin
			 uop.op = alu_op(op3);
			 if(uop.op == II)
			   begin
			      uop.imm = {8'd0, TT_ILLEGAL};
			      uop.is_int = 1'b0;
			      uop.srcA_valid = 1'b0;
			      uop.srcB_valid = 1'b0;
			      uop.dst_valid = 1'b0;
			   end
			 else
			   begin
			      /* icc rides in the dst register: a cc op to %g0 (cmp,
			       * tst) still has one */
			      uop.flags_dst_valid = w_alu_icc_wr;
			      uop.dst_valid = (rd != 5'd0) | w_alu_icc_wr;
			      uop.flags_src_valid = w_alu_icc_rd;
			      uop.srcC_valid = w_alu_icc_rd;
			      /* Y: written by the multiplies, read by the divides */
			      uop.hilo_dst_valid = (op3[5] == 1'b0) & (op3[3:1] == 3'b101);
			      uop.hilo_src_valid = (op3[5] == 1'b0) & (op3[3:1] == 3'b111);
			      /* no side effect but rd: rd=%g0 is a nop (not the multiplies,
			       * which write Y, nor the divides, which can trap) */
			      if((rd == 5'd0) && (op3[4] == 1'b0) && (op3[5:2] != 4'b1000) &&
				 (op3[3:1] != 3'b101) && (op3[3:1] != 3'b111))
				begin
				   uop.op = NOP;
				   uop.srcA_valid = 1'b0;
				   uop.srcB_valid = 1'b0;
				   uop.flags_src_valid = 1'b0;   /* addx/subx %g0 */
				   uop.srcC_valid = 1'b0;
				end
			   end // else: !if(uop.op == II)
		      end // if (op3 <= 6'h27 && op3 != 6'h24)
		    else
		      begin
			 case(op3)
			   6'h24: /* mulscc: rd, Y and icc in, rd, Y and icc out */
			     begin
				uop.op = S_MULSCC;
				uop.dst_valid = 1'b1;
				uop.flags_src_valid = 1'b1;
				uop.srcC_valid = 1'b1;
				uop.flags_dst_valid = 1'b1;
				uop.hilo_src_valid = 1'b1;
				uop.hilo_dst_valid = 1'b1;
			     end
			   6'h28: /* rdy / stbar / rdasr */
			     begin
				uop.srcA_valid = 1'b0;
				uop.srcB_valid = 1'b0;
				/* as qemu sparc32 (non-LEON) and interpret.cc: rs1 = 15 is stbar
				 * whatever rd is, every other rs1 (rdasr) reads %y */
				if(rs1 == 5'd15)
				  begin
				     uop.op = NOP;   /* stbar: memory is TSO here */
				  end
				else
				  begin
				     uop.op = (rd == 5'd0) ? NOP : S_RDY;
				     uop.hilo_src_valid = (rd != 5'd0);
				  end
			     end
			   6'h29, 6'h2a, 6'h2b: /* rdpsr rdwim rdtbr */
			     begin
				uop.srcA_valid = 1'b0;
				uop.srcB_valid = 1'b0;
				if(!s)
				  begin
				     uop.op = II;
				     uop.imm = {8'd0, TT_PRIVILEGED};
				     uop.is_int = 1'b0;
				     uop.dst_valid = 1'b0;
				  end
				else
				  begin
				     uop.op = (op3 == 6'h29) ? S_RDPSR : (op3 == 6'h2a) ? S_RDWIM : S_RDTBR;
				     uop.flags_src_valid = (op3 == 6'h29);   /* PSR.icc */
				     uop.srcC_valid = (op3 == 6'h29);
				     /* RDPSR: the CWP it reads is this decode-time one (older
				      * SAVE/RESTOREs may not have retired when it executes) */
				     uop.imm = {{(16-LG_NW){1'b0}}, cwp};
				     uop.jmp_imm = 'd0;
				  end
			     end
			   6'h30: /* wry / wrasr: rs1 xor operand 2 */
			     begin
				uop.dst_valid = 1'b0;
				if(rd == 5'd0)
				  begin
				     uop.op = S_WRY;
				     uop.hilo_dst_valid = 1'b1;
				  end
				else
				  begin
				     /* wr %asrN, N != 0: a nop (qemu sparc32 non-LEON, interpret.cc) */
				     uop.op = NOP;
				     uop.srcA_valid = 1'b0;
				     uop.srcB_valid = 1'b0;
				  end
			     end
			   6'h31, 6'h32, 6'h33: /* wrpsr wrwim wrtbr */
			     begin
				uop.dst_valid = 1'b0;
				if(!s)
				  begin
				     uop.op = II;
				     uop.imm = {8'd0, TT_PRIVILEGED};
				     uop.is_int = 1'b0;
				     uop.srcA_valid = 1'b0;
				     uop.srcB_valid = 1'b0;
				  end
				else
				  begin
				     uop.op = (op3 == 6'h31) ? S_WRPSR : (op3 == 6'h32) ? S_WRWIM : S_WRTBR;
				     uop.serializing_op = 1'b1;
				     /* WRPSR writes icc: into a register of its own (dst %g0) */
				     uop.flags_dst_valid = (op3 == 6'h31);
				     uop.dst_valid = (op3 == 6'h31);
				     uop.dst = 'd0;
				  end
			     end
			   6'h34, 6'h35: /* FPop1 FPop2 */
			     begin
				uop.srcA_valid = 1'b0;
				uop.srcB_valid = 1'b0;
				uop.dst_valid = 1'b0;
				uop.is_int = 1'b0;
				if(!ef)
				  begin
				     uop.op = II;
				     uop.imm = {8'd0, TT_FP_DISABLED};
				  end
				else if(op3 == 6'h35)
				  begin
				     uop.is_fp = 1'b1;
				     if(w_fcmp)
				       begin
					  uop.op = w_fcmp_dbl ? S_FCMPD : S_FCMPS;
					  uop.imm = {9'd0, opf[2], 6'd0};   /* fpu_compare cond[3]: fcmpe signals on any NaN */
					  uop.jmp_imm = 'd0;
					  uop.jmp_imm[2:1] = fsel(rs1, w_fcmp_dbl);
					  uop.jmp_imm[4:3] = fsel(rs2, w_fcmp_dbl);
					  uop.srcA = fidx(rs1);
					  uop.fp_srcA_valid = 1'b1;
					  uop.srcB = fidx(rs2);
					  uop.fp_srcB_valid = 1'b1;
					  uop.fcr_dst_valid = 1'b1;   /* all of fcc */
				       end
				     else
				       begin
					  /* quad and reserved: unimplemented_FPop (core.sv: ftt 3) */
					  uop.op = II;
					  uop.imm = {8'd0, TT_FP_EXCEPTION};
					  uop.is_fp = 1'b0;
				       end
				  end
				else
				  begin
				     uop.op = fpop1_op(opf);
				     uop.is_fp = 1'b1;
				     if(uop.op == FP_UNIMPL)
				       begin
					  /* quad and reserved: unimplemented_FPop (core.sv: ftt 3) */
					  uop.op = II;
					  uop.imm = {8'd0, TT_FP_EXCEPTION};
					  uop.is_fp = 1'b0;
				       end
				     else
				       begin
					  /* unary ops read rs2; binary rs1 then rs2.  jmp_imm (exec.sv
					   * FP issue): [2:1] / [4:3] srcA / srcB's part of its pair,
					   * [5] a single destination, [0] its half is the high one.  A
					   * single destination writes half a pair: the old pair is
					   * srcC, merged at writeback. */
					  uop.jmp_imm = 'd0;
					  uop.jmp_imm[2:1] = fsel(w_fp_unary ? rs2 : rs1, w_fp_src_dbl);
					  uop.jmp_imm[4:3] = fsel(rs2, w_fp_src_dbl);
					  uop.jmp_imm[5] = !w_fp_dst_dbl;
					  uop.jmp_imm[0] = !rd[0];
					  uop.srcA = w_fp_unary ? fidx(rs2) : fidx(rs1);
					  uop.fp_srcA_valid = 1'b1;
					  uop.srcB = fidx(rs2);
					  uop.fp_srcB_valid = !w_fp_unary;
					  uop.srcC = fidx(rd);
					  uop.fp_srcC_valid = !w_fp_dst_dbl;
					  uop.dst = fidx(rd);
					  uop.fp_dst_valid = 1'b1;
				       end
				  end
			     end
			   6'h36, 6'h37: /* CPop */
			     begin
				uop.op = II;
				uop.imm = {8'd0, TT_CP_DISABLED};
				uop.is_int = 1'b0;
				uop.srcA_valid = 1'b0;
				uop.srcB_valid = 1'b0;
				uop.dst_valid = 1'b0;
			     end
			   6'h38: /* jmpl: rd = pc, target rs1 + operand 2 */
			     begin
				uop.op = S_JMPL;
				uop.is_call = (rd == 5'd15);
				uop.is_ret = (rd == 5'd0) & i & (insn[12:0] == 13'd8) &
					     ((rs1 == 5'd31) | (rs1 == 5'd15));
				uop.has_delay_slot = 1'b1;
				uop.br_pred = 1'b1;
				uop.is_br = 1'b1;
			     end
			   6'h39: /* rett */
			     begin
				uop.dst_valid = 1'b0;
				if(et | !s | w_wim_restore)
				  begin
				     uop.op = II;
				     uop.imm = {8'd0, et ? (s ? TT_ILLEGAL : TT_PRIVILEGED) :
						!s ? TT_PRIVILEGED : TT_WIN_UNDERFLOW};
				     uop.is_int = 1'b0;
				     uop.srcA_valid = 1'b0;
				     uop.srcB_valid = 1'b0;
				  end
				else
				  begin
				     uop.op = S_RETT;
				     uop.serializing_op = 1'b1;
				     uop.is_br = 1'b1;
				  end
			     end
			   6'h3a: /* ticc */
			     begin
				uop.dst_valid = 1'b0;
				if(cond == 4'd0)
				  begin
				     uop.op = NOP;   /* tn */
				     uop.srcA_valid = 1'b0;
				     uop.srcB_valid = 1'b0;
				  end
				else
				  begin
				     uop.op = S_TICC;
				     uop.cond = cond;
				     uop.flags_src_valid = w_cond_reads_cc;
				     uop.srcC_valid = w_cond_reads_cc;
				  end
			     end
			   6'h3b: /* flush */
			     begin
				/* the I-cache line at the EA (rs1 + rs2/simm13): a serializing
				 * cache op that invalidates the L1I set the EA indexes, then
				 * restarts -- so code the kernel patches is refetched */
				uop.op = S_FLUSH;
				uop.dst_valid = 1'b0;
				uop.serializing_op = 1'b1;
				uop.is_cache = 1'b1;
				uop.cache_act = CA_I_LINE_INV;
			     end
			   6'h3c: /* save */
			     begin
				if(w_wim_save)
				  begin
				     uop.op = II;
				     uop.imm = {8'd0, TT_WIN_OVERFLOW};
				     uop.is_int = 1'b0;
				     uop.srcA_valid = 1'b0;
				     uop.srcB_valid = 1'b0;
				     uop.dst_valid = 1'b0;
				  end
				else
				  begin
				     uop.op = S_SAVE;
				     uop.dst = w_rd_save;
				     next_cwp = w_cwp_save;
				  end
			     end
			   6'h3d: /* restore */
			     begin
				if(w_wim_restore)
				  begin
				     uop.op = II;
				     uop.imm = {8'd0, TT_WIN_UNDERFLOW};
				     uop.is_int = 1'b0;
				     uop.srcA_valid = 1'b0;
				     uop.srcB_valid = 1'b0;
				     uop.dst_valid = 1'b0;
				  end
				else
				  begin
				     uop.op = S_RESTORE;
				     uop.dst = w_rd_restore;
				     next_cwp = w_cwp_restore;
				  end
			     end
			   default: /* 0x2c-0x2f, 0x3e, 0x3f */
			     begin
				uop.op = II;
				uop.imm = {8'd0, TT_ILLEGAL};
				uop.is_int = 1'b0;
				uop.srcA_valid = 1'b0;
				uop.srcB_valid = 1'b0;
				uop.dst_valid = 1'b0;
			     end
			 endcase // case (op3)
		      end // else: !if(op3 <= 6'h27 && op3 != 6'h24)
		 end // case: 2'd2
	       2'd3: /* loads and stores: address rs1 + operand 2 */
		 begin
		    if(w_mem_alt & !s)
		      begin
			 uop.imm = {8'd0, TT_PRIVILEGED};
		      end
		    else if(w_mem_alt & i)
		      begin
			 uop.imm = {8'd0, TT_ILLEGAL};
		      end
		    else if(!w_mem_int && (op3 >= 6'h30))
		      begin
			 uop.imm = {8'd0, ((op3 <= 6'h37) && (op3 != 6'h32)) ? TT_CP_DISABLED : TT_ILLEGAL};
		      end
		    else if(!w_mem_int && ((op3 == 6'h22) || (op3 >= 6'h28)))
		      begin
			 uop.imm = {8'd0, TT_ILLEGAL};
		      end
		    else if((op3 == 6'h26) && !s) /* stdfq */
		      begin
			 uop.imm = {8'd0, TT_PRIVILEGED};
		      end
		    else if(!w_mem_int && !ef)
		      begin
			 uop.imm = {8'd0, TT_FP_DISABLED};
		      end
		    else if(w_mem_int && ((w_mem_base == 4'h8) || (w_mem_base == 4'hb) ||
					  (w_mem_base == 4'hc) || (w_mem_base == 4'he)))
		      begin
			 uop.imm = {8'd0, TT_ILLEGAL};   /* V9 ldsw/ldx/stx/casa */
		      end
		    else if(w_mem_int && ((w_mem_base == 4'h3) || (w_mem_base == 4'h7)) && rd[0])
		      begin
			 uop.imm = {8'd0, TT_ILLEGAL};   /* ldd/std with an odd rd */
		      end
		    else
		      begin
			 /* the LSU's layout (exec.sv mem pipe): base in srcA, an
			  * index register in srcC (else the immediate), store data
			  * in srcB */
			 uop.srcA = w_rs1;
			 uop.srcA_valid = 1'b1;
			 uop.srcC = w_rs2;
			 uop.srcC_valid = w_op2_reg;
			 uop.is_mem = 1'b1;
			 if(w_mem_alt)
			   begin
			      uop.asi = insn[12:5];
			      /* a non-memory ASI (SRMMU registers and flushes, module
			       * registers, cache diagnostics): alone in the machine, then
			       * the front end restarts, so younger accesses see its effect */
			      if(!asi_is_memory(insn[12:5]))
				begin
				   uop.serializing_op = 1'b1;
				end
			   end
			 if(w_mem_int)
			   begin
			      case(w_mem_base)
				4'h0: uop.op = LW;
				4'h1: uop.op = LBU;
				4'h2: uop.op = LHU;
				4'h3: uop.op = LD;
				4'h4: uop.op = SW;
				4'h5: uop.op = SB;
				4'h6: uop.op = SH;
				4'h7: uop.op = SD;
				4'h9: uop.op = LB;
				4'ha: uop.op = LH;
				4'hd: uop.op = S_LDSTUB;
				4'hf: uop.op = S_SWAP;
				default: uop.op = II;   /* excluded above */
			      endcase // case (w_mem_base)
			      /* stores and swap read rd; loads, ldstub and swap write it.
			       * A load to %g0 still makes its access (faults, devices).
			       * ldd %g0 still writes %g1: its dst stays valid (a register
			       * %g0 leaves unmapped, as a cmp's).  rd is even, so rd+1's
			       * flat index is dst + 1 (no window wrap). */
			      uop.is_store = (w_mem_base[3:2] == 2'b01) | (w_mem_base == 4'hd) | (w_mem_base == 4'hf);
			      uop.srcB = w_rd;
			      uop.srcB_valid = (w_mem_base[3:2] == 2'b01) | (w_mem_base == 4'hf);
			      uop.dst = w_rd;
			      uop.dst_valid = ((rd != 5'd0) | (w_mem_base == 4'h3)) & (w_mem_base[3:2] != 2'b01);
			      uop.dst2 = w_rd + 'd1;
			      uop.dst2_valid = (w_mem_base == 4'h3);
			      uop.srcD = w_rd + 'd1;
			      uop.srcD_valid = (w_mem_base == 4'h7);
			   end
			 else
			   begin
			      /* ldf/stf/lddf/stdf are r9999's lwc1/swc1/ldc1/sdc1 (same
			       * alignment).  A single is half a pair: ldf reads the old pair
			       * (srcB) and merges into the jmp_imm[0] half (1 = the high
			       * word, f[2k]); stf stores that half. */
			      case(op3)
				6'h20: uop.op = LWC1;
				6'h21: uop.op = S_LDFSR;
				6'h23: uop.op = LDC1;
				6'h24: uop.op = SWC1;
				6'h25: uop.op = S_STFSR;
				6'h26: uop.op = S_STDFQ;
				6'h27: uop.op = SDC1;
				default: uop.op = II;   /* excluded above */
			      endcase // case (op3)
			      uop.is_store = op3[2];
			      /* the FSR (and so fcc) and the FP queue move whole: serialize */
			      uop.serializing_op = (op3 == 6'h21) | (op3 == 6'h25) | (op3 == 6'h26);
			      uop.fcr_src_valid = (op3 == 6'h25);
			      uop.fcr_dst_valid = (op3 == 6'h21);
			      uop.jmp_imm = 'd0;
			      uop.jmp_imm[0] = (op3[1:0] == 2'b00) & !rd[0];
			      uop.srcB = fidx(rd);
			      uop.fp_srcB_valid = (op3 == 6'h20) | (op3 == 6'h24) | (op3 == 6'h27);
			      uop.dst = fidx(rd);
			      uop.fp_dst_valid = (op3 == 6'h20) | (op3 == 6'h23);
			   end
		      end
		 end // case: 2'd3
	     endcase // case (op)
	  end
	/* a trap's imm is just the trap type (the arms set imm[7:0] only) */
	if(uop.op == II)
	  begin
	     uop.jmp_imm = 'd0;
	  end
	else if(uop.op == IRQ)
	  begin
	     uop.imm = 16'd0;
	     uop.jmp_imm = 'd0;
	  end
     end // always_comb

endmodule // decode_sparc
