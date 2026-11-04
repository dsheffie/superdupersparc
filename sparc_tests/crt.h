/* freestanding Linux sparc32 user-mode runtime: runs under qemu-sparc and
 * sparc_iss --user.  _start sets its own %sp so register state is deterministic. */
static inline long sys3(long n, long a, long b, long c) {
  register long g1 asm("g1") = n;
  register long o0 asm("o0") = a;
  register long o1 asm("o1") = b;
  register long o2 asm("o2") = c;
  asm volatile("ta 0x10" : "+r"(o0) : "r"(g1), "r"(o1), "r"(o2) : "memory", "cc");
  return o0;
}
static void sys_exit(int c) { sys3(1, c, 0, 0); for(;;); }
static unsigned slen(const char *s) { unsigned n = 0; while(s[n]) { n++; } return n; }
static void puts_(const char *s) { sys3(4, 1, (long)s, slen(s)); }
static void puthex(unsigned v) {
  char b[11]; b[0]='0'; b[1]='x';
  for(int i = 0; i < 8; i++) { b[2+i] = "0123456789abcdef"[(v >> (28-4*i)) & 15]; }
  b[10] = '\n';
  sys3(4, 1, (long)b, 11);
}
int main(void);
static char stack[65536] __attribute__((aligned(16)));
__attribute__((naked)) void _start(void) {
  asm volatile("sethi %%hi(%0+65536-96), %%sp\n\t"
	       "or %%sp, %%lo(%0+65536-96), %%sp\n\t"
	       "call main\n\t nop\n\t"
	       "mov 1, %%g1\n\t ta 0x10\n\t" :: "i"(stack));
}
