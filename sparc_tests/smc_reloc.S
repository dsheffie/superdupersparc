/* self-modifying code, NetBSD srt0.S style: routine R runs, and while it runs it
 * reads its own just-executed lines as DATA (srt0's self-relocation loop, which
 * also executes from lines it is reading).  Much later, R is overwritten by byte
 * stores (bootxx's memcpy of /boot over 0x4000) with a copy that differs in one
 * word (R+0x28, as /boot differs from bootxx), then R runs again.  No FLUSH: the
 * SuperSPARC I-cache is coherent with stores (machine.vh ENABLE_COHERENT_L1I).
 * Bare metal, supervisor, ET = 0, MMU off; ends with `ta 0`.
 * Expected: o1 = 1, o2 = 2 (o2 = 1 if the L1I kept the stale line).
 * Build: clang -E -P -x assembler-with-cpp smc_reloc.S -o build/smc_reloc.s &&
 *        sparc64-linux-gnu-as -32 build/smc_reloc.s -o build/smc_reloc.o &&
 *        sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 \
 *          -o build/smc_reloc.elf build/smc_reloc.o */
#ifndef DELAY
#define DELAY	100000
#endif
#define RLEN	0x50

	.macro	routine, marker
	set	R, %l0			/* 0x00 */
	set	buf, %l1		/* 0x08 */
	mov	RLEN, %l2		/* 0x10 */
	nop				/* 0x14 */
	nop
	nop
	nop				/* 0x20 */
	nop
	mov	\marker, %o5		/* 0x28: the word that differs */
	nop
1:	ld	[%l0], %o0		/* 0x30: read R itself as data */
	add	%l0, 4, %l0
	st	%o0, [%l1]
	subcc	%l2, 4, %l2
	bg	1b
	 add	%l1, 4, %l1
	retl
	 nop
	.endm

	.text
	.globl _start
_start:
	call	R			/* %o5 = 1 */
	 nop
	mov	%o5, %o1
	/* bootxx's memcpy: one byte at a time */
	set	src, %l3
	set	R, %l4
	mov	RLEN, %l5
1:	ldub	[%l3], %l6
	stb	%l6, [%l4]
	inc	%l3
	subcc	%l5, 1, %l5
	bne	1b
	 inc	%l4
	set	DELAY, %l5
2:	subcc	%l5, 1, %l5
	bne	2b
	 nop
	call	R			/* %o5 = 2 */
	 nop
	mov	%o5, %o2
	ta	0
	nop

	.align	64
R:	routine	1

	.align	64
src:	routine	2

	.align	64
buf:	.skip	RLEN

#ifdef MMU
/* -DMMU: run with ooo_core --mmu-ctrl 0x901 --mmu-ctpr 0x80000 --mmu-ctx 0 and
 * link with --section-start=.ptab=0x800000; the low 16 MB is identity mapped,
 * cacheable, by one level-1 PTE (as OBP maps the boot block's 0x4000) */
#define PTD(pa)		(((pa) >> 4) | 1)
#define PTE(pa, acc, c, m) ((((pa) >> 4) & ~0xff) | ((c) << 7) | ((m) << 6) | ((acc) << 2) | 2)
	.section .ptab, "aw"
	.align	1024
ctx_table:				/* 0x800000 */
	.word	PTD(0x800400)
	.skip	1020
l1:					/* 0x800400: VA[31:24] */
	.word	PTE(0x000000, 3, 1, 0)	/* VA 0-16 MB -> PA 0, RWX */
	.skip	255 * 4
#endif
