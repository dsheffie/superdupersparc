/* Bare-metal runtime for Dhrystone on sparc_iss / ooo_core (with ../sv_asm.S:
 * the trap table, the window overflow/underflow handlers and _start, which
 * leaves main's return value in %g6 and halts in error mode). */
#include <stddef.h>

char *strcpy(char *d, const char *s) {
  char *r = d;
  while((*d++ = *s++) != '\0') {
  }
  return r;
}

int strcmp(const char *a, const char *b) {
  while(*a != '\0' && *a == *b) {
    a++;
    b++;
  }
  return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

void *memcpy(void *d, const void *s, size_t n) {
  unsigned char *dp = d;
  const unsigned char *sp = s;
  while(n--) {
    *dp++ = *sp++;
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
