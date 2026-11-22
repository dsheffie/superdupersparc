/* self-modifying code, NetBSD bootxx style: run code at tgt, byte-copy new code
 * over it from src with a loop (no FLUSH), spin DELAY iterations so every store
 * has long drained, then run tgt again.  The SuperSPARC's I-cache is coherent
 * with stores (machine.vh ENABLE_COHERENT_L1I), so the second call must see the
 * new code.  Bare metal, supervisor, ET = 0, MMU off; ends with `ta 0`.
 * Expected: o1 = 1, o2 = 2 (o2 = 1 if the L1I kept the stale line).
 * Build: clang -E -P -x assembler-with-cpp smc_copy.S -o build/smc_copy.s &&
 *        sparc64-linux-gnu-as -32 build/smc_copy.s -o build/smc_copy.o &&
 *        sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 \
 *          -o build/smc_copy.elf build/smc_copy.o */
#ifndef DELAY
#define DELAY	1000
#endif
	.text
	.globl _start
_start:
	set	tgt, %l0
#ifdef PRESTORE
	/* OBP-style: the code is written by CPU stores (dirty in the L1D) before it runs */
	set	0x90102001, %l1		/* mov 1, %o0 */
	st	%l1, [%l0]
#endif
	call	tgt			/* %o0 = 1 */
	 nop
	mov	%o0, %o1
	/* bootxx's copy: one byte at a time */
	set	src, %l1
	mov	16, %l2
	mov	%l0, %l3
1:	ldub	[%l1], %l4
	stb	%l4, [%l3]
	inc	%l1
	subcc	%l2, 1, %l2
	bne	1b
	 inc	%l3
	set	DELAY, %l5
2:	subcc	%l5, 1, %l5
	bne	2b
	 nop
	call	tgt			/* %o0 = 2 */
	 nop
	mov	%o0, %o2
	ta	0
	nop

	.align	64
tgt:	mov	1, %o0
	retl
	 nop
	nop

	.align	16
src:	mov	2, %o0
	retl
	 nop
	nop
