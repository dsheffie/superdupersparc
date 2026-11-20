/* A lock release followed at once by a window-overflow trap, as NeXTSTEP's
 * thread_sleep does it (the release Kodiak loses, NeXTSTEP "Checking disks"):
 *     clr  [lock]        release the interlock
 *     call thread_block
 *      clr %o0
 *     save               window_overflow (tt 5): save, wr %wim, 8 x std, restore,
 *                        wr %psr, rett -- NeXTSTEP's handler, with its rd/wr %psr
 * then a PIL raise (rd/wr %psr, splusclock) and a call chain of varying depth
 * (more overflows, then underflows on the way back), and the lock is read back:
 * the per-retire compare catches a lost release (and the halt-time memory
 * compare a lost store anywhere).  Each round acquires with ldstub and writes
 * an owner tag with stb into the lock's other bytes first, as the debug kernel
 * does, and stores to another word of the lock's line.
 * Bare metal, supervisor, ET=1, MMU off.  CONFLICT=1 puts the stack 64 KB above
 * the lock, so the spills land in the lock's direct-mapped L1D set.
 * POLL=1 adds uncached (ASI 0x20) loads of a status word, as a driver polls a
 * device: in the chain, before the acquire and right after block returns --
 * ooo_core --nack-dev-loads NACKs them while --snoop-storm snoops are queued.
 * Ends with `ta 0x7f` (tt 0xff) -> bad_trap -> error mode; a nonzero lock
 * read back takes `ta 0x7e` instead (tt 0xfe).
 * BOARD=1: bare metal on Kodiak under kodiak_arm --elf.  A PROM stub (.boot, at
 * PA 0 in both the PROM and RAM) clears boot mode and jumps to _start; the
 * rounds never end; POLL reads the NVRAM through the ARM window (lduba ASI
 * 0x2f), so the board's NACK path takes it while kodiak_arm --storm snoops;
 * the round count and a lost release go to a mailbox at MBOX by bypass stores,
 * which kodiak_arm prints. */
#define NW 8
#define ROUNDS 3000
#define MBOX 0x3ff000		/* [0] magic, [1] round, [2] lost marker, [3] lock word */
#if BOARD
#define POLL_LD(r, t) set 0xf1200000, r; lduba [r] 0x2f, t
#else
#define POLL_LD(r, t) set pw, r; lda [r] 0x20, t
#endif

#if BOARD
	.section .boot, "ax"
	/* reset, boot mode: MCR = MB | DE | AC (E = 0, BM = 0), as ooo_core's
	 * --mmu-ctrl default; the code is the same at RAM PA 0 for the refetch */
	set 0x8900, %g1
	sta %g1, [%g0] 4
	nop; nop; nop
	set _start, %g1
	jmp %g1
	 nop
#endif
	.text
	.align 4096
	.globl trap_table
trap_table:
	.rept 5
	rd %tbr, %g7; ba bad_trap; nop; nop
	.endr
	ba window_overflow; rd %psr, %l0; nop; nop	/* tt 0x05 */
	ba window_underflow; rd %psr, %l0; nop; nop	/* tt 0x06 */
	.rept 256 - 7
	rd %tbr, %g7; ba bad_trap; nop; nop
	.endr

bad_trap:			/* ET=0 here: ta 0 -> error mode -> the run ends */
	ta 0
	nop

/* NeXTSTEP's window_overflow (f0095f18), without its user-window branch */
window_overflow:
	mov %g1, %l7
	rd %wim, %l3
	srl %l3, 1, %g1
	sll %l3, NW-1, %l4
	or %l4, %g1, %g1
	save			/* into the oldest window */
	wr %g1, %wim
	std %l0, [%sp+0]
	std %l2, [%sp+8]
	std %l4, [%sp+16]
	std %l6, [%sp+24]
	std %i0, [%sp+32]
	std %i2, [%sp+40]
	std %i4, [%sp+48]
	std %i6, [%sp+56]
	restore
	wr %l0, %psr
	nop; nop; nop
	mov %l7, %g1
	jmp %l1			/* re-execute the save */
	rett %l2

window_underflow:
	rd %wim, %l3
	sll %l3, 1, %l4
	srl %l3, NW-1, %l5
	or %l5, %l4, %l5
	wr %l5, %wim
	nop; nop; nop
	restore
	restore			/* the window to fill */
	ldd [%sp+0], %l0
	ldd [%sp+8], %l2
	ldd [%sp+16], %l4
	ldd [%sp+24], %l6
	ldd [%sp+32], %i0
	ldd [%sp+40], %i2
	ldd [%sp+48], %i4
	ldd [%sp+56], %i6
	save
	save
	jmp %l1			/* re-execute the restore */
	rett %l2

