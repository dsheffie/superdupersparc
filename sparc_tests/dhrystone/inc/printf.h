/* dhry21a.c's printf_: output is not needed on bare metal (the result is %g6) */
#ifndef __DHRY_PRINTF_H__
#define __DHRY_PRINTF_H__
#define printf_(...) ((void)0)
#endif
