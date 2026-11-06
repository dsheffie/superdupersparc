/* Bare-metal supervisor runtime (sv.c, mmu.c): real trap table, the textbook window
 * overflow/underflow handlers (jmp %l1; rett %l2 DCTI couples), a software trap
 * (ta 1) that returns past itself.  Ends in error mode (a trap with ET=0) with
 * %g7 = tbr (tt 0xff = clean exit), %g6 = main's return value and
 * %g5 = the number of ta 1 traps taken. */
#define NW 8
	.text
	.align 4096
	.globl trap_table
trap_table:
	.rept 5
	rd %tbr, %g7; ba bad_trap; nop; nop
	.endr
	ba window_overflow; nop; nop; nop	/* tt 0x05 */
	ba window_underflow; nop; nop; nop	/* tt 0x06 */
	rd %tbr, %g7; ba bad_trap; nop; nop
	ba fp_trap; nop; nop; nop		/* tt 0x08 */
	ba data_fault; nop; nop; nop		/* tt 0x09 */
	.rept 0x11 - 10
	rd %tbr, %g7; ba bad_trap; nop; nop
	.endr
	.rept 15				/* tt 0x11-0x1f: interrupt levels 1-15 */
	ba irq_trap; nop; nop; nop
	.endr
	.rept 0x81 - 0x20
	rd %tbr, %g7; ba bad_trap; nop; nop
	.endr
	ba soft_trap; nop; nop; nop		/* tt 0x81: ta 1 */
	.rept 256 - 0x82
	rd %tbr, %g7; ba bad_trap; nop; nop
	.endr

bad_trap:			/* ET=0 here: ta 0 -> error mode -> ISS halts */
	ta 0
	nop

window_overflow:
	mov %wim, %l3
	mov %g1, %l7
	srl %l3, 1, %g1
	sll %l3, NW-1, %l4
	or %l4, %g1, %g1
	save			/* into the oldest window */
	mov %g1, %wim
	nop; nop; nop
	std %l0, [%sp+0]
	std %l2, [%sp+8]
	std %l4, [%sp+16]
	std %l6, [%sp+24]
	std %i0, [%sp+32]
	std %i2, [%sp+40]
	std %i4, [%sp+48]
	std %i6, [%sp+56]
	restore
	mov %l7, %g1
	jmp %l1			/* re-execute the save */
	rett %l2

window_underflow:
	mov %wim, %l3
	sll %l3, 1, %l4
	srl %l3, NW-1, %l5
	or %l5, %l4, %l5
	mov %l5, %wim
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

/* data_access_exception: capture the SRMMU fault status (read-to-clear) and
 * address into mmu_fsr_seen/mmu_far_seen, count it, skip the faulting insn */
	.globl mmu_fsr_seen, mmu_far_seen, mmu_faults
data_fault:
	set 0x300, %l4
	lda [%l4] 4, %l5
	set mmu_fsr_seen, %l6
	st %l5, [%l6]
	set 0x400, %l4
	lda [%l4] 4, %l5
	set mmu_far_seen, %l6
	st %l5, [%l6]
	set mmu_faults, %l6
	ld [%l6], %l5
	add %l5, 1, %l5
	st %l5, [%l6]
	jmp %l2
	rett %l2 + 4

/* interrupt level n (tt 0x10+n): record n in irq_seen, count it, clear soft
 * interrupt n at the CPU 0 slave interrupt controller (PA 0xff1400004, via the
 * ASI 0x2f MMU bypass), and return to the interrupted insn */
	.globl irq_seen, irq_count
irq_trap:
	rd %tbr, %l4
	srl %l4, 4, %l4
	and %l4, 0xf, %l4
	set irq_seen, %l6
	st %l4, [%l6]
	set irq_count, %l6
	ld [%l6], %l5
	add %l5, 1, %l5
	st %l5, [%l6]
	add %l4, 16, %l4
	mov 1, %l5
	sll %l5, %l4, %l5
	set 0xf1400004, %l6
	sta %l5, [%l6] 0x2f
	jmp %l1
	rett %l2

/* fp_exception (precise, the FQ empty): log the FSR (its ftt says why) and skip
 * the FPop, leaving its destination as it was -- an OS would emulate it here */
	.globl fp_traps, fp_fsr_log
fp_trap:
	set fp_traps, %l4
	ld [%l4], %l5
	and %l5, 63, %l6
	sll %l6, 2, %l6
	set fp_fsr_log, %l7
	st %fsr, [%l7 + %l6]
	add %l5, 1, %l5
	st %l5, [%l4]
	jmp %l2
	rett %l2 + 4

soft_trap:			/* g5++, resume after the ta */
	add %g5, 1, %g5
	jmp %l2
	rett %l2 + 4

	.globl _start
_start:
	set trap_table, %g1
	mov %g1, %tbr
	mov 2, %wim		/* CWP=0, window 1 invalid */
	set 0x10e0, %g1		/* EF=1, S=1, ET=1, PIL=0, CWP=0 */
	mov %g1, %psr
	nop; nop; nop
	set stack_top, %sp
	mov 0, %g5
	call main
	nop
	mov %o0, %g6
	ta 0x7f			/* -> bad_trap with tt 0xff */
	nop

	.data
	.align 4
mmu_fsr_seen:	.word 0
mmu_far_seen:	.word 0
mmu_faults:	.word 0
irq_seen:	.word 0
irq_count:	.word 0
fp_traps:	.word 0
fp_fsr_log:	.skip 256

	.bss
	.align 16
	.space 65536
stack_top:
	.space 128

	.section .note.GNU-stack,"",@progbits
