/* rst_loop.S: OBP's reset loop (ffd27994..ffd279a0) -- `b .` as the last word of a
 * line with `sta 1, [sysctrl] 0x2f` in its delay slot -- run from a page mapped by
 * nb_ptab.S (CBIT 0 = uncached code, the L1I's NC path).  On kodiak_tb the reset
 * sequencer must start ([SYSRST] 0 -> 1); it spun forever on the board. */
	.text
	.globl _start
_start:
#ifdef DIRTY
	/* dirty a lot of the caches first (as a running OS leaves them): 1 MB of stores
	 * at PA 0x900000 (identity mapped by nb_ptab, cacheable with CBIT=1) */
	set	0x100000, %l0
	set	0x00900000, %l1
2:	st	%l0, [%l1 + %l0]
	subcc	%l0, 16, %l0
	bne	2b
	 nop
#endif
	ba	go
	 nop
	.align	64
go:	nop
	sethi	%hi(0xf1f00000), %l3
	mov	1, %l4
1:	b	1b			/* +0xc: the last word of the line */
	 sta	%l4, [%l3] 0x2f		/* +0x10: the next line's first word */
