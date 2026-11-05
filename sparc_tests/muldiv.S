/* Multiply / divide / Y on ooo_core: bare metal, supervisor, ET=0 (the reset
 * PSR) like wiggle.S.  Every result lands in a register (the per-retire
 * compare, Y included) and most in memory (the halt-time memory compare).
 * Ends with a divide by zero: with ET=0 that is error mode, which halts both
 * the RTL and the ISS at that udiv.  Build with GNU as (see csmith/run.sh). */
	.text
	.globl _start
_start:
	set	out, %l0
	set	vals, %l1
	/* ---- umul / smul over a table of operand pairs: rd and Y ---- */
	mov	0, %l2
1:	ld	[%l1 + %l2], %o0
	add	%l2, 4, %l3
	and	%l3, 63, %l3
	ld	[%l1 + %l3], %o1
	umul	%o0, %o1, %o2
	rd	%y, %o3
	smul	%o0, %o1, %o4
	rd	%y, %o5
	std	%o2, [%l0]
	std	%o4, [%l0 + 8]
	add	%l0, 16, %l0
	add	%l2, 4, %l2
	cmp	%l2, 64
	bne	1b
	 nop
	/* rd = rs1 (the multiplier reads the old rs1), and rd = %g0: Y only */
	set	0x12345678, %g1
	set	0x9abcdef0, %g2
	umul	%g1, %g2, %g1
	rd	%y, %g3
	smul	%g2, -7, %g0
	rd	%y, %g4
	umul	%g4, 1000, %g5		/* Y from the %g0 multiply is a source here */
	st	%g1, [%l0]
	st	%g3, [%l0 + 4]
	st	%g4, [%l0 + 8]
	st	%g5, [%l0 + 12]
	add	%l0, 16, %l0
	/* ---- the cc forms: N and Z from the low word, V = C = 0 ---- */
	set	0x10000, %o0
	umulcc	%o0, %o0, %o1		/* 2^32: low word 0 -> Z */
	be	2f
	 mov	1, %o2
	mov	2, %o2
2:	smulcc	%o0, -1, %o3		/* negative -> N */
	bneg	3f
	 mov	3, %o4
	mov	4, %o4
3:	subcc	%g0, 1, %g0		/* C = 1 ... */
	umulcc	%o0, 3, %o5		/* ... cleared by the multiply */
	addx	%g0, 0, %g6		/* C into a register: must be 0 */
	st	%o2, [%l0]
	st	%o4, [%l0 + 4]
	st	%g6, [%l0 + 8]
	add	%l0, 16, %l0
	/* ---- wr %y / rd %y ---- */
	set	0xcafe0000, %o0
	wr	%o0, 0xbe, %y
	rd	%y, %o1
	wr	%g0, %y
	rd	%y, %o2
	st	%o1, [%l0]
	st	%o2, [%l0 + 4]
	add	%l0, 16, %l0
	/* ---- divides: {Y, rs1} / operand 2 ---- */
	wr	%g0, %y
	set	1000000, %o0
	udiv	%o0, 7, %o1		/* 142857 */
	wr	%g0, 3, %y
	udiv	%o0, %o0, %o2		/* (3 << 32 | 10^6) / 10^6 */
	set	-1000000, %o3
	mov	-1, %g1
	wr	%g1, %y			/* sign-extended dividend */
	sdiv	%o3, 7, %o4		/* -142857 */
	wr	%g0, %y
	sdiv	%o0, -7, %o5		/* zero-extended: +10^6 / -7 */
	std	%o0, [%l0]
	std	%o2, [%l0 + 8]
	std	%o4, [%l0 + 16]
	add	%l0, 32, %l0
	/* overflow: saturate, and udivcc / sdivcc set V */
	wr	%g0, 9, %y
	udivcc	%g0, 2, %o0		/* 9 << 31 > 2^32 - 1 -> 0xffffffff, V */
	bvs	4f
	 mov	5, %o1
	mov	6, %o1
