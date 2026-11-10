/* Bare-metal runtime for the SC4.2-compiled Dhrystone (dhry21a.o/dhry21b.o built
 * on Solaris with cc -xO4 -xcg92 -dalign, plus Solaris libc's strcpy/strcmp/memcpy
 * objects), linked with ../sv_asm.S.  The benchmark's own main is renamed
 * dhry_main; this main runs it and checks the final values: %g6 = 0x600d. */
#include <stddef.h>

int dhry_main(void);
extern char Ch_1_Glob, Ch_2_Glob;
extern int Int_Glob, Bool_Glob;
extern int Arr_1_Glob[50];
extern int Arr_2_Glob[50][50];

/* stdio: the benchmark only reports; nothing to print to */
int printf(const char *f, ...) { (void)f; return 0; }
int fprintf(void *fp, const char *f, ...) { (void)fp; (void)f; return 0; }
static int dummy_file;
void *fopen(const char *p, const char *m) { (void)p; (void)m; return &dummy_file; }
int fclose(void *fp) { (void)fp; return 0; }
void exit(int c) {
  __asm__ __volatile__("mov %0, %%g6\n\tta 0x7f\n\tnop" :: "r"(c));
  for(;;) {
  }
}
/* the timer: unused here (the cycle count comes from the simulator) */
double dtime(void) { return 0.0; }

static unsigned char heap[4096] __attribute__((aligned(8)));
static size_t heap_used;
void *malloc(size_t n) {
  void *p = &heap[heap_used];
  heap_used += (n + 7) & ~(size_t)7;
  return p;
}

int main(void) {
  dhry_main();
  int bad = 0;
  bad |= (Int_Glob != 5) << 0;
  bad |= (Bool_Glob != 1) << 1;
  bad |= (Ch_1_Glob != 'A') << 2;
  bad |= (Ch_2_Glob != 'B') << 3;
  bad |= (Arr_1_Glob[8] != 7) << 4;
  bad |= (Arr_2_Glob[8][7] != DHRY_RUNS + 10) << 5;
  return bad ? (0xbad0 | bad) : 0x600d;
}
