! pmu_rd.s: read the superdupersparc PMU (decode_sparc.sv S_RDASR) from user mode.
!   void pmu_rd(unsigned long long *cycles, unsigned long long *insns)
! %asr16/17 = cycles [31:0]/[63:32], %asr18/19 = retired instructions.  Each
! 64-bit count is read hi, lo, hi, retrying if the high word moved.
! The reads are .words: SC4.2's assembler takes %asr16-19 for UltraSPARC
! registers (GSR is %asr19) and refuses them for a V8 target.
! Sun as (SC4.2 / Solaris 2.x): cc -o pmu pmu.c pmu_rd.s
	.section ".text"
	.align	4
	.global	pmu_rd
	.type	pmu_rd, #function
pmu_rd:
.Lpmu_c:
	.word	0x95444000		! rd %asr17, %o2
	.word	0x97440000		! rd %asr16, %o3
	.word	0x99444000		! rd %asr17, %o4
	cmp	%o2, %o4
	bne	.Lpmu_c
	nop
	st	%o2, [%o0]
	st	%o3, [%o0 + 4]
.Lpmu_i:
	.word	0x9544c000		! rd %asr19, %o2
	.word	0x97448000		! rd %asr18, %o3
	.word	0x9944c000		! rd %asr19, %o4
	cmp	%o2, %o4
	bne	.Lpmu_i
	nop
	st	%o2, [%o1]
	retl
	st	%o3, [%o1 + 4]
	.size	pmu_rd, . - pmu_rd
