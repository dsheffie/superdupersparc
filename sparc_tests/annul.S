/* Annulling conditional branches (b<cond>,a / fb<cond>,a) on ooo_core, linked
 * with sv_asm.S (trap table, ta 1 resumes at its nPC, %g6 = main's return).
 * l1i.sv predicts them like any conditional: predicted taken, the slot follows;
 * predicted not taken, fetch skips the (annulled) slot, and a taken outcome
 * restarts into it (PC = branch + 4, nPC = target; core.sv annul_skip).  The
 * outcomes come from a xorshift, so all four {predicted, actual} pairs occur.
 * Each slot bumps a counter that must move exactly when the branch is taken, so
 * a run or a skipped slot shows in the per-retire register compare.
 *   1  be,a forward, slot = add
 *   2  bne,a backward (a loop whose slot is the next pass's first insn), slot = ld
 *   3  be,a with ta 1 in its slot: a trap in a restarted slot (nPC = target)
 *   4  fbl,a on an fcmps of random values, slot = add
 * Build: clang -E -P -x assembler-with-cpp, as -32 -Av8, link with sv_asm.o. */
#define N 300

	.text
	.align 4
	.globl main
main:
	save	%sp, -96, %sp
	set	0x2545f491, %g1		/* xorshift state */
	clr	%l0			/* case 1 taken (slot) count */
	clr	%l1			/* case 1 not-taken count */
	clr	%l2			/* case 2 slot loads summed */
	clr	%l3			/* case 4 slot count */
	clr	%l4			/* case 4 not-taken count */
	set	data, %o0
	mov	N, %i5

loop:
	/* xorshift32: g1 ^= g1 << 13; g1 ^= g1 >> 17; g1 ^= g1 << 5 */
	sll	%g1, 13, %g2
	xor	%g1, %g2, %g1
	srl	%g1, 17, %g2
	xor	%g1, %g2, %g1
	sll	%g1, 5, %g2
	xor	%g1, %g2, %g1

	/* ---- 1: be,a forward ---- */
	andcc	%g1, 1, %g0
	be,a	1f
	 add	%l0, 1, %l0		/* only when taken */
	add	%l1, 1, %l1		/* only when not taken */
1:
	/* ---- 2: bne,a backward, 0..3 extra passes, slot = a load ---- */
	and	%g1, 6, %g3		/* 0, 2, 4, 6 */
	srl	%g3, 1, %g3
	ld	[%o0], %g4
2:	subcc	%g3, 1, %g3
	bge,a	2b
	 ld	[%o0 + 4], %g4		/* only when taken */
	add	%l2, %g4, %l2

	/* ---- 3: be,a with a software trap in its slot ---- */
	andcc	%g1, 0x100, %g0
	be,a	3f
	 ta	1			/* only when taken: %g5++, resumes at 3f */
	nop
3:
	/* ---- 4: fbl,a on fcmps of two random values ---- */
	srl	%g1, 8, %g2
	and	%g2, 0xff, %g2
	st	%g2, [%o0 + 8]
	srl	%g1, 16, %g2
	and	%g2, 0xff, %g2
	st	%g2, [%o0 + 12]
	ld	[%o0 + 8], %f0
	ld	[%o0 + 12], %f1
	fitos	%f0, %f0
	fitos	%f1, %f1
	fcmps	%f0, %f1
	nop
	fbl,a	4f
	 add	%l3, 1, %l3		/* only when taken */
	add	%l4, 1, %l4		/* only when not taken */
4:
	subcc	%i5, 1, %i5
	bne	loop
	 nop

	/* checksum: every counter, so the halt-time compare sees them too */
	add	%l0, %l1, %i0
	sll	%i0, 4, %i0
	add	%i0, %l2, %i0
	add	%i0, %l3, %i0
	add	%i0, %l4, %i0
	add	%i0, %g5, %i0
	ret
	 restore

	.data
	.align 8
data:	.word	1, 2, 0, 0
