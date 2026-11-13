/* L2 memory-level parallelism: K independent pointer chases walked in lockstep
 * over a FOOT-byte dataset at BASEADDR (one node per 16-byte line, each list a
 * random cycle through its own FOOT/K bytes).  The loads of one step are
 * independent, so a core that keeps several L1D misses in flight to the L2
 * takes about L2-latency / min(K, misses in flight) cycles per step.  Bare
 * metal (../sv_asm.S _start, MMU off); no cycle counter on V8, so run.sh takes
 * the difference of two trip counts (STEPS). */
#include <stdint.h>

#define BASEADDR (1UL<<24)

typedef struct node {
  struct node *next;
  uint32_t pad[3];   /* one node per 16-byte line */
} node_t;

static uint32_t lcg(uint32_t *s) {
  *s = *s * 1664525u + 1013904223u;
  return *s;
}

/* list k: a random cyclic permutation of its n nodes (Sattolo's shuffle) */
static node_t *build(node_t *base, uint32_t n, uint32_t seed) {
  static uint32_t perm[(FOOT / sizeof(node_t))];
  for(uint32_t i = 0; i < n; i++) {
    perm[i] = i;
  }
  for(uint32_t i = n - 1; i > 0; i--) {
    uint32_t j = lcg(&seed) % i;
    uint32_t t = perm[i];
    perm[i] = perm[j];
    perm[j] = t;
  }
  for(uint32_t i = 0; i < n; i++) {
    base[perm[i]].next = &base[perm[(i + 1) % n]];
  }
  return &base[perm[0]];
}

int main(void) {
  const uint32_t n = (FOOT / sizeof(node_t)) / K;
  node_t *base = (node_t *)BASEADDR;
  node_t *p[K];
  for(uint32_t k = 0; k < K; k++) {
    p[k] = build(base + k * n, n, 12345u + 977u * k);
  }
  /* warm: one full lap of every list puts the dataset in the L2 */
  for(uint32_t i = 0; i < n; i++) {
    for(uint32_t k = 0; k < K; k++) {
      p[k] = p[k]->next;
    }
  }
  for(uint32_t t = 0; t < STEPS; t++) {
    for(uint32_t k = 0; k < K; k++) {
      p[k] = p[k]->next;
    }
  }
  uint32_t sum = 0;
  for(uint32_t k = 0; k < K; k++) {
    sum += (uint32_t)p[k];
  }
  return sum ? 0x600d : 0;
}
