/* Integer PRF bank pressure on ooo_core: bare metal, supervisor, ET=0, WIM=0
 * (save/restore never trap), like wiggle.S.  core.sv allocates ALU results only
 * from the low half of the PRF and loads only from the high half, so ALU writes
 * migrate architectural registers into the ALU half.  This writes every one of
 * the 136 windowed arch registers (8 globals + 16 per window x 8 windows) with
 * an ALU op, round after round, which drives them all into the ALU half: if a
 * half cannot hold 136 arch registers plus the in-flight destinations, ALU ops
 * can no longer allocate (the hang machine.vh describes at 256 entries).  Then
 * loads refill every register (pulling them back to the MEM half) and the ALU
 * rounds repeat.  Each window's values depend on the window and the round, so
 * the per-retire compare checks them all.  Ends with `ta 0` (error mode). */
#define ROUNDS 6
	.text
	.globl _start
_start:
	wr	%g0, 0, %wim
	nop
	nop
	nop
	set	data, %g7
	mov	ROUNDS, %g6
1:	/* ---- ALU round: 8 windows x (8 locals + 8 outs), plus %g1-%g5 ---- */
	mov	8, %g5
2:	add	%g6, %g5, %g1
	add	%g1, 1, %l0
	add	%g1, 2, %l1
	add	%g1, 3, %l2
	add	%g1, 4, %l3
	add	%g1, 5, %l4
	add	%g1, 6, %l5
	add	%g1, 7, %l6
	add	%g1, 8, %l7
	add	%g1, 9, %o0
	add	%g1, 10, %o1
	add	%g1, 11, %o2
	add	%g1, 12, %o3
	add	%g1, 13, %o4
	add	%g1, 14, %o5
	add	%g1, 15, %o6
	add	%g1, 16, %o7
	add	%g1, 17, %g2
	add	%g1, 18, %g3
	add	%g1, 19, %g4
	subcc	%g5, 1, %g5
	bne	2b
	 save	%g0, 0, %g0		/* next window (CWP - 1 mod 8) */
	/* ---- load round: every window's locals and outs from memory ---- */
	mov	8, %g5
3:	ld	[%g7 + 0], %l0
	ld	[%g7 + 4], %l1
	ld	[%g7 + 8], %l2
	ld	[%g7 + 12], %l3
	ld	[%g7 + 16], %l4
	ld	[%g7 + 20], %l5
	ld	[%g7 + 24], %l6
	ld	[%g7 + 28], %l7
	ld	[%g7 + 32], %o0
	ld	[%g7 + 36], %o1
	ld	[%g7 + 40], %o2
	ld	[%g7 + 44], %o3
	ld	[%g7 + 48], %o4
	ld	[%g7 + 52], %o5
	ld	[%g7 + 56], %o6
	ld	[%g7 + 60], %o7
	subcc	%g5, 1, %g5
	bne	3b
	 restore %g0, 0, %g0
	subcc	%g6, 1, %g6
	bne	1b
	 nop
	ta	0
	 nop

	.data
	.align	8
data:
	.word	0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
	.word	0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x100
