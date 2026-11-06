/* ldstub / swap on ooo_core: bare metal, supervisor, ET=0, MMU off, like
 * wiggle.S.  Every result lands in a register (the per-retire compare) and the
 * locks/counters in memory (the halt-time memory compare).
 *   - cold (L1D miss) and hot atomics on each byte lane, rd = %g0
 *   - an older store / a younger load to the same word as an atomic
 *   - atomics whose line set holds a dirty line of another tag (16 KB stride)
 *   - a spinlock loop (ldstub acquire, stb %g0 release) around a counter
 *   - atomics on the path of an unpredictable branch (taken half the time: the
 *     wrong-path ones must not write) and in an annulled delay slot
 * Ends with `ta 0` (error mode); -DMISALIGN=1 ends with a misaligned swap
 * (mem_address_not_aligned, tt 7) instead.  Build like mmu_on.S, linked with
 * -Ttext=0x400000 only. */
	.text
	.globl _start
_start:
	set	words, %l0
	/* ---- ldstub, cold then hot, each lane ---- */
	ldstub	[%l0 + 0], %o0
	ldstub	[%l0 + 1], %o1
	ldstub	[%l0 + 2], %o2
	ldstub	[%l0 + 3], %o3
	ldstub	[%l0 + 0], %o4		/* 0xff now */
	ld	[%l0], %o5		/* 0xffffffff */
	ldstub	[%l0 + 0x16], %g0	/* rd = %g0: memory still written */
	ldub	[%l0 + 0x16], %g1
	/* ---- swap, cold then hot ---- */
	set	0x13579bdf, %g2
	swap	[%l0 + 0x20], %g2	/* %g2 = old 0x11223344 */
	set	0x2468ace0, %g3
	swap	[%l0 + 0x20], %g3	/* %g3 = 0x13579bdf */
	ld	[%l0 + 0x20], %g4	/* younger load: 0x2468ace0 */
	swap	[%l0 + 0x24], %g0	/* stores 0 */
	ld	[%l0 + 0x24], %g5
	/* ---- older store then atomic, same word and same line ---- */
	set	0x00abcdef, %o0
	st	%o0, [%l0 + 0x30]
	ldstub	[%l0 + 0x30], %o1	/* 0x00 (the stored byte) */
	ld	[%l0 + 0x30], %o2	/* 0xffabcdef */
	sth	%o0, [%l0 + 0x34]
	set	0x77777777, %o3
	swap	[%l0 + 0x34], %o3	/* 0xcdef0000 */
	stb	%o0, [%l0 + 0x3b]
	ldstub	[%l0 + 0x38], %o4	/* the old byte of the sibling word */
	ldub	[%l0 + 0x3b], %o5	/* 0xef */
	/* ---- dirty conflict victims: 8 lines, each with a dirty twin 16 KB away ---- */
	set	conf, %l1
	set	0x4000, %l2
	mov	8, %l3
1:	add	%l1, %l2, %l4
	st	%l3, [%l4]		/* dirty the twin */
	ldstub	[%l1 + 1], %o0		/* evicts it */
	add	%o0, %l3, %o0
	swap	[%l1 + 4], %o0
	st	%o0, [%l4 + 8]		/* back to the twin */
	subcc	%l3, 1, %l3
	bne	1b
	 add	%l1, 0x10, %l1
	/* ---- spinlock around a counter ---- */
	set	lock, %l1
	mov	50, %l3
2:	ldstub	[%l1], %o0
	tst	%o0
	bne	2b			/* never held: falls through */
	 nop
	ld	[%l1 + 4], %o1
	add	%o1, %l3, %o1
	st	%o1, [%l1 + 4]
	stbar
	stb	%g0, [%l1]		/* release */
	subcc	%l3, 1, %l3
	bne	2b
	 nop
	/* ---- atomics behind an unpredictable branch (xorshift low bit) ---- */
	set	0x2545f491, %l4
	set	cnt, %l1
	mov	64, %l3
3:	sll	%l4, 13, %o0
	xor	%l4, %o0, %l4
	srl	%l4, 17, %o0
	xor	%l4, %o0, %l4
	sll	%l4, 5, %o0
	xor	%l4, %o0, %l4
	andcc	%l4, 1, %g0
	be	4f
	 nop
	ldstub	[%l1 + 0], %o0		/* odd: lock byte and a swap of the count */
	ld	[%l1 + 4], %o1
	add	%o1, 1, %o1
	swap	[%l1 + 4], %o1
	stb	%g0, [%l1 + 0]
4:	andcc	%l4, 2, %g0
	bne,a	5f			/* annulled when not taken */
	 ldstub	[%l1 + 8], %o2
5:	subcc	%l3, 1, %l3
	bne	3b
	 ld	[%l1 + 8], %o3
	/* ---- a swap in a call's delay slot ---- */
	set	0xfeedface, %o4
	call	6f
	 swap	[%l1 + 12], %o4
6:	ld	[%l1 + 12], %o5
#if MISALIGN == 1
	swap	[%l0 + 2], %o4
#endif
	ta	0
	nop

	.data
	.align	16
words:	.word	0x01020304, 0, 0, 0, 0, 0x00005500, 0, 0
	.word	0x11223344, 0x55667788, 0, 0, 0, 0, 0x01020304, 0
lock:	.word	0, 0, 0, 0
cnt:	.word	0, 0, 0, 0
	.align	0x4000
conf:	.skip	0x4000 + 0x100