/* thread_block stand-in: a PIL raise (splusclock), then a chain of %o0 more
 * frames, then the PIL back */
block:
	save %sp, -112, %sp
	rd %psr, %l2
	or %l2, 0xa00, %l3
	wr %l3, %psr
	nop; nop; nop
	call chain
	 mov %i0, %o0
	wr %l2, %psr
	nop; nop; nop
	ret
	 restore
chain:
	save %sp, -112, %sp
#if POLL
	POLL_LD(%l0, %l1)
#endif
	subcc %i0, 1, %o0
	bg,a chain_more
	 nop
	ret
	 restore
chain_more:
	call chain
	 nop
	ret
	 restore

	.globl _start
_start:
	set trap_table, %g1
	wr %g1, %tbr
	wr %g0, 2, %wim		/* CWP=0, window 1 invalid */
	set 0x00e0, %g1		/* S=1, PS=1, ET=1, PIL=0, CWP=0 */
	wr %g1, %psr
	nop; nop; nop
	set stack_top, %sp
	set lk, %g4
	set ROUNDS, %g5
	clr %g6			/* round number: picks the depths */
#if BOARD
	set MBOX, %g3
	set 0x52454c53, %g1	/* "RELS" */
	sta %g1, [%g3] 0x20
	add %g3, 8, %g1
	sta %g0, [%g1] 0x20
	add %g3, 4, %g2		/* the round count's word */
#endif
round:
	/* the release runs (round % 7) frames down, so the save right after it
	 * (block's) meets the invalid window in some rounds, as in the kernel */
	srl %g6, 3, %o0
	call sleeper_at
	 and %o0, 7, %o0
	inc %g6
#if BOARD
	ba round
	 sta %g6, [%g2] 0x20
#endif
	subcc %g5, 1, %g5
	bne round
	 nop
	ta 0x7f			/* clean end: tt 0xff */
	nop

sleeper_at:
	save %sp, -112, %sp
	tst %i0
	bne,a 1f
	 nop
	call sleeper
	 nop
	ret
	 restore
1:	call sleeper_at
	 sub %i0, 1, %o0
	ret
	 restore

sleeper:
	save %sp, -112, %sp
	mov %g4, %l0
	mov %g6, %l6
#if POLL
	POLL_LD(%l1, %l1)
#endif
	/* acquire, as simple_lock_try */
1:	ldstub [%l0 + 0x10], %l1
	tst %l1
	bne 1b
	 nop
	/* the debug kernel's owner tag, in the lock's other three bytes */
	srl %l6, 16, %l2
	stb %l2, [%l0 + 0x11]
	srl %l6, 8, %l2
	stb %l2, [%l0 + 0x12]
	stb %l6, [%l0 + 0x13]
	/* other data in the lock's line (the condition lock's fields) */
	st %l6, [%l0 + 0x18]
	/* depth 0-8 frames past block's own */
	and %l6, 7, %o0
	/* release + thread_block, exactly as thread_sleep */
	clr [%l0 + 0x10]
	call block
	 nop
#if POLL
	POLL_LD(%l1, %l1)
#endif
	ld [%l0 + 0x10], %l3
	tst %l3
	bne lost
	 nop
	ret
	 restore
lost:
#if BOARD
	add %g3, 12, %l4
	sta %l3, [%l4] 0x20
	set 0x10571057, %g1
	add %g3, 8, %l4
	sta %g1, [%l4] 0x20
	ba .
	 nop
#endif
	ta 0x7e			/* the release was lost: tt 0xfe */
	nop

	.data
	.align 64
pw:
	.word 0x5a5a5a5a
	.align 64
lk:
	.word 0, 0, 0, 0, 0, 0, 0, 0
	.word 0, 0, 0, 0, 0, 0, 0, 0
#if CONFLICT
	/* stack_top = lk + 64 KB + 224: block's caller frame (two below the top)
	 * spills to lk + 64 KB .. + 63, the lock line's direct-mapped L1D set */
	.space 0x10000 + 224 - 64
#else
	.space 8192
#endif
stack_top:
	.space 4096

	.section .note.GNU-stack,"",@progbits
