`include "machine.vh"
`include "rob.vh"
`include "uop.vh"

/* unit-test wrapper: decode_sparc with the uop fields tb_decode_sparc.cc checks
 * broken out as plain ports */
module tb_decode_sparc(
		       s,
		       et,
		       ef,
		       cwp,
		       wim,
		       insn,
		       op,
		       is_ii,
		       is_nop,
		       is_ldd,
		       is_wrpsr,
		       srcA,
		       srcA_valid,
		       fp_srcA_valid,
		       srcB,
		       srcB_valid,
		       fp_srcB_valid,
		       srcC,
		       srcC_valid,
		       fp_srcC_valid,
		       dst,
		       dst_valid,
		       dst2,
		       srcD,
		       srcD_valid,
		       is_std,
		       dst2_valid,
		       fp_dst_valid,
		       fcr_src_valid,
		       fcr_dst_valid,
		       hilo_src_valid,
		       hilo_dst_valid,
		       flags_src_valid,
		       flags_dst_valid,
		       cond,
		       imm32,
		       asi,
		       has_delay_slot,
		       has_nullifying_delay_slot,
		       serializing_op,
		       is_mem,
		       is_store,
		       next_cwp);
   input logic			s;
   input logic			et;
   input logic			ef;
   input logic [`LG_NWINDOWS-1:0] cwp;
   input logic [`NWINDOWS-1:0]	wim;
   input logic [31:0]		insn;
   output logic [8:0]		op;
   output logic			is_ii;
   output logic			is_nop;
   output logic			is_ldd;
   output logic			is_wrpsr;
   output logic [`LG_PRF_ENTRIES-1:0] srcA;
   output logic			srcA_valid;
   output logic			fp_srcA_valid;
   output logic [`LG_PRF_ENTRIES-1:0] srcB;
   output logic			srcB_valid;
   output logic			fp_srcB_valid;
   output logic [`LG_PRF_ENTRIES-1:0] srcC;
   output logic			srcC_valid;
   output logic			fp_srcC_valid;
   output logic [`LG_PRF_ENTRIES-1:0] dst;
   output logic			dst_valid;
   output logic [`LG_PRF_ENTRIES-1:0] dst2;
   output logic [`LG_PRF_ENTRIES-1:0] srcD;
   output logic			srcD_valid;
   output logic			is_std;
   output logic			dst2_valid;
   output logic			fp_dst_valid;
   output logic			fcr_src_valid;
   output logic			fcr_dst_valid;
   output logic			hilo_src_valid;
   output logic			hilo_dst_valid;
   output logic			flags_src_valid;
   output logic			flags_dst_valid;
   output logic [3:0]		cond;
   output logic [31:0]		imm32;
   output logic [7:0]		asi;
   output logic			has_delay_slot;
   output logic			has_nullifying_delay_slot;
   output logic			serializing_op;
   output logic			is_mem;
   output logic			is_store;
   output logic [`LG_NWINDOWS-1:0] next_cwp;

   uop_t uop;

   decode_sparc dec(
		    .s(s),
		    .et(et),
		    .ef(ef),
		    .cwp(cwp),
		    .wim(wim),
		    .irq(1'b0),
		    .iacc_exc(1'b0),
		    .iacc_mmu('0), .irq_level(4'd0),
		    .xflush(1'b0), .xflush_op(II),
		    .iacc_err(1'b0),
		    .insn(insn),
		    .pc('d0),
		    .insn_pred(1'b0),
		    .bpu_idx('d0),
		    .insn_pred_target('d0),
`ifdef ENABLE_CYCLE_ACCOUNTING
		    .fetch_cycle('d0),
`endif
		    .uop(uop),
		    .next_cwp(next_cwp));

   always_comb
     begin
	op = uop.op;
	is_ii = (uop.op == II);
	is_nop = (uop.op == NOP);
	is_ldd = (uop.op == LD);
	is_wrpsr = (uop.op == S_WRPSR);
	srcA = uop.srcA;
	srcA_valid = uop.srcA_valid;
	fp_srcA_valid = uop.fp_srcA_valid;
	srcB = uop.srcB;
	srcB_valid = uop.srcB_valid;
	fp_srcB_valid = uop.fp_srcB_valid;
	srcC = uop.srcC;
	srcC_valid = uop.srcC_valid;
	fp_srcC_valid = uop.fp_srcC_valid;
	dst = uop.dst;
	dst_valid = uop.dst_valid;
	dst2 = uop.dst2;
	srcD = uop.srcD;
	srcD_valid = uop.srcD_valid;
	is_std = (uop.op == SD);
	dst2_valid = uop.dst2_valid;
	fp_dst_valid = uop.fp_dst_valid;
	fcr_src_valid = uop.fcr_src_valid;
	fcr_dst_valid = uop.fcr_dst_valid;
	hilo_src_valid = uop.hilo_src_valid;
	hilo_dst_valid = uop.hilo_dst_valid;
	flags_src_valid = uop.flags_src_valid;
	flags_dst_valid = uop.flags_dst_valid;
	cond = uop.cond;
	imm32 = {uop.jmp_imm[15:0], uop.imm};
	asi = uop.asi;
	has_delay_slot = uop.has_delay_slot;
	has_nullifying_delay_slot = uop.has_nullifying_delay_slot;
	serializing_op = uop.serializing_op;
	is_mem = uop.is_mem;
	is_store = uop.is_store;
     end // always_comb

endmodule // tb_decode_sparc
