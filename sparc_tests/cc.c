#include "crt.h"
#define OPS(X) X(addcc) X(subcc) X(addxcc) X(subxcc) X(andcc) X(orcc) X(xorcc) X(andncc) X(orncc) X(xnorcc) \
  X(taddcc) X(tsubcc) X(umulcc) X(smulcc) X(mulscc) X(udivcc) X(addx) X(subx) X(sll) X(srl) X(sra)
#define DECL(op) unsigned t_##op(unsigned, unsigned, unsigned *, unsigned);
OPS(DECL)
unsigned t_mem(unsigned *);
unsigned t_annul(void);
static volatile unsigned v[] = {0, 1, 2, 3, 0x7fffffff, 0x80000000u, 0xffffffffu, 0xfffffffeu, 0x12345678, 31, 33};
int main(void) {
  unsigned out[2];
#define RUN(op) for(int i = 0; i < 11; i++) { for(int j = 0; j < 11; j++) { for(unsigned c = 0; c < 2; c++) { \
    unsigned b = v[j]; if(#op[0] == 'u' && #op[1] == 'd' && b == 0) { b = 9; } \
    puthex(t_##op(v[i], b, out, c)); puthex(out[0]); puthex(out[1]); } } }
  OPS(RUN)
  static unsigned buf[4] __attribute__((aligned(8))) = {0x0102f304, 0xa5a58001, 0, 0};
  puthex(t_mem(buf)); puthex(buf[0]); puthex(buf[1]); puthex(buf[2]); puthex(buf[3]);
  puthex(t_annul());
  return 0;
}
