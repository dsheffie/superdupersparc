/* casa (LEON3's V8 CASA: decode_sparc.sv S_CASA, l1d.sv MEM_CAS) with the
 * SRMMU on (see mmu_on.S / atomic_mmu.S), run with
 *   ooo_core -f cas_<n>.elf --mmu-ctrl 0x901 --mmu-ctpr 0x80000 --mmu-ctx 0
 * casa [rs1] asi, rs2, rd: the word at [rs1] is compared with rs2; if equal rd
 * is written there; rd gets the old word either way.  The low 16 MB is identity
 * mapped (one level-1 PTE, cacheable); VA 0x40000000 is a 3-level walk to 4 KB
 * pages at PA 0x900000.  Every PTE starts with R = M = 0, so the halt-time
 * memory compare checks that casa sets M (it is a store, even when the compare
 * fails) and that a wrong-path one does not.
 *   page 0: RW cacheable: cold equal, not-equal, hot, rd = %g0, rs2 = %g0,
 *           an older store and a younger load to the same word, ASI 0xb and 0xa
 *   page 1: read only
 *   page 2: RW uncacheable (C = 0)
 *   page 3: RW, touched only by a casa on the not-taken side of a branch the
 *           cold predictor gets wrong: its PTE must keep M = 0
 * then, through the identity map: casas whose line set holds a dirty line of
 * another tag (16 KB stride), and a casa retry loop incrementing a counter.
 * Then drops to user mode (wr %psr: S = 0) for a user casa with ASI 0xa, and
 * ends with `ta 0` (error mode, ET = 0; a wrong value ends with `ta 1`).
 * -DFAULT=n ends with one trap instead:
 *   1: user casa with ASI 0xb          privileged_instruction (tt 3)
 *   2: supervisor casa, ASI 0x4 (MMU)  illegal_instruction (tt 2)
 *   3: casa to an address with [1:0]=2 mem_address_not_aligned (tt 7)
 *   4: casa to the uncacheable page    data_access_error (tt 0x29), no access
 *   5: casa to the read-only page      data_access_exception (tt 9)
 *   6: casa with i = 1 (V9's %asi)     illegal_instruction (tt 2)
 * Build with the LEON3 assembler mode (-Aleon), linked like atomic_mmu.S:
 *   clang -E -P -x assembler-with-cpp [-DFAULT=n] cas.S -o build/cas_<n>.s
 *   sparc64-linux-gnu-as -32 -Aleon build/cas_<n>.s -o build/cas_<n>.o
 *   sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 \
 *     --section-start=.ptab=0x800000 --section-start=.pages=0x900000 \
 *     -o build/cas_<n>.elf build/cas_<n>.o */
#define PTD(pa)		(((pa) >> 4) | 1)
#define PTE(pa, acc, c, m) ((((pa) >> 4) & ~0xff) | ((c) << 7) | ((m) << 6) | ((acc) << 2) | 2)
#ifndef FAULT
#define FAULT 0
#endif
/* the expected values, worked out by hand (the checker only proves RTL = ISS):
 * a mismatch ends with `ta 1` (tt 0x81) instead of `ta 0` */
#define CHK(r, v)	\
	set	v, %o7;	\
	cmp	r, %o7;	\
	bne	fail;	\
	 nop
	.text
	.globl _start
_start:
	set	0x40000000, %l0		/* VA of the pages */
	set	0x00900000, %l1		/* their PA (the identity alias) */
	/* ---- page 0: cold, equal: swaps ---- */
	add	%l0, 0x10, %l2
	set	0x00112233, %o0		/* compare (the word's value) */
	set	0xcafef00d, %o1		/* swap */
	casa	[%l2] 0xb, %o0, %o1	/* %o1 = 0x00112233, mem = 0xcafef00d */
	ld	[%l1 + 0x10], %o2	/* through the alias: 0xcafef00d */
	CHK(%o1, 0x00112233)
	CHK(%o2, 0xcafef00d)
	/* not equal: memory unchanged, rd gets the old word */
	set	0x12345678, %o3
	mov	%o3, %o4
	casa	[%l2] 0xb, %o0, %o4	/* %o4 = 0xcafef00d, mem unchanged */
	ld	[%l2], %o5		/* younger load: 0xcafef00d */
	CHK(%o4, 0xcafef00d)
	CHK(%o5, 0xcafef00d)
	/* hot, equal again */
	mov	%o4, %o0
	set	0x0badc0de, %o1
	casa	[%l2] 0xb, %o0, %o1	/* %o1 = 0xcafef00d, mem = 0x0badc0de */
	CHK(%o1, 0xcafef00d)
	/* rd = %g0: memory still written (compare 0 against a zero word) */
	add	%l0, 0x14, %l3
	casa	[%l3] 0xb, %g0, %g0	/* old 0 == 0: writes 0 back */
	/* rs2 = %g0 against a zero word: swaps */
	set	0x5a5a5a5a, %g1
	casa	[%l3] 0xb, %g0, %g1	/* %g1 = 0, mem = 0x5a5a5a5a */
	ld	[%l3], %g2
	CHK(%g1, 0)
	CHK(%g2, 0x5a5a5a5a)
	/* older store, then casa to the same word: compares against the stored value */
	add	%l0, 0x18, %l4
	set	0x77777777, %g3
	st	%g3, [%l4]
	set	0x88888888, %g4
	casa	[%l4] 0xb, %g3, %g4	/* %g4 = 0x77777777, mem = 0x88888888 */
	ld	[%l4], %g5
	CHK(%g4, 0x77777777)
	CHK(%g5, 0x88888888)
	/* older store to the sibling word of the same line */
	sth	%g3, [%l4 + 4]
	add	%l4, 4, %i5
	set	0x99999999, %g6
	casa	[%i5] 0xb, %g0, %g6	/* old 0x77770000 != 0: unchanged */
	/* ASI 0xa (user data) from supervisor: page 0 is RW to users */
	set	0x00abcdef, %g7
	casa	[%i5] 0xa, %g6, %g7	/* compare 0x77770000: equal, mem = 0x00abcdef */
	ld	[%l4 + 4], %o0
	CHK(%g6, 0x77770000)
	CHK(%g7, 0x77770000)
	CHK(%o0, 0x00abcdef)
	/* ---- page 3: wrong path only ---- */
	set	0x3000, %o1
	add	%l0, %o1, %o1
	mov	5, %o2
	cmp	%o2, 5
	be	1f			/* always taken; cold: predicted not taken */
	 nop
	casa	[%o1] 0xb, %g0, %o2	/* never architecturally executed */
	casa	[%o1] 0xb, %g0, %o2
