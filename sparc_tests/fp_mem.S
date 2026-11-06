/* FP loads/stores and single/double register aliasing on ooo_core: bare metal,
 * supervisor, ET=0, MMU off, like atomic.S.  d[2k] is the pair f[2k] (the high
 * word, at the lower address) : f[2k+1], so every single write lands in half a
 * pair and every double sees both halves.  No FP arithmetic: only moves,
 * sign ops and memory, so no NaN/rounding policy is involved.  Results go
 * through memory (the store check and the halt-time compare) and back into
 * integer registers (the per-retire compare).
 *   - ldf into even and odd halves, then stdf the pair
 *   - lddf, then stf of each half, and an ldf over one half of it
 *   - fmovs pairs (V8 has no fmovd), fnegs / fabss on an odd half
 *   - stfsr / ldfsr (RD and TEM written, fcc kept)
 * Ends with `ta 0` (error mode).  Build like atomic.S. */
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
	set	src, %l0
	set	dst, %l1
	/* ---- singles into both halves, the pair stored as a double ---- */
	ld	[%l0 + 0], %f0
	ld	[%l0 + 4], %f1
	std	%f0, [%l1 + 0]		/* 0x3f800000 0x40000000 */
	ld	[%l0 + 12], %f3		/* odd half first */
	ld	[%l0 + 8], %f2
	std	%f2, [%l1 + 8]
	ldd	[%l1 + 8], %o0		/* %o0:%o1 = the pair */
	/* ---- a double load, then each half as a single ---- */
	ldd	[%l0 + 16], %f4
	st	%f4, [%l1 + 16]		/* the high word */
	st	%f5, [%l1 + 20]		/* the low word */
	ld	[%l1 + 16], %o2
	ld	[%l1 + 20], %o3
	ld	[%l0 + 24], %f5		/* overwrite only the low half */
	std	%f4, [%l1 + 24]		/* high from the ldd, low from the ld */
	ldd	[%l1 + 24], %o4
	/* ---- fmovs pairs move a double; sign ops on an odd half ---- */
	ldd	[%l0 + 32], %f8
	fmovs	%f8, %f10
	fmovs	%f9, %f11
	std	%f10, [%l1 + 32]
	fnegs	%f9, %f13		/* odd destination, odd source */
	fabss	%f8, %f12		/* even destination, even source */
	std	%f12, [%l1 + 40]
	fnegs	%f12, %f15
	fmovs	%f13, %f14
	std	%f14, [%l1 + 48]
	ldd	[%l1 + 32], %g2
	ldd	[%l1 + 40], %g4
	ldd	[%l1 + 48], %l2
	/* ---- a dependent chain through one pair ---- */
	ld	[%l0 + 0], %f16
	fmovs	%f16, %f17
	fnegs	%f17, %f16
	fabss	%f16, %f17
	std	%f16, [%l1 + 56]
	ld	[%l1 + 60], %l4
	/* ---- the FSR ---- */
	st	%fsr, [%l1 + 64]	/* reset value */
	set	0x40000000 | (0x1f << 23), %o0	/* RD = toward zero, TEM = all */
	st	%o0, [%l1 + 68]
	ld	[%l1 + 68], %fsr
	st	%fsr, [%l1 + 72]
	set	0x80000000, %o0		/* RD = toward +inf, TEM = 0 */
	st	%o0, [%l1 + 76]
	ld	[%l1 + 76], %fsr
	st	%fsr, [%l1 + 80]
	ld	[%l1 + 72], %l5
	ld	[%l1 + 80], %l6
	/* ---- every register to memory: the halt-time compare sees all 32 ---- */
	set	fregs, %l7
	std	%f0, [%l7 + 0]
	std	%f2, [%l7 + 8]
	std	%f4, [%l7 + 16]
	std	%f6, [%l7 + 24]
	std	%f8, [%l7 + 32]
	std	%f10, [%l7 + 40]
	std	%f12, [%l7 + 48]
	std	%f14, [%l7 + 56]
	std	%f16, [%l7 + 64]
	ta	0
	nop

	.data
	.align	16
src:	.word	0x3f800000, 0x40000000, 0x40400000, 0x40800000
	.word	0x11223344, 0x55667788, 0x99aabbcc, 0xddeeff00
	.word	0xc0490fdb, 0x3fc90fdb, 0, 0
dst:	.skip	128
fregs:	.skip	128
