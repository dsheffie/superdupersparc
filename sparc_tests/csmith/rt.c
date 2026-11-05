/* Bare-metal runtime for csmith programs on sparc_iss / ooo_core (with
 * ../sv_asm.S: the trap table, the window overflow/underflow handlers and
 * _start, which leaves main's return value in %g6 and halts in error mode).
 *
 * The program is compiled with -Dmain=csmith_main; main here runs it and
 * returns the checksum its platform_main_end printf'd, so the result is %g6.
 *
 * Built with clang's +soft-mul-div like the program, so nothing here may use
 * an integer *, / or %: the helpers below are shift/add/compare only. */
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>

int csmith_main(int argc, char *argv[]);

static uint32_t rt_checksum;
static char rt_out[256];
static unsigned rt_out_len;

#ifdef RT_USER
/* Linux user mode (qemu-sparc / sparc_iss -u): ../crt.h's _start and syscalls;
 * main prints what the program printed */
#include "../crt.h"
int main(void) {
  csmith_main(1, (char **)0);
  sys3(4, 1, (long)rt_out, rt_out_len);
  return 0;
}
#else
int main(void) {
  csmith_main(1, (char **)0);
  return (int)rt_checksum;
}
#endif

/* ---------------------------------------------------------------- libc */
void *memcpy(void *d, const void *s, size_t n) {
  unsigned char *dp = d;
  const unsigned char *sp = s;
  while(n--) {
    *dp++ = *sp++;
  }
  return d;
}

void *memmove(void *d, const void *s, size_t n) {
  unsigned char *dp = d;
  const unsigned char *sp = s;
  if(dp < sp) {
    while(n--) {
      *dp++ = *sp++;
    }
  }
  else {
    dp += n;
    sp += n;
    while(n--) {
      *--dp = *--sp;
    }
  }
  return d;
}

void *memset(void *d, int c, size_t n) {
  unsigned char *dp = d;
  while(n--) {
    *dp++ = (unsigned char)c;
  }
  return d;
}

int strcmp(const char *a, const char *b) {
  while(*a && (*a == *b)) {
    a++;
    b++;
  }
  return (unsigned char)*a - (unsigned char)*b;
}

static void out_c(char c) {
  if(rt_out_len < sizeof(rt_out) - 1) {
    rt_out[rt_out_len++] = c;
  }
}

/* enough printf for csmith: %d %u %x %X %s %c; the last number printed by
 * the "checksum = %X" line is the result */
int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  for(; *fmt; fmt++) {
    if(*fmt != '%') {
      out_c(*fmt);
      continue;
    }
    fmt++;
    while(*fmt == 'l') {
      fmt++;
    }
    if(*fmt == 's') {
      for(const char *s = va_arg(ap, const char *); s && *s; s++) {
	out_c(*s);
      }
    }
    else if(*fmt == 'c') {
      out_c((char)va_arg(ap, int));
    }
    else if((*fmt == 'x') || (*fmt == 'X') || (*fmt == 'd') || (*fmt == 'u')) {
      uint32_t v = va_arg(ap, uint32_t);
      rt_checksum = v;
      for(int sh = 28; sh >= 0; sh -= 4) {
	out_c("0123456789ABCDEF"[(v >> sh) & 15]);
      }
    }
  }
  va_end(ap);
  return 0;
}

/* ------------------------------------------------- soft multiply / divide */
static uint32_t umul32(uint32_t a, uint32_t b) {
  uint32_t r = 0;
  while(b) {
    if(b & 1) {
      r += a;
    }
    a <<= 1;
    b >>= 1;
  }
  return r;
}

static uint64_t umul64(uint64_t a, uint64_t b) {
  uint64_t r = 0;
  while(b) {
    if(b & 1) {
      r += a;
    }
    a <<= 1;
    b >>= 1;
  }
  return r;
}

/* restoring division; q / r of n / d (d != 0: csmith's safe math guards it) */
static uint32_t udivmod32(uint32_t n, uint32_t d, uint32_t *rem) {
  uint32_t q = 0, r = 0;
  for(int i = 31; i >= 0; i--) {
    r = (r << 1) | ((n >> i) & 1);
    if(r >= d) {
      r -= d;
      q |= 1u << i;
    }
  }
  *rem = r;
  return q;
}

static uint64_t udivmod64(uint64_t n, uint64_t d, uint64_t *rem) {
  uint64_t q = 0, r = 0;
  for(int i = 63; i >= 0; i--) {
    r = (r << 1) | ((n >> i) & 1);
    if(r >= d) {
      r -= d;
      q |= 1ull << i;
    }
  }
  *rem = r;
  return q;
}

