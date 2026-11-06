/* fcmps/fcmpd/fcmpes/fcmped and all 16 FBfcc conditions on ooo_core: bare
 * metal, supervisor, ET=0, MMU off, FSR.TEM = 0 (no FP traps), like fp_mem.S.
 * Each operand pair (=, <, >, unordered via quiet and signaling NaNs, +0/-0,
 * infinities, singles in both halves of a pair) is compared, then every FBfcc
 * condition sets one bit of %o5 when taken; the annulled forms clear a bit in
 * their delay slot when not annulled.  After each pair the FSR (fcc, cexc,
 * aexc) is stored; the masks go to memory too.  No FP arithmetic.
 * Ends with `ta 0` (error mode).  Build like atomic.S. */
#define BIT(c, n)			\
	fb##c	1f;			\
	 nop;				\
	ba	2f;			\
	 nop;				\
1:	or	%o5, (1 << n), %o5;	\
2:

#define ABIT(c, n)			\
	fb##c,a	1f;			\
	 or	%o4, (1 << n), %o4;	\
1:

#define ALLCOND				\
	mov	0, %o5;			\
	mov	0, %o4;			\
	nop;				\
	BIT(n, 0)  BIT(ne, 1)  BIT(lg, 2)  BIT(ul, 3)	\
	BIT(l, 4)  BIT(ug, 5)  BIT(g, 6)   BIT(u, 7)	\
	BIT(a, 8)  BIT(e, 9)   BIT(ue, 10) BIT(ge, 11)	\
	BIT(uge, 12) BIT(le, 13) BIT(ule, 14) BIT(o, 15)	\
	ABIT(n, 0)  ABIT(ne, 1)  ABIT(l, 4)  ABIT(u, 7)	\
	ABIT(a, 8)  ABIT(e, 9)   ABIT(ge, 11) ABIT(o, 15)	\
	st	%o5, [%l1];		\
	st	%o4, [%l1 + 4];		\
	st	%fsr, [%l1 + 8];	\
	add	%l1, 16, %l1

/* compare f[ra] with f[rb] as singles, d[ra] with d[rb] as doubles */
#define CMPS(op, ra, rb)	op	%f##ra, %f##rb; ALLCOND
#define CMPD(op, ra, rb)	op	%f##ra, %f##rb; ALLCOND

	.text
	.globl _start
_start:
	rd	%psr, %g1
	set	0x1000, %g2		/* PSR.EF */
	or	%g1, %g2, %g1
	wr	%g1, %psr
	nop
	nop
	nop
	set	sv, %l0
	set	out, %l1
	/* singles: f0..f15 from sv (both halves of each pair) */
	ldd	[%l0 + 0], %f0
	ldd	[%l0 + 8], %f2
	ldd	[%l0 + 16], %f4
	ldd	[%l0 + 24], %f6
	ldd	[%l0 + 32], %f8
	ldd	[%l0 + 40], %f10
	ldd	[%l0 + 48], %f12
	ldd	[%l0 + 56], %f14
	/* doubles: d16..d30 from dv */
	set	dv, %l2
	ldd	[%l2 + 0], %f16
	ldd	[%l2 + 8], %f18
	ldd	[%l2 + 16], %f20
	ldd	[%l2 + 24], %f22
	ldd	[%l2 + 32], %f24
	ldd	[%l2 + 40], %f26
	ldd	[%l2 + 48], %f28
	ldd	[%l2 + 56], %f30
	CMPS(fcmps, 0, 1)		/* 1.0 < 2.0 */
	CMPS(fcmps, 1, 0)		/* > */
	CMPS(fcmps, 0, 0)		/* = */
	CMPS(fcmps, 2, 3)		/* +0 = -0 */
	CMPS(fcmps, 4, 0)		/* qNaN: unordered, no NV */
	CMPS(fcmpes, 4, 0)		/* qNaN, fcmpes: NV */
	CMPS(fcmps, 0, 5)		/* sNaN: NV */
	CMPS(fcmps, 6, 7)		/* -inf < +inf */
	CMPS(fcmps, 9, 8)		/* odd vs even half: -1.5 < 3.0 */
	CMPS(fcmps, 11, 10)		/* denormal vs 0: > */
	CMPD(fcmpd, 16, 18)		/* 1.0 < 2.0 */
	CMPD(fcmpd, 18, 16)
	CMPD(fcmpd, 16, 16)
	CMPD(fcmpd, 20, 22)		/* +0 = -0 */
	CMPD(fcmpd, 24, 16)		/* qNaN */
	CMPD(fcmped, 24, 16)
	CMPD(fcmpd, 16, 26)		/* sNaN */
	CMPD(fcmpd, 28, 30)		/* -inf < +inf */
	CMPD(fcmped, 28, 30)		/* ordered: no NV */
	ta	0
	nop

	.data
	.align	16
sv:	.word	0x3f800000, 0x40000000	/* 1.0 2.0 */
	.word	0x00000000, 0x80000000	/* +0 -0 */
	.word	0x7fc00000, 0x7f800001	/* qNaN sNaN */
	.word	0xff800000, 0x7f800000	/* -inf +inf */
	.word	0x40400000, 0xbfc00000	/* 3.0 -1.5 */
	.word	0x00000000, 0x00000001	/* 0, denormal */
	.word	0, 0, 0, 0
dv:	.word	0x3ff00000, 0		/* 1.0 */
	.word	0x40000000, 0		/* 2.0 */
	.word	0x00000000, 0		/* +0 */
	.word	0x80000000, 0		/* -0 */
	.word	0x7ff80000, 0		/* qNaN */
	.word	0x7ff00000, 1		/* sNaN */
	.word	0xfff00000, 0		/* -inf */
	.word	0x7ff00000, 0		/* +inf */
out:	.skip	16 * 24
