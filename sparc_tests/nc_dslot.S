/* nc_dslot.S: a branch whose delay slot is the first word of the NEXT line, in
 * uncached code (the L1I's NC_TURNAROUND/NC_USE/NC_REREAD path).  OBP's reset loop
 * on Kodiak is exactly this shape -- `b .` at the last word of a line, `sta 1,
 * [sysctrl]` in its delay slot, the PROM mapped C=0 -- and it spun without
 * the reset taking effect.  The loop below counts in the delay slot, so the checker
 * catches a dropped or doubled delay slot.  Also a taken branch backward into the
 * same line and a call/ret pair across lines.
 * MMU on, low 16 MB identity mapped by nb_ptab.S (uncacheable by default).
 * Expected: %l1 = N (the delay slot ran once per iteration), %o5 = 3.
 * Build (as nb_boot.sh): clang -E -P -x assembler-with-cpp nc_dslot.S -o build/nc_dslot.s &&
 *   sparc64-linux-gnu-as -32 build/nc_dslot.s -o build/nc_dslot.o &&
 *   sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 \
 *     --section-start=.ptab=0x800000 -o build/nc_dslot.elf build/nc_dslot.o build/nb_ptab.o
 *   ../ooo_core -f build/nc_dslot.elf --mmu-ctrl 0x901 --mmu-ctpr 0x80000 --mmu-ctx 0 */
#define N	50
	.text
	.globl _start
_start:
	mov	N, %l0
	mov	0, %l1
	mov	0, %o5
	ba	loop
	 nop
	.align	64
	/* loop: the bne is the last word of its line (+0xc), its delay slot the next
	 * line's first word (+0x10) */
loop:	subcc	%l0, 1, %l0
	nop
	nop
	bne	loop
	 add	%l1, 1, %l1
	/* a backward branch within one line, three times */
	mov	3, %l2
1:	add	%o5, 1, %o5
	subcc	%l2, 1, %l2
	bne	1b
	 nop
	/* call and return across lines */
	call	fn
	 nop
	ta	0
	nop
	.align	16
	nop
	nop
	nop
fn:	retl				/* the last word of its line */
	 add	%o5, 0, %o5		/* the next line's first word */