/* the SPARC V7 helper names clang's +soft-mul-div calls */
uint32_t rt_umul(uint32_t a, uint32_t b) __asm__(".umul");
uint32_t rt_mul(int32_t a, int32_t b) __asm__(".mul");
uint32_t rt_udiv(uint32_t a, uint32_t b) __asm__(".udiv");
uint32_t rt_urem(uint32_t a, uint32_t b) __asm__(".urem");
int32_t rt_div(int32_t a, int32_t b) __asm__(".div");
int32_t rt_rem(int32_t a, int32_t b) __asm__(".rem");

uint32_t rt_umul(uint32_t a, uint32_t b) {
  return umul32(a, b);
}

uint32_t rt_mul(int32_t a, int32_t b) {
  return umul32((uint32_t)a, (uint32_t)b);
}

uint32_t rt_udiv(uint32_t a, uint32_t b) {
  uint32_t r;
  return udivmod32(a, b, &r);
}

uint32_t rt_urem(uint32_t a, uint32_t b) {
  uint32_t r;
  udivmod32(a, b, &r);
  return r;
}

/* C semantics: the quotient truncates toward zero, the remainder takes the
 * dividend's sign */
int32_t rt_div(int32_t a, int32_t b) {
  uint32_t ua = (a < 0) ? -(uint32_t)a : (uint32_t)a;
  uint32_t ub = (b < 0) ? -(uint32_t)b : (uint32_t)b;
  uint32_t r, q = udivmod32(ua, ub, &r);
  return ((a < 0) != (b < 0)) ? (int32_t)-q : (int32_t)q;
}

int32_t rt_rem(int32_t a, int32_t b) {
  uint32_t ua = (a < 0) ? -(uint32_t)a : (uint32_t)a;
  uint32_t ub = (b < 0) ? -(uint32_t)b : (uint32_t)b;
  uint32_t r;
  udivmod32(ua, ub, &r);
  return (a < 0) ? (int32_t)-r : (int32_t)r;
}

int64_t __muldi3(int64_t a, int64_t b) {
  return (int64_t)umul64((uint64_t)a, (uint64_t)b);
}

uint64_t __udivdi3(uint64_t a, uint64_t b) {
  uint64_t r;
  return udivmod64(a, b, &r);
}

uint64_t __umoddi3(uint64_t a, uint64_t b) {
  uint64_t r;
  udivmod64(a, b, &r);
  return r;
}

int64_t __divdi3(int64_t a, int64_t b) {
  uint64_t ua = (a < 0) ? -(uint64_t)a : (uint64_t)a;
  uint64_t ub = (b < 0) ? -(uint64_t)b : (uint64_t)b;
  uint64_t r, q = udivmod64(ua, ub, &r);
  return ((a < 0) != (b < 0)) ? (int64_t)-q : (int64_t)q;
}

int64_t __moddi3(int64_t a, int64_t b) {
  uint64_t ua = (a < 0) ? -(uint64_t)a : (uint64_t)a;
  uint64_t ub = (b < 0) ? -(uint64_t)b : (uint64_t)b;
  uint64_t r;
  udivmod64(ua, ub, &r);
  return (a < 0) ? (int64_t)-r : (int64_t)r;
}

/* 64-bit shifts by a variable count (clang calls these on sparc32).  Built from
 * the 32-bit halves: a 64-bit shift here would call itself. */
typedef union {
  uint64_t v;
  struct { uint32_t hi, lo; } w;   /* big-endian */
} dw_t;

uint64_t __ashldi3(uint64_t a, int b) {
  dw_t x, r;
  x.v = a;
  b &= 63;
  if(b == 0) {
    return a;
  }
  if(b >= 32) {
    r.w.hi = x.w.lo << (b - 32);
    r.w.lo = 0;
  }
  else {
    r.w.hi = (x.w.hi << b) | (x.w.lo >> (32 - b));
    r.w.lo = x.w.lo << b;
  }
  return r.v;
}

uint64_t __lshrdi3(uint64_t a, int b) {
  dw_t x, r;
  x.v = a;
  b &= 63;
  if(b == 0) {
    return a;
  }
  if(b >= 32) {
    r.w.lo = x.w.hi >> (b - 32);
    r.w.hi = 0;
  }
  else {
    r.w.lo = (x.w.lo >> b) | (x.w.hi << (32 - b));
    r.w.hi = x.w.hi >> b;
  }
  return r.v;
}

int64_t __ashrdi3(int64_t a, int b) {
  dw_t x, r;
  x.v = (uint64_t)a;
  b &= 63;
  if(b == 0) {
    return a;
  }
  if(b >= 32) {
    r.w.lo = (uint32_t)((int32_t)x.w.hi >> (b - 32));
    r.w.hi = (uint32_t)((int32_t)x.w.hi >> 31);
  }
  else {
    r.w.lo = (x.w.lo >> b) | (x.w.hi << (32 - b));
    r.w.hi = (uint32_t)((int32_t)x.w.hi >> b);
  }
  return (int64_t)r.v;
}
