/* First ooo_core bring-up test: bare metal, supervisor, ET=0 (the reset PSR), no
 * traps taken until the end.  Integer ALU, sethi, icc (cmp/subcc + bne, a
 * cc op to %g0), loads/stores, call/ret with save/restore (WIM=0: no window
 * traps), an annulled branch.  Ends with `ta 0`: with ET=0 that is error mode,
 * which halts the ISS. */
	.text
	.globl _start
_start:
	set	stack + 4096 - 96, %sp
	set	data, %o0
	mov	8, %o1
	clr	%o2
1:	ld	[%o0], %o3
	add	%o2, %o3, %o2
	add	%o0, 4, %o0
	subcc	%o1, 1, %o1
	bne	1b
	 nop
	st	%o2, [%o0]		/* sum of data[0..7] */
	call	twice
	 mov	%o2, %o0
	mov	%o0, %g2
	sethi	%hi(0x12345678), %g3
	or	%g3, %lo(0x12345678), %g3
	xor	%g3, %g2, %g4
	sll	%g4, 3, %g5
	srl	%g5, 7, %g6
	sra	%g3, 4, %g7
	orcc	%g0, %g0, %g0		/* Z=1 */
	bne,a	2f			/* not taken: the slot is annulled */
	 add	%g7, 1, %g7
	be	2f
	 add	%g6, 1, %g6
2:	ldub	[%o0 - 4], %g1
	stb	%g1, [%o0 + 7]
	ldsh	[%o0 + 6], %g1
	/* ldd: rd+1 consumed right away (its late wakeup), then rd */
	set	data, %l0
	ldd	[%l0 + 8], %l2		/* %l2 = 3, %l3 = 4 */
	add	%l3, 100, %l4
	add	%l2, %l4, %l5
	mov	16, %l6
	ldd	[%l0 + %l6], %o4	/* reg+reg: %o4 = 5, %o5 = 6 */
	sub	%o5, %o4, %l7
	ldd	[%l0], %g0		/* %g0 half dropped: %g1 = 2 */
	add	%g1, %l7, %g1
	/* std: the pair back to memory, read back by ldd (imm and reg+reg) */
	std	%l2, [%l0 + 32]		/* data[8] = 3, data[9] = 4 */
	mov	40, %l6
	std	%o4, [%l0 + %l6]	/* data[10] = 5, data[11] = 6 */
	ldd	[%l0 + 32], %i0
	ldd	[%l0 + 40], %i2
	add	%i1, %i3, %i4		/* 4 + 6 */
	/* ldd stress: back-to-back ldds between plain loads, both halves consumed
	 * at once, so the parked rd+1 has to find a free writeback slot */
	clr	%g5
	mov	20, %l7
4:	ldd	[%l0], %o0
	ld	[%l0 + 8], %o2
	ldd	[%l0 + 16], %o4
	ld	[%l0 + 12], %o3
	ldd	[%l0 + 32], %i0
	add	%o1, %o5, %l1
	add	%l1, %i1, %l1
	add	%o0, %o4, %l2
	add	%l2, %i0, %l2
	add	%o2, %o3, %l3
	add	%g5, %l1, %g5
	add	%g5, %l2, %g5
	subcc	%l7, 1, %l7
	bne	4b
	 add	%g5, %l3, %g5
	cmp	%l5, 1			/* a nonzero result into %g0 */
	bg	3f
	 nop
	mov	-1, %g1
3:	ta	0

twice:
	save	%sp, -96, %sp
	add	%i0, %i0, %i0
	ret
	 restore

	.data
	.align	4
data:	.word	1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 0
	.align	16
stack:	.skip	4096
