/* unsigned t_<op>(a=%o0, b=%o1, unsigned out[2]=%o2, cin=%o3)
 * sets icc.C=cin and %y=cin, runs <op>, returns the result; out[0]=NZVC read back
 * through annulling branches (b<cc>,a executes its delay slot only when taken),
 * out[1]=%y */
#define CCTEST(op)			\
	.globl t_##op;			\
t_##op:					\
	wr %o3, 0, %y;			\
	nop; nop; nop;			\
	subcc %g0, %o3, %g0;		\
	op %o0, %o1, %o0;		\
	mov 0, %o4;			\
	bneg,a 1f;			\
	or %o4, 8, %o4;			\
1:	be,a 2f;			\
	or %o4, 4, %o4;			\
2:	bvs,a 3f;			\
	or %o4, 2, %o4;			\
3:	bcs,a 4f;			\
	or %o4, 1, %o4;			\
4:	st %o4, [%o2];			\
	rd %y, %o4;			\
	st %o4, [%o2+4];		\
	retl;				\
	nop

	.text
CCTEST(addcc)
CCTEST(subcc)
CCTEST(addxcc)
CCTEST(subxcc)
CCTEST(andcc)
CCTEST(orcc)
CCTEST(xorcc)
CCTEST(andncc)
CCTEST(orncc)
CCTEST(xnorcc)
CCTEST(taddcc)
CCTEST(tsubcc)
CCTEST(umulcc)
CCTEST(smulcc)
CCTEST(mulscc)
CCTEST(udivcc)
CCTEST(addx)
CCTEST(subx)
CCTEST(sll)
CCTEST(srl)
CCTEST(sra)

/* unsigned t_mem(unsigned *buf=%o0): ldstub, swap, ldd/std, signed loads */
	.globl t_mem
t_mem:
	mov 0x55, %o5
	ldstub [%o0+1], %o1
	swap [%o0+4], %o5
	ldd [%o0], %o2
	std %o2, [%o0+8]
	ldsb [%o0+3], %o4
	add %o1, %o4, %o1
	ldsh [%o0+6], %o4
	add %o1, %o4, %o1
	add %o1, %o5, %o1
	xor %o2, %o3, %o0
	retl
	add %o0, %o1, %o0

/* unsigned t_annul(void): ba,a / bn,a / bn / taken + not-taken annul, tne not taken */
	.globl t_annul
t_annul:
	mov 0, %o0
	ba,a 1f
	or %o0, 1, %o0		/* annulled */
1:	bn,a 2f
	or %o0, 2, %o0		/* annulled */
	or %o0, 4, %o0
2:	bn 3f
	or %o0, 8, %o0		/* executed */
3:	cmp %o0, %o0
	bne,a 4f
	or %o0, 16, %o0		/* annulled (not taken) */
	be,a 4f
	or %o0, 32, %o0		/* executed (taken) */
	or %o0, 64, %o0		/* skipped */
4:	tne 5			/* Z=1: not taken */
	retl
	nop

	.section .note.GNU-stack,"",@progbits
