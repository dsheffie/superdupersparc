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
  return (int)fp_traps;
}
