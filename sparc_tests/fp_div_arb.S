/* fp_div_arb.S: the int and FP divides share the unified divider (uni_divider), and
 * r_div_turn (exec.sv, r9999 8714dd3) says which side may start one.  The turn
 * follows READINESS, so an int divide that waits on an FP divide's result must not
 * hold it.  SPARC has no mfc1: the FP result reaches the int side through memory.
 *   - chain: fdivd -> std -> ld -> udiv by it, several times
 *   - contention: fdivs / fsqrtd / sdiv / udiv back to back, in a loop
 * The checker compares every retired result; a deadlock shows as no clean end.
 * Bare metal, supervisor, ET=0, MMU off (as fp_mem.S); ends with `ta 0`.
 * Build: clang -E -P -x assembler-with-cpp fp_div_arb.S -o build/fp_div_arb.s &&
 *   sparc64-linux-gnu-as -32 build/fp_div_arb.s -o build/fp_div_arb.o &&
 *   sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 -o build/fp_div_arb.elf build/fp_div_arb.o */
	.text
	.globl _start
_start:
	rd	%psr, %g1
	set	0x1000, %g2		/* PSR.EF */
	or	%g1, %g2, %g1
	wr	%g1, %psr
	nop
	nop
	nop
	wr	%g0, 0, %y
	set	dat, %l0
	set	buf, %l1
	ldd	[%l0 + 0], %f0		/* 1000000.0 */
	ldd	[%l0 + 8], %f2		/* 7.0 */
	ld	[%l0 + 16], %f4		/* 3.0f */
	ld	[%l0 + 20], %f5		/* 9.0f */
	/* ---- chain: the int divide's divisor comes from an FP divide ---- */
	mov	4, %l2
	set	1000000, %o0
1:	fdivd	%f0, %f2, %f6		/* 142857.14... */
	fdtoi	%f6, %f8		/* 142857 */
	st	%f8, [%l1]
	ld	[%l1], %o1
	udiv	%o0, %o1, %o2		/* 1000000 / 142857 = 7 */
	add	%o3, %o2, %o3
	faddd	%f0, %f2, %f0		/* change the dividend for the next round */
	subcc	%l2, 1, %l2
	bne	1b
	 nop
	/* ---- contention: both sides want the divider back to back ---- */
	mov	16, %l2
	set	123456789, %o4
	mov	37, %o5
2:	fdivs	%f5, %f4, %f10		/* 3.0f */
	sdiv	%o4, %o5, %g3
	fsqrtd	%f0, %f12
	udiv	%o4, %o5, %g4
	fdivd	%f0, %f2, %f14
	sdiv	%g3, %o5, %g5
	fadds	%f10, %f4, %f4		/* the FP inputs change each round */
	add	%o5, 2, %o5
	add	%g3, %g4, %o3
	add	%o3, %g5, %o3
	subcc	%l2, 1, %l2
	bne	2b
	 nop
	std	%f12, [%l1 + 8]
	std	%f14, [%l1 + 16]
	st	%f4, [%l1 + 24]
	ta	0
	nop

	.align	8
dat:	.word	0x412e8480, 0		/* 1000000.0 */
	.word	0x401c0000, 0		/* 7.0 */
	.word	0x40400000		/* 3.0f */
	.word	0x41100000		/* 9.0f */
	.align	8
buf:	.skip	32
