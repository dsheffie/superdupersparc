/* DCTI couples (a control transfer in another one's delay slot) on ooo_core:
 * bare metal, supervisor, ET=0, MMU off, like atomic.S.  With PC = J2 (the
 * second CTI) and nPC = T1 (the first one's resolved next pc), V8 runs:
 *   J2 taken, no annul      -> T1, then J2's target
 *   J2 not taken, a = 0     -> T1, T1 + 4, ...
 *   J2 not taken, a = 1     -> T1 + 4, ...            (T1 annulled)
 *   J2 = ba,a               -> J2's target            (T1 annulled)
 * Every case bumps counters where it should and where it must not, so a
 * double-executed or skipped instruction shows in the per-retire register
 * compare.  Each case runs in a loop of N passes, so it is seen both before and
 * after the branch predictors learn it.  The first case is NeXTSTEP's loop
 * shape (bneg,a with a return in its slot).  Ends with `ta 0` (error mode).
 * Build like atomic.S. */
#define N 6

	.text
	.globl _start
_start:
	clr	%l0			/* expected bumps */
	clr	%l1			/* bumps that must never happen */
	clr	%l2
	clr	%l3
	clr	%l4
	clr	%l5

	/* ---- 1: bneg,a T1 with jmpl %o7+8 in its slot (NeXTSTEP memset) ---- */
	mov	N, %g4
1:	mov	3, %o2
	call	sub1
	 nop
	add	%l2, 1, %l2		/* the return lands here */
	subcc	%g4, 1, %g4
	bne	1b
	 nop

	/* ---- 2: be taken, jmpl in its slot ---- */
	mov	N, %g4
2:	call	sub2
	 nop
	add	%l3, 1, %l3
	subcc	%g4, 1, %g4
	bne	2b
	 nop

	/* ---- 3: be not taken, jmpl in its slot (J2's slot is J2 + 4) ---- */
	mov	N, %g4
3:	call	sub3
	 nop
	add	%l4, 1, %l4
	subcc	%g4, 1, %g4
	bne	3b
	 nop

	/* ---- 4: ba T1, ba T2 in its slot: T1 once, then T2 ---- */
	mov	N, %g4
4:	ba	41f
	 ba	42f
	add	%l1, 1, %l1		/* never: the fall-through */
41:	add	%l0, 1, %l0		/* T1: the second ba's slot */
	add	%l1, 1, %l1		/* never: T1 + 4 */
42:	add	%l5, 1, %l5		/* T2 */
	subcc	%g4, 1, %g4
	bne	4b
	 nop

	/* ---- 5: ba T1, bne,a T2 not taken in its slot: T1 annulled ---- */
	mov	N, %g4
5:	cmp	%g0, %g0		/* Z = 1: bne not taken */
	ba	51f
	 bne,a	52f
	add	%l1, 1, %l1		/* never */
51:	add	%l1, 1, %l1		/* T1: annulled */
	add	%l0, 1, %l0		/* T1 + 4 runs */
	ba	53f
	 nop
52:	add	%l1, 1, %l1		/* never: bne not taken */
53:	subcc	%g4, 1, %g4
	bne	5b
	 nop

	/* ---- 6: ba T1, ba,a T2 in its slot: T1 annulled, straight to T2 ---- */
	mov	N, %g4
6:	ba	61f
	 ba,a	62f
	add	%l1, 1, %l1		/* never */
61:	add	%l1, 1, %l1		/* T1: annulled */
	add	%l1, 1, %l1		/* never */
62:	add	%l0, 1, %l0		/* T2 */
	subcc	%g4, 1, %g4
	bne	6b
	 nop

	/* ---- 7: be taken, bne not taken (a = 0) in its slot: T1, T1 + 4 ---- */
	mov	N, %g4
7:	cmp	%g0, %g0		/* Z = 1 */
	be	71f
	 bne	72f
	add	%l1, 1, %l1		/* never */
71:	add	%l0, 1, %l0		/* T1 */
	add	%l0, 1, %l0		/* T1 + 4 */
	ba	73f
	 nop
72:	add	%l1, 1, %l1		/* never */
73:	subcc	%g4, 1, %g4
	bne	7b
	 nop

	/* ---- 8: ba T1, call F in its slot: T1 once, then F ---- */
	mov	N, %g4
8:	ba	81f
	 call	sub8
	add	%l1, 1, %l1		/* never */
81:	add	%l0, 1, %l0		/* T1: the call's slot */
	add	%l1, 1, %l1		/* never */
82:	subcc	%g4, 1, %g4		/* sub8 returns here */
	bne	8b
	 nop

	ta	0
	 nop

/* the loop of case 1: count %o2 down; when it goes negative, bneg,a is taken,
 * its slot (the return) runs, then T1 once (in the return's slot) */
sub1:
11:	subcc	%o2, 1, %o2
	bneg,a	12f
	 jmpl	%o7 + 8, %g0
	add	%l0, 1, %l0		/* the loop body, 3 times a call */
	ba	11b
	 nop
12:	add	%l0, 1, %l0		/* T1: once */
	add	%l1, 1, %l1		/* never */
	add	%l1, 1, %l1		/* never */

/* be taken (Z = 1) with the return in its slot: T1, then back */
sub2:
	cmp	%g0, %g0
	be	21f
	 jmpl	%o7 + 8, %g0
	add	%l1, 1, %l1		/* never */
21:	add	%l0, 1, %l0		/* T1: once */
	add	%l1, 1, %l1		/* never */

/* be not taken (Z = 0) with the return in its slot: its slot is J2 + 4 */
sub3:
	cmp	%g0, 1
	be	31f
	 jmpl	%o7 + 8, %g0
	add	%l0, 1, %l0		/* J2 + 4: the return's slot, once */
	add	%l1, 1, %l1		/* never */
31:	add	%l1, 1, %l1		/* never */

/* the call of case 8 (%o7 = the call's pc): back past the call's slot to 82 */
sub8:
	set	82b, %g5
	jmpl	%g5, %g0
	 nop
