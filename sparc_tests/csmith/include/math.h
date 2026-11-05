#ifndef __RT_MATH_H__
#define __RT_MATH_H__
/* csmith's safe_math.h defines float helpers (unused by the integer-only
 * programs) in terms of these */
#define fabs(x) __builtin_fabs(x)
#define fabsf(x) __builtin_fabsf(x)
#endif
