/* self-modifying code: stores rewrite instructions that have already executed
 * (so an ISS with a decoded-instruction cache holds them), then run them again.
 * Bare metal, supervisor, ET = 0, MMU off, like atomic.S; ends with `ta 0`.
 * Covers the store paths a decoded page must notice:
 *   st / stb / std   (MMU off: ss10sim's exec_slow -> st_phys)
 *   sta / stba 0x20  (MMU bypass ASI: ss10sim's op_ldst fast path)
 * and a store to an instruction a few words ahead on the same page.
 * Expected: o1 = 1, o2 = 2, o3 = 3, o4 = 4, o5 = 5, l5 = 6, l6 = 7 (l6 = 5 if a
 * stale decode ran).
 * Build: clang -E -P -x assembler-with-cpp smc.S -o build/smc.s &&
 *        sparc64-linux-gnu-as -32 build/smc.s -o build/smc.o &&
 *        sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 \
 *          -o build/smc.elf build/smc.o */
#define MOV_O0(n)	(0x90102000 | (n))	/* or %g0, n, %o0 */
	.text
	.globl _start
_start:
	set	tgt, %l0
	call	tgt			/* %o0 = 1 */
	 nop
	mov	%o0, %o1
	set	MOV_O0(2), %l1
	st	%l1, [%l0]		/* st: tgt is now mov 2, %o0 */
	call	tgt
	 nop
	mov	%o0, %o2
	mov	3, %l2
	stb	%l2, [%l0 + 3]		/* stb: the immediate's low byte */
	call	tgt
	 nop
	mov	%o0, %o3
	set	MOV_O0(4), %g2		/* std: both words (the second is retl) */
	ld	[%l0 + 4], %g3
	std	%g2, [%l0]
	call	tgt
	 nop
	mov	%o0, %o4
	set	MOV_O0(5), %l1
	sta	%l1, [%l0] 0x20		/* sta, bypass ASI */
	call	tgt
	 nop
	mov	%o0, %o5
	mov	6, %l2
	add	%l0, 3, %l7
	stba	%l2, [%l7] 0x20		/* stba, bypass ASI (no immediate form) */
	call	tgt
	 nop
	mov	%o0, %l5
	/* the same page, a few words ahead: run the loop body once as mov 5,
	 * then patch it to mov 7 and run it again */
	set	ahead, %l3
	mov	2, %l4
1:	nop
ahead:	mov	5, %o0
	mov	%o0, %l6
	set	MOV_O0(7), %l1
	st	%l1, [%l3]
	subcc	%l4, 1, %l4
	bne	1b
	 nop
	ta	0
	nop

	.align	8
tgt:	mov	1, %o0
	retl
	 nop
