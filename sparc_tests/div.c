#include "crt.h"
/* udiv/sdiv/umul/smul and the %y plumbing */
static volatile unsigned uv[] = {0, 1, 7, 0x7fffffff, 0x80000000u, 0xffffffffu, 12345, 0xdeadbeefu};
static volatile int sv[] = {1, -1, 3, -3, 7, -100, 0x7fffffff, (int)0x80000000};
int main(void) {
  for(int i = 0; i < 8; i++) {
    for(int j = 0; j < 8; j++) {
      unsigned a = uv[i], b = uv[j] ? uv[j] : 5;
      int x = sv[i], y = sv[j];
      puthex(a / b); puthex(a % b);
      if(!(x == (int)0x80000000 && y == -1)) { puthex((unsigned)(x / y)); puthex((unsigned)(x % y)); }
      puthex(a * b); puthex((unsigned)(((unsigned long long)a * b) >> 32));
      puthex((unsigned)(((long long)x * y) >> 32));
    }
  }
  return 0;
}
