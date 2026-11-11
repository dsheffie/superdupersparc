/* L2 read bandwidth, ported from rv64-standalone-apps/l2_bw (read_bw.c): stream
 * loads over a FOOT-byte buffer at BASEADDR, one 32-bit ld per 16-byte line (each
 * load a different line; ld, not ldd), 16 per iteration, TRIES in all.
 * Bare metal (../sv_asm.S _start, MMU off): there is no cycle counter on V8, so
 * run.sh builds each footprint at two trip counts and takes the difference of the
 * simulator's cycle counts -- the steady-state cost of TRIES loads, warm-up and
 * startup cancel out. */
#include <stdint.h>

#define BASEADDR (1UL<<24)

typedef struct {
  uint32_t a;
  uint32_t pad[3];   /* one load per 16-byte L1D/L2 line */
} cacheline_t;

static void read_bw(uint8_t *m, uint32_t mask, uint32_t tries) {
  volatile cacheline_t *mm = (volatile cacheline_t*)m;
  uint32_t i = 0, t = 0;

  while(t < tries) {
    mm[i+0].a;
    mm[i+1].a;
    mm[i+2].a;
    mm[i+3].a;
    mm[i+4].a;
    mm[i+5].a;
    mm[i+6].a;
    mm[i+7].a;
    mm[i+8].a;
    mm[i+9].a;
    mm[i+10].a;
    mm[i+11].a;
    mm[i+12].a;
    mm[i+13].a;
    mm[i+14].a;
    mm[i+15].a;
    i += 16;
    i = (i >= mask) ? 0 : i;
    t += 16;
  }
}

int main(void) {
  read_bw((uint8_t*)BASEADDR, FOOT / sizeof(cacheline_t), TRIES);
  return 0x600d;
}
