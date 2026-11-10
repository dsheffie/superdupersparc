/* FP traps on ooo_core: bare metal, linked with sv_asm.S, whose fp_exception
 * handler logs the FSR (ftt, cexc) and skips the FPop.  Every TEM bit is enabled
 * in turn and an op raising that exception run, plus ops that trap with the bit
 * masked (none) and an unimplemented quad FPop.  Results, the trap count and the
 * FSR log go to memory (the halt-time compare); main returns the trap count. */
extern volatile unsigned fp_traps;

static void set_fsr(unsigned v) {
  volatile unsigned t = v;
  asm volatile("ld [%0], %%fsr" :: "r"(&t) : "memory");
}
static unsigned get_fsr(void) {
  volatile unsigned t;
  asm volatile("st %%fsr, [%0]" :: "r"(&t) : "memory");
  return t;
}

static volatile float fz = 0.0f, f1 = 1.0f, f3 = 3.0f, fbig = 3e38f, fsmall = 1e-30f;
static volatile double dz = 0.0, d1 = 1.0, d3 = 3.0, dbig = 1e308;
static volatile float fnsmall = -1e-30f;
static volatile double dmin = 2.2250738585072014e-308, dmin15 = 3.3375e-308, dtiny = 1e-40;
static volatile union { float f; unsigned u; } fden = { .u = 0x00012345 }, fnden = { .u = 0x80012345 };
static volatile union { double d; unsigned long long u; } dden = { .u = 0x0000123456789abcULL };
#define FSR_NS (1u << 22)
static double sqrt_d(double v) { double r; asm volatile("fsqrtd %1, %0" : "=e"(r) : "e"(v)); return r; }
volatile unsigned res[64];
volatile unsigned fsr_after[64];

#define TEM(nv, of, uf, dz, nx) (((nv) << 27) | ((of) << 26) | ((uf) << 25) | ((dz) << 24) | ((nx) << 23))

int main(void) {
  unsigned n = 0;
  volatile union { float f; unsigned u; } x;
  volatile union { double d; unsigned long long u; } y;
  /* masked: no traps, cexc/aexc set */
  set_fsr(0);
  x.f = f1 / fz;    res[n] = x.u; fsr_after[n++] = get_fsr();   /* DZ */
  x.f = fz / fz;    res[n] = x.u; fsr_after[n++] = get_fsr();   /* NV */
  x.f = fbig * fbig; res[n] = x.u; fsr_after[n++] = get_fsr();  /* OF NX */
  x.f = f1 / f3;    res[n] = x.u; fsr_after[n++] = get_fsr();   /* NX */
  /* each exception enabled: traps, destination untouched (the handler skips) */
  set_fsr(TEM(0, 0, 0, 1, 0));
  x.u = 0x12345678; x.f = f1 / fz; res[n] = x.u; fsr_after[n++] = get_fsr();
  set_fsr(TEM(1, 0, 0, 0, 0));
  x.u = 0x12345678; x.f = fz / fz; res[n] = x.u; fsr_after[n++] = get_fsr();
  set_fsr(TEM(0, 1, 0, 0, 0));
  x.u = 0x12345678; x.f = fbig * fbig; res[n] = x.u; fsr_after[n++] = get_fsr();
  set_fsr(TEM(0, 0, 0, 0, 1));
  x.u = 0x12345678; x.f = f1 / f3; res[n] = x.u; fsr_after[n++] = get_fsr();
  set_fsr(TEM(0, 0, 0, 0, 1));
  y.u = 0x1122334455667788ULL; y.d = d1 / d3; res[n] = (unsigned)y.u; fsr_after[n++] = get_fsr();
  set_fsr(TEM(0, 1, 0, 0, 1));
  y.u = 0x1122334455667788ULL; y.d = dbig * dbig; res[n] = (unsigned)(y.u >> 32); fsr_after[n++] = get_fsr();
  /* an enabled exception the op does not raise: no trap */
  set_fsr(TEM(0, 0, 0, 1, 0));
  x.f = f1 + f3;    res[n] = x.u; fsr_after[n++] = get_fsr();
  /* tiny before rounding: unfinished, even with UF masked */
  set_fsr(0);
  x.u = 0x12345678; x.f = fsmall * fsmall; res[n] = x.u; fsr_after[n++] = get_fsr();
  /* faddq: unimplemented_FPop */
  set_fsr(0);
  asm volatile(".word 0x81a00860" ::: "memory");   /* faddq %f0, %f0, %f0 */
  fsr_after[n++] = get_fsr();
  /* a successful FPop clears ftt */
  x.f = f1 + f1;    res[n] = x.u; fsr_after[n++] = get_fsr();
  /* FSR.NS: a denormal operand reads as a zero of its sign; a tiny result is a
   * zero of its sign with UF NX; nothing punts */
  set_fsr(FSR_NS);
  x.u = 0x12345678; x.f = fsmall * fsmall;  res[n] = x.u; fsr_after[n++] = get_fsr();   /* +0, UF NX */
  x.u = 0x12345678; x.f = fnsmall * fsmall; res[n] = x.u; fsr_after[n++] = get_fsr();   /* -0 */
  x.u = 0x12345678; x.f = fsmall / fbig;    res[n] = x.u; fsr_after[n++] = get_fsr();   /* div: +0 */
  x.u = 0x12345678; x.f = fden.f + f1;      res[n] = x.u; fsr_after[n++] = get_fsr();   /* 1.0 exact */
  x.u = 0x12345678; x.f = fnden.f * f3;     res[n] = x.u; fsr_after[n++] = get_fsr();   /* -0, no flags */
  y.u = 0x1122334455667788ULL; y.d = dmin15 - dmin;  res[n] = (unsigned)(y.u >> 32); fsr_after[n++] = get_fsr(); /* +0 */
  y.u = 0x1122334455667788ULL; y.d = dmin - dmin15;  res[n] = (unsigned)(y.u >> 32); fsr_after[n++] = get_fsr(); /* -0 */
  y.u = 0x1122334455667788ULL; y.d = dden.d + d1;    res[n] = (unsigned)y.u; fsr_after[n++] = get_fsr();         /* 1.0 */
  y.u = 0x1122334455667788ULL; y.d = sqrt_d(dden.d); res[n] = (unsigned)(y.u >> 32); fsr_after[n++] = get_fsr(); /* +0 */
  y.u = 0x1122334455667788ULL; y.d = (double)fnden.f; res[n] = (unsigned)(y.u >> 32); fsr_after[n++] = get_fsr(); /* fstod -0 */
  x.u = 0x12345678; x.f = (float)dtiny;     res[n] = x.u; fsr_after[n++] = get_fsr();   /* fdtos +0, UF NX */
  x.u = 0x12345678; x.f = (float)dden.d;    res[n] = x.u; fsr_after[n++] = get_fsr();   /* fdtos of a denormal: +0 */
  x.u = 0x12345678; x.f = f1 * f3;          res[n] = x.u; fsr_after[n++] = get_fsr();   /* normal ops unaffected */
  /* ... and UF enabled: the flushed result's UF is an IEEE trap */
  set_fsr(FSR_NS | TEM(0, 0, 1, 0, 0));
  x.u = 0x12345678; x.f = fsmall * fsmall;  res[n] = x.u; fsr_after[n++] = get_fsr();
  set_fsr(0);
  return (int)fp_traps;
}
