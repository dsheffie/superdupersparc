/* The PMU: rd %asr16/17 = cycles [31:0]/[63:32], rd %asr18/19 = retired
 * instructions [31:0]/[63:32] (decode_sparc.sv S_RDASR).  A 64-bit value is
 * read hi, lo, hi, retrying if the high word changed.  Checks that both
 * counts advance, that a loop of known length retires about that many
 * instructions (the reads execute speculatively, so within a ROB's worth),
 * that %g0 destinations and the %y/stbar neighbours still behave, and that
 * the counts are below 2^32 this early.  The co-sim checker takes the RTL's
 * counter values (top.cc), so a wrong count shows up only through these
 * checks: a failure spins at `fail` (rtl_regress: no clean end).
 * Bare metal, supervisor, ET=0, like wiggle.S.  Ends with `ta 0`. */
#define LOOPS 1000			/* 3 instructions each */
#define SLACK 64			/* more than the ROB holds in flight */

#define READ64(hi, lo, rhi, rlo, tmp)	\
9:	rd	hi, rhi;		\
	rd	lo, rlo;		\
	rd	hi, tmp;		\
	cmp	rhi, tmp;		\
	bne	9b;			\
	 nop

	.text
	.globl _start
_start:
	wr	%g0, 0x5a, %y
	nop
	nop
	nop
	rd	%asr16, %g0		/* rd = %g0: no write */
	rd	%asr18, %g0
	READ64(%asr17, %asr16, %l0, %l1, %g1)	/* cycles c0 */
	READ64(%asr19, %asr18, %l2, %l3, %g1)	/* instructions i0 */
	set	LOOPS, %o0
1:	subcc	%o0, 1, %o0
	bne	1b
	 add	%o1, 1, %o1
	READ64(%asr19, %asr18, %l6, %l7, %g1)	/* instructions i1 */
	READ64(%asr17, %asr16, %l4, %l5, %g1)	/* cycles c1 */
	/* early in the run both counts fit in 32 bits */
	orcc	%l0, %l2, %g0
	bne	fail
	 nop
	orcc	%l4, %l6, %g0
	bne	fail
	 nop
	/* the loop took more cycles than it has iterations */
	sub	%l5, %l1, %o2
	set	LOOPS, %o3
	cmp	%o2, %o3
	bleu	fail
	 nop
	/* it retired 3 * LOOPS instructions, give or take what was in flight */
	sub	%l7, %l3, %o2
	set	3 * LOOPS - SLACK, %o3
	cmp	%o2, %o3
	blu	fail
	 nop
	set	3 * LOOPS + SLACK, %o3
	cmp	%o2, %o3
	bgu	fail
	 nop
	/* %y and stbar are unchanged by the new rs1 values */
	rd	%y, %o4
	cmp	%o4, 0x5a
	bne	fail
	 nop
	rd	%asr1, %o4		/* rs1 1-14: reads %y (as qemu) */
	cmp	%o4, 0x5a
	bne	fail
	 nop
	stbar
	ta	0
fail:	b	fail
	 nop
