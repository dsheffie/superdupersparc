/* nb_boot.c's page tables at PA 0x800000 (ld --section-start=.ptab=0x800000):
 * the low 16 MB identity mapped by one level-1 PTE, UNCACHEABLE by default, as
 * OBP maps the boot block's 0x4000 -- the case where the L1I kept uncached fills
 * (l1i.sv NC_TURNAROUND).  -DCBIT=1 maps it cacheable.
 * Run with --mmu-ctrl 0x901 --mmu-ctpr 0x80000 --mmu-ctx 0 */
#ifndef CBIT
#define CBIT 0
#endif
#define PTD(pa)		(((pa) >> 4) | 1)
#define PTE(pa, acc, c, m) ((((pa) >> 4) & ~0xff) | ((c) << 7) | ((m) << 6) | ((acc) << 2) | 2)
	.section .ptab, "aw"
	.align	1024
ctx_table:				/* 0x800000 */
	.word	PTD(0x800400)
	.skip	1020
l1:					/* 0x800400: VA[31:24] */
	.word	PTE(0x000000, 3, CBIT, 0)	/* VA 0-16 MB -> PA 0, RWX */
	.skip	255 * 4
	.section .note.GNU-stack,"",@progbits
