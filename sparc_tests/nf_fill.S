/* MCR.NF window fill, as Solaris 2.5.1's _sys_rtt does it for a user window
 * (unix f0041720..f004176c): set NF, clear the SFSR, restore, ldd the window
 * from [%sp] (here an unmapped page: every load walks and faults), save, clear
 * NF, read the SFAR and SFSR.  With NF the faults are recorded, not trapped:
 * each faulting ldd is skipped (core.sv w_nf_skip, a pipeline restart) and its
 * rd keeps its value.  Kodiak silicon livelocked here (bit_b7e_nopipe_npf1).
 * Bare metal, supervisor, ET=0, WIM=0 (save/restore never trap), MMU on:
 *   ooo_core -f nf_fill.elf --mmu-ctrl 0x901 --mmu-ctpr 0x80000 --mmu-ctx 0
 * VA 0-16 MB is identity mapped by one level-1 PTE; VA 0x50xxxxxx is invalid
 * at level 1.  Ends with `ta 0` (error mode). */
#define PTD(pa)		(((pa) >> 4) | 1)
#define PTE(pa, acc, c, m) ((((pa) >> 4) & ~0xff) | ((c) << 7) | ((m) << 6) | ((acc) << 2) | 2)
/* SPBASE/STRIDE: where the window is loaded from, and how far it moves per
 * iteration; SPBASE 0x00ffffe0 STRIDE 0 straddles the last mapped page and the
 * unmapped 0x01000000 (older loads hit, younger ones fault) */
#ifndef SPBASE
#define SPBASE 0x50000000
#endif
#ifndef STRIDE
#define STRIDE 0x1000
#endif
#define ITERS 64
	.text
	.globl _start
_start:
	wr	%g0, %wim
	nop
	nop
	nop
	set	SPBASE, %g6		/* the "user stack" */
	set	STRIDE, %g7
	mov	ITERS, %g5
	mov	0, %g4			/* checksum of the SFAR/SFSR values */
1:	mov	%g6, %i6		/* the restored window's %sp */
	set	0x11111111, %l0		/* the values the skipped loads must keep */
	mov	0x300, %g1
	lda	[%g1] 4, %g0		/* read (clear) the SFSR */
	lda	[%g0] 4, %g2
	or	%g2, 2, %g2
	sta	%g2, [%g0] 4		/* NF on */
	restore
	ldd	[%sp], %l0
	ldd	[%sp + 8], %l2
	ldd	[%sp + 0x10], %l4
	ldd	[%sp + 0x18], %l6
	ldd	[%sp + 0x20], %i0
	ldd	[%sp + 0x28], %i2
	ldd	[%sp + 0x30], %i4
	ldd	[%sp + 0x38], %fp
	save
	andn	%g2, 2, %g2
	sta	%g2, [%g0] 4		/* NF off */
	mov	0x400, %g3
	lda	[%g3] 4, %g3		/* SFAR */
	lda	[%g1] 4, %g1		/* SFSR */
	add	%g4, %g3, %g4
	xor	%g4, %g1, %g4
	add	%g6, %g7, %g6		/* next page */
	subcc	%g5, 1, %g5
	bne	1b
	 nop
	ta	0

	/* page tables at PA 0x800000 (ld --section-start=.ptab=0x800000) */
	.section .ptab, "aw"
	.align	1024
ctx_table:				/* 0x800000 */
	.word	PTD(0x800400)
	.skip	1020
l1:					/* 0x800400: VA[31:24] */
	.word	PTE(0x000000, 3, 1, 0)	/* VA 0-16 MB -> PA 0, RWX */
	.skip	255 * 4			/* everything else (0x50xxxxxx) invalid */
