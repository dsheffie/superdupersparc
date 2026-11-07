/* The runtime for Gaisler GRLIB's LEON3 system tests (software/systest and
 * software/leon3 of grlib-gpl; not in this tree, see build.sh), bare metal on
 * sparc_iss / ooo_core with ../sv_asm.S.  It stands in for GRLIB's report and
 * LEON helpers:
 *   - report_subtest/fail: the first failure is (subtest << 8) | id;
 *   - get_asr17: LEON's configuration register, which the tests gate on.  It
 *     claims hardware mul/div (bit 8), no MAC (bit 9: umac/smac are LEON-only)
 *     and a GRFPU (bits 11:10 = 1) so the FP tests run rather than skip;
 *     (grfpu_test itself is not run, see main);
 *   - get_pid: CPU 0.
 * regtest.S reads %asr17 (and %asr16) itself.  On this core, as on qemu sparc32,
 * rd %asrN returns %y, so main loads %y with the same configuration value first
 * (its FT bits are 0: regtest skips the register-file EDAC tests).
 * main returns 0x600d in %g6 when every test passed, else 0xbad00000 | the first
 * failure (and %g5's soft-trap count is unused). */
#include <stdint.h>

static volatile int g_subtest = 0;
static volatile int g_first_fail = 0;
static volatile int g_fails = 0;

int report_subtest(int subtest) {
  g_subtest = subtest;
  return 0;
}

int fail(int id) {
  if(g_fails == 0) {
    g_first_fail = ((g_subtest & 0xff) << 8) | (id & 0xff);
  }
  g_fails = g_fails + 1;
  return 0;
}

int report_device(unsigned int dev) {
  (void)dev;
  return 0;
}

#define ASR17_CONFIG ((1 << 8) | (1 << 10) | 7)   /* mul/div, GRFPU, NWINDOWS - 1 */

int get_asr17(void) {
  return ASR17_CONFIG;
}

int get_pid(void) {
  return 0;
}

int xgetpsr(void) {
  int psr;
  __asm__ volatile("rd %%psr, %0" : "=r"(psr));
  return psr;
}

void setpsr(int psr) {
  __asm__ volatile("wr %0, 0, %%psr\n\tnop\n\tnop\n\tnop" : : "r"(psr));
}

double sqrt(double x) {
  double r;
  __asm__ volatile("fsqrtd %1, %0" : "=f"(r) : "f"(x));
  return r;
}

double fabs(double x) {
  union { double d; uint64_t u; } v;
  v.d = x;
  v.u &= ~(1ULL << 63);
  return v.d;
}

extern int regtest(void);
extern int multest(void);
extern int divtest(void);
extern int fputest(void);

int main(void) {
  report_subtest(3);   /* REGFILE */
  __asm__ volatile("wr %0, 0, %%y\n\tnop\n\tnop\n\tnop" : : "r"(ASR17_CONFIG));
  if(regtest()) {
    fail(1);
  }
  multest();
  divtest();
  fputest();
  /* grfpu_test is left out: its FP trap handler re-executes the trapping op
   * from the FQ (GRFPU's deferred traps); this FPU traps precisely, FQ empty */
  return (g_fails == 0) ? 0x600d : (int)(0xbad00000u | (unsigned)g_first_fail);
}
