/* SRMMU probes (lda ASI 3) of every type on ooo_core: run like mmu_on.S
 *   ooo_core -f probe.elf --mmu-ctrl 0x801 --mmu-ctpr 0x80000 --mmu-ctx 0
 * va[11:8] is the probe type -- 0 page, 1 segment, 2 region, 3 context,
 * 4 entire, 5-15 undefined (0).  A probe stops at its type's level and answers
 * with the entry there, a PTD as well as a PTE; a PTE met first is the answer,
 * an invalid entry 0.  Solaris 2.5.1's vik_mmu_probe walks region -> segment ->
 * page and takes a PTE answer as a large page, so a probe answering the leaf
 * for every type gave it a bogus PA.  Each answer lands in its own register,
 * so the per-retire compare checks every one against the ISS.  The same VA is
 * probed with different types back to back (the L1D keeps the last answer).
 * Same tables as mmu_on.S: VA 0-16 MB an L1 PTE, 0x40000000 a 3-level walk to
 * 4 KB pages, 0x41000000 a 256 KB (L2) PTE, 0x50000000 invalid at level 1.
 * Then a write and read-back of the ASI 0x4c breakpoint action register
 * (Solaris's bpt_reg spins until it reads back).  Ends with `ta 0`. */
#define PTD(pa)		(((pa) >> 4) | 1)
#define PTE(pa, acc, c, m) ((((pa) >> 4) & ~0xff) | ((c) << 7) | ((m) << 6) | ((acc) << 2) | 2)
	.text
	.globl _start
_start:
	/* ---- 4 KB page: context PTD, region PTD, segment PTD, page PTE ---- */
	set	0x40000000, %g1
	or	%g1, 0x400, %g6
	lda	[%g6] 3, %l0	/* entire: the L3 PTE */
	or	%g1, 0x200, %g6
	lda	[%g6] 3, %l1	/* region: the L1 PTD */
	or	%g1, 0x100, %g6
	lda	[%g6] 3, %l2	/* segment: the L2 PTD */
	lda	[%g1] 3, %l3		/* page: the L3 PTE */
	or	%g1, 0x300, %g6
	lda	[%g6] 3, %l4	/* context: the context table PTD */
	or	%g1, 0x500, %g6
	lda	[%g6] 3, %l5	/* type 5: 0 */
	set	0x40001000, %g2		/* the next page: region again first */
	or	%g2, 0x200, %g6
	lda	[%g6] 3, %l6
	or	%g2, 0x400, %g6
	lda	[%g6] 3, %l7
	/* ---- 256 KB page: the L2 PTE answers page, segment and entire ---- */
	set	0x41000000, %g3
	or	%g3, 0x200, %g6
	lda	[%g6] 3, %i0	/* region: the L1 PTD */
	or	%g3, 0x100, %g6
	lda	[%g6] 3, %i1	/* segment: the L2 PTE */
	lda	[%g3] 3, %i2		/* page: the L2 PTE */
	or	%g3, 0x400, %g6
	lda	[%g6] 3, %i3	/* entire: the L2 PTE */
	/* ---- 16 MB region: the L1 PTE answers all but context ---- */
	set	0x00100000, %g4
	or	%g4, 0x200, %g6
	lda	[%g6] 3, %i4	/* region: the L1 PTE */
	or	%g4, 0x100, %g6
	lda	[%g6] 3, %i5	/* segment: the L1 PTE */
	lda	[%g4] 3, %o0		/* page: the L1 PTE */
	or	%g4, 0x300, %g6
	lda	[%g6] 3, %o1	/* context: the context table PTD */
	/* ---- invalid at level 1: 0, except a context probe ---- */
	set	0x50000000, %g5
	or	%g5, 0x400, %g6
	lda	[%g6] 3, %o2
	or	%g5, 0x200, %g6
	lda	[%g6] 3, %o3
	lda	[%g5] 3, %o4
	or	%g5, 0x300, %g6
	lda	[%g6] 3, %o5
	/* ---- probes and ASI stores in delay slots of mispredicted branches ----
	 * An xorshift low bit picks each branch's direction, so about half
	 * mispredict and enter the faulted-delay-slot serialize funnel with an
	 * ASI op (serializing) in the slot.  be,a: the slot runs only when taken
	 * (Solaris vik_window_underflow has a probe there; a taken one
	 * deadlocked).  An annulled sta to ASI 0x4c must not write, which the
	 * read-back after each pass shows.  bne: a plain slot, always runs. */
	set	0x12345678, %g1		/* xorshift state */
	mov	64, %g2
	clr	%g3			/* the checksum, compared at every retire */
	set	0x40000400, %g5		/* an entire probe of the 4 KB page */
1:	sll	%g1, 13, %g4
	xor	%g1, %g4, %g1
	srl	%g1, 17, %g4
	xor	%g1, %g4, %g1
	sll	%g1, 5, %g4
	xor	%g1, %g4, %g1
	clr	%g6
	andcc	%g1, 1, %g0
	be,a	2f
	 lda	[%g5] 3, %g6		/* only when taken */
	add	%g3, 3, %g3		/* not taken */
2:	add	%g3, %g6, %g3
	andcc	%g1, 2, %g0
	be,a	3f
	 sta	%g1, [%g0] 0x4c		/* only when taken */
	add	%g3, 5, %g3
3:	lda	[%g0] 0x4c, %g6
	add	%g3, %g6, %g3
	andcc	%g1, 4, %g0
	bne	4f
	 lda	[%g5] 3, %g6		/* always */
	add	%g3, 7, %g3
4:	add	%g3, %g6, %g3
	subcc	%g2, 1, %g2
	bne	1b
	 nop

	/* ---- ASI 0x4c, the breakpoint action register: 13 bits read back ---- */
	set	0xffffffff, %g7
	sta	%g7, [%g0] 0x4c
	lda	[%g0] 0x4c, %g7		/* 0x1fff */
	ta	0
	 nop

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
	.word	PTD(0x800900)		/* VA 0x41xxxxxx */
	.skip	(256 - 0x42) * 4	/* VA 0x50xxxxxx: invalid */
l2:					/* 0x800800: VA[23:18] of 0x40xxxxxx */
	.word	PTD(0x800a00)
	.skip	63 * 4
l2b:					/* 0x800900: VA[23:18] of 0x41xxxxxx */
	.word	PTE(0xa00000, 1, 1, 0)	/* 256 KB, RW */
	.skip	63 * 4
l3:					/* 0x800a00: VA[17:12] of 0x400xxxxx */
	.word	PTE(0x900000, 1, 1, 0)
	.word	PTE(0x901000, 1, 1, 0)
	.skip	62 * 4