1:	ld	[%l2], %o3
	CHK(%o3, 0x0badc0de)
	/* ---- dirty conflict victims (identity map): each casa evicts a dirty twin ---- */
	set	conf, %l5
	set	0x4000, %l6
	mov	8, %l7
2:	add	%l5, %l6, %i0
	st	%l7, [%i0]		/* dirty the twin */
	mov	%l7, %i1
	casa	[%l5] 0xb, %g0, %i1	/* old 0: swaps in the iteration count */
	add	%i1, %l7, %i1
	st	%i1, [%i0 + 4]		/* back to the twin */
	subcc	%l7, 1, %l7
	bne	2b
	 add	%l5, 0x10, %l5
	set	conf, %l5
	ld	[%l5], %o0		/* the first iteration's count */
	CHK(%o0, 8)
	add	%l5, %l6, %o1
	ld	[%o1 + 4], %o0		/* its twin: 0 + 8 */
	CHK(%o0, 8)
	/* ---- casa increment loop: ld, add, casa, retry if another value won ---- */
	set	cnt, %l5
	mov	40, %l7
3:	ld	[%l5], %i2
4:	add	%i2, %l7, %i3
	casa	[%l5] 0xb, %i2, %i3
	cmp	%i3, %i2
	bne,a	4b			/* never taken here (no other writer) */
	 mov	%i3, %i2
	subcc	%l7, 1, %l7
	bne	3b
	 nop
	ld	[%l5], %i4		/* 40 * 41 / 2 = 820 */
	CHK(%i4, 820)
#if FAULT == 2
	casa	[%l2] 0x4, %g0, %o0
#elif FAULT == 3
	add	%l2, 2, %o1
	casa	[%o1] 0xb, %g0, %o0
#elif FAULT == 4
	set	0x2000, %o1
	add	%l0, %o1, %o1
	set	0x13579bdf, %o0
	casa	[%o1] 0xb, %g0, %o0	/* the word is 0: would swap if it ran */
#elif FAULT == 5
	set	0x1000, %o1
	add	%l0, %o1, %o1
	casa	[%o1] 0xb, %g0, %o0
#elif FAULT == 6
	.word	0xd5e4a009		/* casa [%l2] %asi, %o1, %o2: i = 1 */
#endif
	/* ---- user mode: S = 0 (ET stays 0), then a user casa ---- */
	rd	%psr, %o0
	andn	%o0, 0x80, %o0
	wr	%o0, 0, %psr
	nop
	nop
	nop
	add	%l0, 0x20, %o1
	set	0xdeadbeef, %o4		/* the word's value */
	set	0xfeedface, %o2
	casa	[%o1] 0xa, %o4, %o2	/* %o2 = 0xdeadbeef, mem = 0xfeedface */
	ld	[%o1], %o3
	CHK(%o2, 0xdeadbeef)
	CHK(%o3, 0xfeedface)
#if FAULT == 1
	casa	[%o1] 0xb, %g0, %o2
#endif
	ta	0
	nop
fail:	ta	1
	nop

	.data
	.align	16
cnt:	.word	0
	.align	0x4000
conf:	.skip	0x4000 + 0x100

	/* page tables at PA 0x800000 (ld --section-start=.ptab=0x800000) */
	.section .ptab, "aw"
	.align	1024
ctx_table:				/* 0x800000 */
	.word	PTD(0x800400)
	.skip	1020
l1:					/* 0x800400: VA[31:24] */
	.word	PTE(0x000000, 3, 1, 0)	/* VA 0-16 MB -> PA 0, RWX */
	.skip	(0x40 - 1) * 4
	.word	PTD(0x800800)		/* VA 0x40xxxxxx */
	.skip	(256 - 0x41) * 4	/* VA 0x50xxxxxx: invalid */
l2:					/* 0x800800: VA[23:18] */
	.word	PTD(0x800900)
	.skip	63 * 4
l3:					/* 0x800900: VA[17:12] */
	.word	PTE(0x900000, 1, 1, 0)	/* RW */
	.word	PTE(0x901000, 0, 1, 0)	/* read only */
	.word	PTE(0x902000, 1, 0, 0)	/* RW, uncacheable */
	.word	PTE(0x903000, 1, 1, 0)	/* RW, wrong path only */
	.skip	60 * 4
	.section .pages, "aw"
	.word	0, 0, 0, 0, 0x00112233, 0, 0, 0, 0xdeadbeef
	.skip	0x4000 - 36