4:	set	0x7fffffff, %g1
	wr	%g1, %y
	sdivcc	%g0, 1, %o2		/* huge positive -> 0x7fffffff */
	set	0x80000000, %g1
	wr	%g1, %y
	sdivcc	%g0, 1, %o3		/* INT64_MIN / 1 -> 0x80000000 */
	sdivcc	%g0, -1, %o4		/* INT64_MIN / -1 -> 0x7fffffff */
	addx	%g0, 0, %o5		/* C stays 0 */
	wr	%g0, %y
	udivcc	%g0, 3, %g2		/* 0 -> Z, not V */
	bvc	5f
	 mov	7, %g3
	mov	8, %g3
5:	std	%o0, [%l0]
	std	%o2, [%l0 + 8]
	std	%o4, [%l0 + 16]
	st	%g3, [%l0 + 24]
	add	%l0, 32, %l0
	/* ---- dependent chains: each multiply's rd and Y feed the next, more
	 * than the 16 HILO registers in flight ---- */
	set	0x10001, %o0
	mov	3, %o1
	mov	40, %l7
6:	umul	%o0, %o1, %o0
	rd	%y, %o2
	add	%o2, %o1, %o1
	smul	%o1, %o0, %o1
	subcc	%l7, 1, %l7
	bne	6b
	 xor	%o0, %o1, %o0
	st	%o0, [%l0]
	st	%o1, [%l0 + 4]
	/* back to back, no consumers between them */
	umul	%o0, 5, %o3
	umul	%o3, 5, %o4
	umul	%o4, 5, %o5
	rd	%y, %g1
	udiv	%o5, 5, %g2		/* reads that Y */
	st	%o3, [%l0 + 8]
	st	%o4, [%l0 + 12]
	st	%o5, [%l0 + 16]
	st	%g1, [%l0 + 20]
	st	%g2, [%l0 + 24]
	add	%l0, 32, %l0
	/* ---- multiplies and divides in delay slots ---- */
	mov	3, %o0
	cmp	%o0, 3
	be	7f
	 umul	%o0, 11, %o1		/* taken: runs */
	mov	-1, %o1
7:	bne	8f
	 umul	%o0, 13, %o2		/* not taken: runs */
	cmp	%o0, 4
	bne,a	8f
	 smul	%o0, 17, %o3		/* taken, a=1: runs */
8:	be,a	9f
	 umul	%o0, 19, %o4		/* not taken, a=1: annulled */
	rd	%y, %o5
9:	wr	%g0, %y
	ba	10f
	 udiv	%o1, 3, %g1
10:	std	%o0, [%l0]
	std	%o2, [%l0 + 8]
	std	%o4, [%l0 + 16]
	st	%g1, [%l0 + 24]
	add	%l0, 32, %l0
	/* ---- the V7 software multiply (Linux .umul): 32 mulscc steps ---- */
	set	0xdeadbeef, %o0
	set	0x01234567, %o1
	wr	%o0, %y			/* multiplier */
	andcc	%g0, %g0, %o4		/* partial product 0, N = V = 0 */
	.rept	32
	mulscc	%o4, %o1, %o4
	.endr
	mulscc	%o4, %g0, %o4		/* final shift */
	rd	%y, %o5			/* low word (signed-multiplier correction not applied) */
	umul	%o0, %o1, %g4		/* the hardware answer, for comparison */
	rd	%y, %g5
	st	%o4, [%l0]
	st	%o5, [%l0 + 4]
	st	%g4, [%l0 + 8]
	st	%g5, [%l0 + 12]
	add	%l0, 16, %l0
	/* ---- division_by_zero: ET=0 -> error mode, both halt here ---- */
	wr	%g0, %y
	mov	1, %o0
	udiv	%o0, %g0, %o1
	nop

	.data
	.align	8
vals:	.word	0, 1, 2, 3, 0x7fffffff, 0x80000000, 0xffffffff, 0xfffffffe
	.word	12345, 0xdeadbeef, 0x10000, 0xffff, 0x55555555, 0xaaaaaaaa, 7, 0x80000001
	.align	8
out:	.skip	1024
