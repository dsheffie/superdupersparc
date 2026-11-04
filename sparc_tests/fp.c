#include "crt.h"
/* single/double arith, conversions, compares; NaN/inf/denormal edges */
static volatile float fv[] = {0.0f, -0.0f, 1.0f, -2.5f, 3.14159f, 1e30f, 1e-40f, __builtin_inff(), -__builtin_inff(), 7e9f};
static volatile double dv[] = {0.0, -0.0, 1.0, -2.5, 3.141592653589793, 1e300, 4e-320, __builtin_inf(), -__builtin_inf(), -3e9};
#ifdef __sparc__
static float sqrt_s(float x) { float r; asm("fsqrts %1, %0" : "=f"(r) : "f"(x)); return r; }
static double sqrt_d(double x) { double r; asm("fsqrtd %1, %0" : "=e"(r) : "e"(x)); return r; }
#else
#define sqrt_s __builtin_sqrtf
#define sqrt_d __builtin_sqrt
#endif
static unsigned fb(float f) { union { float f; unsigned u; } x; x.f = f; return x.u; }
static unsigned db_hi(double d) { union { double d; unsigned long long u; } x; x.d = d; return (unsigned)(x.u >> 32); }
static unsigned db_lo(double d) { union { double d; unsigned long long u; } x; x.d = d; return (unsigned)x.u; }
int main(void) {
  for(int i = 0; i < 10; i++) {
    for(int j = 0; j < 10; j++) {
      float a = fv[i], b = fv[j];
      double c = dv[i], d = dv[j];
      puthex(fb(a + b)); puthex(fb(a - b)); puthex(fb(a * b)); puthex(fb(a / b));
      puthex(db_hi(c + d)); puthex(db_lo(c * d)); puthex(db_hi(c / d)); puthex(db_lo(c - d));
      puthex((a < b) | ((a == b) << 1) | ((a > b) << 2) | ((c <= d) << 3) | ((c != d) << 4));
      puthex(db_hi((double)a * (double)b));
    }
    puthex(fb((float)dv[i])); puthex(db_hi((double)fv[i])); puthex(db_lo((double)fv[i]));
    puthex((unsigned)(int)fv[i]); puthex((unsigned)(int)dv[i]);
    puthex(fb((float)(int)(i * 123456789))); puthex(db_lo((double)(int)(i * -987654321)));
    puthex(fb(sqrt_s(fv[i]))); puthex(db_hi(sqrt_d(dv[i])));
    puthex(fb(-fv[i])); puthex(fb(__builtin_fabsf(fv[i])));
  }
  return 0;
}
