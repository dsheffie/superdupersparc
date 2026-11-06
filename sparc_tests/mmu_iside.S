/* SRMMU instruction side on ooo_core, MMU on from reset (see mmu_on.S):
 *   ooo_core -f mmu_iside_<n>.elf --mmu-ctrl 0x801 --mmu-ctpr 0x80000 --mmu-ctx 0
 * The low 16 MB is identity mapped (one level-1 PTE), as in mmu_on.S; code also
 * runs at VA 0x60000000, a chain of NCODE 4 KB pages at PA 0xb00000 (VA != PA),
 * more pages than the itlb holds, walked twice.  Each page does some arithmetic
 * and a load, then jumps to the next; the last returns.  Every PTE starts with
 * R = M = 0 (fetches set R; the halt-time memory compare checks it).  Ends with
 * an instruction_access_exception (ET = 0: error mode, both halt there):
 *   IFAULT=1: a jump to the unmapped VA 0x70000000 (invalid at level 1)
 *   IFAULT=2: a jump into page NCODE, mapped read-only (ACC 0, no execute) */
#define PTD(pa)		(((pa) >> 4) | 1)
#define PTE(pa, acc, c, m) ((((pa) >> 4) & ~0xff) | ((c) << 7) | ((m) << 6) | ((acc) << 2) | 2)
#define NCODE 12
	.text
	.globl _start
_start:
	mov	2, %l5			/* passes over the chain */
	mov	0, %o0
	set	0x00900000, %l1		/* a data page (identity) */
1:	set	0x60000000, %g1
	jmpl	%g1, %o7		/* into the mapped code */
	 add	%o0, 1, %o0
	st	%o0, [%l1]
	subcc	%l5, 1, %l5
	bne	1b
	 nop
#if IFAULT == 1
	set	0x70000000, %g1
#else
	set	0x60000000 + NCODE * 0x1000, %g1
#endif
	jmpl	%g1, %o7
	 nop
	nop

	/* the mapped code: page k at VA 0x60000000 + k*0x1000, PA 0xb00000 + k*0x1000 */
	.section .vcode, "ax"
	.set	k, 0
	.rept	NCODE
	.balign	4096
	add	%o0, k + 3, %o0
	sll	%o0, 1, %o1
	xor	%o0, %o1, %o0
	ld	[%l1 + 4 * k], %o2	/* the identity data page */
	add	%o0, %o2, %o0
	.if	k == NCODE - 1
	retl
	 nop
	.else
	set	0x60000000 + (k + 1) * 0x1000, %g2
	jmp	%g2
	 nop
	.endif
	.set	k, k + 1
	.endr
	.balign	4096
	/* page NCODE (read only, no execute): what IFAULT=2 jumps to */
	nop
	nop

	/* page tables at PA 0x800000 */
	.section .ptab, "aw"
	.align	1024
ctx_table:				/* 0x800000 */
	.word	PTD(0x800400)
	.skip	1020
l1:					/* 0x800400: VA[31:24] */
	.word	PTE(0x000000, 3, 1, 0)	/* VA 0-16 MB -> PA 0, RWX */
	.skip	(0x60 - 1) * 4
	.word	PTD(0x800800)		/* VA 0x60xxxxxx */
	.skip	(256 - 0x61) * 4	/* VA 0x70xxxxxx: invalid */
l2:					/* 0x800800 */
	.word	PTD(0x800900)
	.skip	63 * 4
l3:					/* 0x800900 */
	.set	k, 0
	.rept	NCODE
	.word	PTE(0xb00000 + k * 0x1000, 2, 1, 0)	/* RX */
	.set	k, k + 1
	.endr
	.word	PTE(0xb00000 + NCODE * 0x1000, 0, 1, 0)	/* read only */
	.skip	(64 - NCODE - 1) * 4
	.section .pages, "aw"
	.skip	0x1000
