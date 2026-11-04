#include "crt.h"
/* deep recursion: exercises SAVE/RESTORE through window spill/fill */
static int fib(int n) { return n < 2 ? n : fib(n-1) + fib(n-2); }
static unsigned divs(unsigned x) {
  unsigned acc = 0;
  for(int i = 1; i < 200; i++) {
    acc ^= (x / i) + (unsigned)((int)(x - 77777*i) / (i - 100 ? i - 100 : 3)) + (x % (i+3));
    x = x * 1103515245u + 12345u;
  }
  return acc;
}
int main(void) {
  puts_("fib(24) = "); puthex(fib(24));
  puts_("divs = "); puthex(divs(12345));
  long long a = 0x123456789abcdefLL, b = 0x13579bdf;
  puts_("ll = "); puthex((unsigned)((a * b) >> 17)); puthex((unsigned)(a / b));
  return 0;
}
