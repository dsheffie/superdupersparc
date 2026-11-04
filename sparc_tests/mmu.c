/* SRMMU directed test (bare metal, supervisor).  Identity-maps the low 16MB with
 * one level-1 PTE, then a 3-level walk for two 4KB pages, and checks R/M
 * updates, protection and invalid faults (fault status/address register
 * contents), probe, bypass ASI and read-to-clear.  main returns 0 when every
 * check passes, else bit n set = check n failed. */
#define PTD(pa)      ((((unsigned)(pa)) >> 4) | 1u)
#define PTE(pa, acc) (((((unsigned)(pa)) >> 4) & ~0xffu) | ((acc) << 2) | 2u)
#define PTE_R (1u << 5)
#define PTE_M (1u << 6)

static unsigned ctx_table[256] __attribute__((aligned(1024)));
static unsigned l1[256] __attribute__((aligned(1024)));
static unsigned l2[64] __attribute__((aligned(256)));
static unsigned l3[64] __attribute__((aligned(256)));
extern volatile unsigned mmu_fsr_seen, mmu_far_seen, mmu_faults;

static unsigned lda(unsigned a, int asi_is_4) {
  unsigned v;
  if(asi_is_4) {
    asm volatile("lda [%1] 4, %0" : "=r"(v) : "r"(a) : "memory");
  }
  else {
    asm volatile("lda [%1] 3, %0" : "=r"(v) : "r"(a) : "memory");
  }
  return v;
}
static void sta4(unsigned a, unsigned v) { asm volatile("sta %0, [%1] 4" :: "r"(v), "r"(a) : "memory"); }
static unsigned ld_phys(unsigned pa) { unsigned v; asm volatile("lda [%1] 0x20, %0" : "=r"(v) : "r"(pa) : "memory"); return v; }

int main(void) {
  unsigned fail = 0;
  volatile unsigned *rw = (volatile unsigned *)0x40000000;
  volatile unsigned *ro = (volatile unsigned *)0x40001000;
  volatile unsigned *bad = (volatile unsigned *)0x50000000;

  ctx_table[0] = PTD(l1);
  l1[0x00] = PTE(0, 3);              /* VA 0-16MB -> PA 0, RWX (16MB level-1 page) */
  l1[0x40] = PTD(l2);                /* VA 0x40000000 */
  l2[0] = PTD(l3);
  l3[0] = PTE(0x600000, 1);          /* RW */
  l3[1] = PTE(0x601000, 0);          /* read-only */
  sta4(0x100, ((unsigned)ctx_table >> 4) & ~3u);
  sta4(0x200, 0);
  sta4(0x000, lda(0x000, 1) | 1);    /* enable */

  rw[2] = 0xcafef00d;
  if(ld_phys(0x600008) != 0xcafef00d) { fail |= 1 << 0; }
  if((l3[0] & (PTE_R | PTE_M)) != (PTE_R | PTE_M)) { fail |= 1 << 1; }
  (void)ro[0];
  if((l3[1] & (PTE_R | PTE_M)) != PTE_R) { fail |= 1 << 2; }
  if(lda(0x40000000, 0) != l3[0]) { fail |= 1 << 3; }     /* probe */

  ro[0] = 1;                         /* protection: L=3 AT=5 (super store) FT=2 FAV */
  if(mmu_faults != 1 || mmu_fsr_seen != 0x3aa || mmu_far_seen != 0x40001000) { fail |= 1 << 4; }
  if(ld_phys(0x601000) != 0) { fail |= 1 << 5; }          /* the store did not happen */
  (void)bad[0];                      /* invalid at level 1: L=1 AT=1 (super load) FT=1 FAV */
  if(mmu_faults != 2 || mmu_fsr_seen != 0x126 || mmu_far_seen != 0x50000000) { fail |= 1 << 6; }
  if(lda(0x300, 1) != 0) { fail |= 1 << 7; }              /* the handler's read cleared it */
  if((lda(0x000, 1) >> 24) != 0 || !(lda(0x000, 1) & (1u << 11))) { fail |= 1 << 8; }  /* Viking MBus */
  return fail;
}
