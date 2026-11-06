/* ldstub / swap with the SRMMU on (see mmu_on.S), run with
 *   ooo_core -f atomic_mmu_<n>.elf --mmu-ctrl 0x801 --mmu-ctpr 0x80000 --mmu-ctx 0
 * The low 16 MB is identity mapped (one level-1 PTE); VA 0x40000000 is a
 * 3-level walk to 4 KB pages at PA 0x900000.  Every PTE starts with R = M = 0,
 * so the halt-time memory compare checks that an atomic sets M (it is a store:
 * the mark walk at the ROB head) and that a wrong-path one does not.
 *   page 0: RW, cold-dtlb ldstub (walk, then mark walk), then swap
 *   page 1: read only
 *   page 2: RW, swap after an older store through the alias
 *   page 3: RW, touched only by a ldstub on the not-taken side of a branch the
 *           cold predictor gets wrong: its PTE must keep M = 0 (and R may be set)
 * Ends with `ta 0` (error mode), or a data_access_exception:
 *   FAULT=1: ldstub to the read-only page (protection, a store access)
 *   FAULT=2: swap to the unmapped VA 0x50000000 (invalid at level 1) */
#define PTD(pa)		(((pa) >> 4) | 1)
#define PTE(pa, acc, c, m) ((((pa) >> 4) & ~0xff) | ((c) << 7) | ((m) << 6) | ((acc) << 2) | 2)
	.text
	.globl _start
_start:
	set	0x40000000, %l0		/* VA of the pages */
	set	0x00900000, %l1		/* their PA (the identity alias) */
	/* ---- page 0 ---- */
	ldstub	[%l0 + 0x11], %o0
	ldub	[%l1 + 0x11], %o1	/* 0xff through the alias */
	set	0xa5a5a5a5, %o2
	swap	[%l0 + 0x20], %o2
	ld	[%l1 + 0x20], %o3
	/* ---- page 1 (read only): a load is fine ---- */
	set	0x1000, %g1
	ld	[%l0 + %g1], %o4
	/* ---- page 2: older store through the alias, then swap through the VA ---- */
	set	0x2000, %g1
	add	%l1, %g1, %l2
	add	%l0, %g1, %l3
	set	0x31415926, %o5
	st	%o5, [%l2 + 8]
	set	0x27182818, %g2
	swap	[%l3 + 8], %g2		/* 0x31415926 */
	ld	[%l2 + 8], %g3
	/* ---- page 3: wrong-path only ---- */
	set	0x3000, %g1
	add	%l0, %g1, %l4
	mov	5, %g4
	cmp	%g4, 5
	be	1f			/* always taken; cold: predicted not taken */
	 nop
	ldstub	[%l4], %g5		/* never architecturally executed */
	ldstub	[%l4 + 1], %g5
1:	ld	[%l0 + 0x20], %g6
#if FAULT == 1
	set	0x1000, %g1
	ldstub	[%l0 + %g1], %g7
#elif FAULT == 2
	set	0x50000000, %g1
	swap	[%g1], %g7
#endif
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
	.skip	(256 - 0x41) * 4	/* VA 0x50xxxxxx: invalid */
l2:					/* 0x800800: VA[23:18] */
	.word	PTD(0x800900)
	.skip	63 * 4
l3:					/* 0x800900: VA[17:12] */
	.word	PTE(0x900000, 1, 1, 0)	/* RW */
	.word	PTE(0x901000, 0, 1, 0)	/* read only */
	.word	PTE(0x902000, 1, 1, 0)	/* RW */
	.word	PTE(0x903000, 1, 1, 0)	/* RW, wrong path only */
	.skip	60 * 4
	.section .pages, "aw"
	.word	0, 0, 0, 0, 0x00112233, 0, 0, 0, 0xdeadbeef
	.skip	0x4000 - 36
