/* SRMMU on ooo_core, MMU on from reset (no lda/sta to ASI 0x4 yet): run with
 *   ooo_core -f mmu_on.elf --mmu-ctrl 0x801 --mmu-ctpr 0x80000 --mmu-ctx 0
 * (ctrl = MBus mode | E; ctpr = 0x800000 >> 4: the context table below).
 * Bare metal, supervisor, ET=0 like wiggle.S.  The low 16 MB is identity
 * mapped by one level-1 (16 MB) PTE, so code, tables and the physical aliases
 * of the mapped pages run at PA = VA (the L1I does not translate yet); VA
 * 0x40000000 is a 3-level walk to 4 KB pages, VA 0x41000000 a 256 KB page.
 * Every PTE starts with R = M = 0, so the walker's R write-back (and its mirror
 * into the checker's memory) and the M marking of the first store to each page
 * are checked by the halt-time memory compare.
 * Ends with a load from the unmapped VA 0x50000000: a data_access_exception
 * with ET = 0, i.e. error mode, where the RTL and the ISS both halt. */
#define PTD(pa)		(((pa) >> 4) | 1)
#define PTE(pa, acc, c, m) ((((pa) >> 4) & ~0xff) | ((c) << 7) | ((m) << 6) | ((acc) << 2) | 2)
#define NPAGES 40
	.text
	.globl _start
_start:
	set	0x40000000, %l0		/* VA of the 4 KB pages */
	set	0x00900000, %l1		/* their PA (the identity alias) */
	/* ---- page 0 (RW): stores through the VA, loads back through the alias ---- */
	set	0xcafef00d, %o0
	st	%o0, [%l0 + 8]
	ld	[%l1 + 8], %o1
	set	0x0123, %o2
	sth	%o2, [%l0 + 0x12]
	mov	0x5a, %o3
	stb	%o3, [%l0 + 0x15]
	ldd	[%l1 + 0x10], %o4	/* 0x00000123 5a...: the halfword + byte */
	set	0x89abcdef, %g2
	set	0x76543210, %g3
	std	%g2, [%l0 + 0x20]
	ldd	[%l0 + 0x20], %g4
	ldub	[%l1 + 0x23], %g6
	ldsh	[%l1 + 0x24], %g7
	/* and the other way: through the alias, read through the VA */
	set	0x31415926, %o0
	st	%o0, [%l1 + 0x40]
	ld	[%l0 + 0x40], %o1
	/* ---- page 1: read only (ACC 0), loads only ---- */
	set	0x1004, %g1
	ld	[%l0 + %g1], %o2
	/* ---- page 2: uncached (C = 0) ---- */
	set	0x2000, %o3
	set	0xdeadbeef, %o4
	st	%o4, [%l0 + %o3]
	ld	[%l0 + %o3], %o5
	/* ---- a 256 KB page: VA 0x41000000 + off -> PA 0xa00000 + off ---- */
	set	0x41023456 & ~3, %l2
	set	0x00a23456 & ~3, %l3
	set	0x600dcafe, %o0
	st	%o0, [%l2]
	ld	[%l3], %o1
	/* ---- TLB pressure: one store + load per page over NPAGES pages (more
	 * than the dtlb holds), each value depending on the last ---- */
	set	0x3000, %l4
	set	NPAGES - 3, %l5
	mov	7, %o0
1:	add	%l0, %l4, %l6
	st	%o0, [%l6 + 0x10]
	ld	[%l6 + 0x10], %o1
	sll	%o1, 1, %o0
	xor	%o0, %l5, %o0
	set	0x1000, %g1
	subcc	%l5, 1, %l5
	bne	1b
	 add	%l4, %g1, %l4
	/* and back over them, newest first, through the alias */
	set	(NPAGES - 1) * 0x1000, %l4
	mov	0, %o2
2:	add	%l1, %l4, %l6
	ld	[%l6 + 0x10], %o1
	add	%o2, %o1, %o2
	set	0x3000, %g1
	cmp	%l4, %g1
	set	0x1000, %g1
	bne	2b
	 sub	%l4, %g1, %l4
	st	%o2, [%l0 + 0x80]
	/* ---- data_access_exception (invalid at level 1), ET = 0: error mode ---- */
	set	0x50000000, %l7
	ld	[%l7], %o0
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
	.word	PTE(0x900000, 1, 1, 0)	/* RW */
	.word	PTE(0x901000, 0, 1, 0)	/* read only, M stays 0 */
	.word	PTE(0x902000, 1, 0, 0)	/* RW, uncached */
	.set	pg, 3
	.rept	NPAGES - 3
	.word	PTE(0x900000 + pg * 0x1000, 1, 1, 0)
	.set	pg, pg + 1
	.endr
	.skip	(64 - NPAGES) * 4
	/* the mapped pages' PA range, so the ELF loads it (zeroed) */
	.section .pages, "aw"
	.skip	NPAGES * 0x1000
	.section .bigpage, "aw"
	.skip	0x24000
