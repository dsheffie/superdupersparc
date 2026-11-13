/* L2 set conflicts across ways (l2.sv L2_WAYS): every line this test touches
 * is in ONE L2 set (and its neighbour, +16 bytes) for any L2 of up to 2^15 sets
 * per way, so 2-, 3- and 4-way L2s keep choosing victims there.  Lines are
 * 0x400000 + k * 512 KB:
 *   k = 0      the code of the loop below (the L1I holds it: an L2 victim with pi)
 *   k = 1..8   data, loaded and stored (the L1D writes dirty lines back to the
 *              L2, so victims are dirty; a clean L1D eviction leaves pd set, so
 *              victims are probed)
 *   k = 9..11  three two-instruction routines, called at random: an L1I miss
 *              that can evict a line the L1D holds (a real back-invalidate)
 * Loads read every k (code too).  A xorshift32 picks op, k and the word.
 * The loads land in registers (the per-retire compare) and the stores in
 * memory (the halt-time memory compare, after the L2 flush walks every way).
 * Bare metal, supervisor, ET=0, MMU off, like wiggle.S.  Ends with `ta 0`.
 * Build:  sparc64-linux-gnu-as -32 -Av8 -o l2_ways.o l2_ways.S
 *         sparc64-linux-gnu-ld -m elf32_sparc -Ttext=0x400000 --section-start=.r9=0x880000
 *           --section-start=.r10=0x900000 --section-start=.r11=0x980000 -o l2_ways.elf l2_ways.o */
	.ifndef ITERS
	.equ	ITERS, 4000		/* --defsym ITERS=n for a longer run */
	.endif
	.text
	.globl _start
_start:
	set	0x2545f491, %g1		/* xorshift32 state */
	set	ITERS, %g2
	set	0x00400000, %g3		/* line k = %g3 + (k << 19) */
	clr	%l5			/* xor of everything loaded */
loop:
	sll	%g1, 13, %o0
	xor	%g1, %o0, %g1
	srl	%g1, 17, %o0
	xor	%g1, %o0, %g1
	sll	%g1, 5, %o0
	xor	%g1, %o0, %g1
	/* the word: bits 3:2 of the offset from r[9:8], the neighbouring set from r[20] */
	srl	%g1, 8, %o1
	and	%o1, 0xc, %o1
	srl	%g1, 16, %o2
	and	%o2, 0x10, %o2
	or	%o1, %o2, %o1
	srl	%g1, 12, %o3
	and	%o3, 3, %o3
	cmp	%o3, 1
	be	do_store
	 cmp	%o3, 2
	be	do_call
	 nop
	/* a load (op 0 or 3) from line k = r[3:0], 12..15 folded onto 8..11 */
	and	%g1, 15, %o4
	cmp	%o4, 12
	bge,a	1f
	 sub	%o4, 4, %o4
1:	sll	%o4, 19, %o5
	add	%o5, %g3, %o5
	ld	[%o5 + %o1], %l0
	ba	next
	 xor	%l5, %l0, %l5
do_store:
	/* a store to data line k = 1 + r[2:0] */
	and	%g1, 7, %o4
	add	%o4, 1, %o4
	sll	%o4, 19, %o5
	add	%o5, %g3, %o5
	ba	next
	 st	%g1, [%o5 + %o1]
do_call:
	/* a call to routine k = 9 + (r[15:14] mod 3) */
	srl	%g1, 14, %o4
	and	%o4, 3, %o4
	cmp	%o4, 3
	be,a	2f
	 clr	%o4
2:	add	%o4, 9, %o4
	sll	%o4, 19, %o5
	add	%o5, %g3, %o5
	jmpl	%o5, %o7
	 nop
	xor	%l5, %o0, %l5
next:
	subcc	%g2, 1, %g2
	bne	loop
	 nop
	/* read back every word of every line */
	clr	%o4
3:	sll	%o4, 19, %o5
	add	%o5, %g3, %o5
	ld	[%o5 + 0x00], %l0
	xor	%l5, %l0, %l5
	ld	[%o5 + 0x04], %l0
	xor	%l5, %l0, %l5
	ld	[%o5 + 0x08], %l0
	xor	%l5, %l0, %l5
	ld	[%o5 + 0x0c], %l0
	xor	%l5, %l0, %l5
	ld	[%o5 + 0x10], %l0
	xor	%l5, %l0, %l5
	ld	[%o5 + 0x14], %l0
	xor	%l5, %l0, %l5
	ld	[%o5 + 0x18], %l0
	xor	%l5, %l0, %l5
	ld	[%o5 + 0x1c], %l0
	xor	%l5, %l0, %l5
	add	%o4, 1, %o4
	cmp	%o4, 12
	bne	3b
	 nop
	ta	0

	.section .r9, "ax"
	retl
	 add	%o0, 9, %o0
	.section .r10, "ax"
	retl
	 add	%o0, 10, %o0
	.section .r11, "ax"
	retl
	 add	%o0, 11, %o0
