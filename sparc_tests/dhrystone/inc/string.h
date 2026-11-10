/* freestanding stub (sparc_tests/dhrystone): dhry_rt.c */
#ifndef __DHRY_STRING_H__
#define __DHRY_STRING_H__
#include <stddef.h>
char *strcpy(char *d, const char *s);
int strcmp(const char *a, const char *b);
void *memcpy(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
#endif
