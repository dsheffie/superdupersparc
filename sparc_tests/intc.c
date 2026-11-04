/* sun4m slavio interrupt controller (run with sparc_iss --sun4m): soft
 * interrupts via the CPU 0 slave register, PIL masking, level 15 vs PIL 15,
 * trap levels, clearing from the handler.  main returns 0 when every check
 * passes, else bit n set = check n failed. */
extern volatile unsigned irq_seen, irq_count;

static unsigned ld_pa(unsigned va) { unsigned v; asm volatile("lda [%1] 0x2f, %0" : "=r"(v) : "r"(va) : "memory"); return v; }
static void st_pa(unsigned va, unsigned v) { asm volatile("sta %0, [%1] 0x2f" :: "r"(v), "r"(va) : "memory"); }
static void set_pil(unsigned pil) {
  unsigned psr;
  asm volatile("rd %%psr, %0" : "=r"(psr));
  psr = (psr & ~0xf00u) | (pil << 8);
  asm volatile("wr %0, 0, %%psr\n\tnop\n\tnop\n\tnop" :: "r"(psr) : "memory");
}
#define SLAVE_PENDING 0xf1400000u
#define SLAVE_SET     0xf1400008u
#define SOFT(n)       (1u << (16 + (n)))

int main(void) {
  unsigned fail = 0;
  set_pil(6);
  st_pa(SLAVE_SET, SOFT(5));                   /* level 5 <= PIL 6: stays pending */
  if(irq_count != 0) { fail |= 1 << 0; }
  if(!(ld_pa(SLAVE_PENDING) & SOFT(5))) { fail |= 1 << 1; }
  set_pil(4);                                  /* now 5 > 4: taken */
  if(irq_count != 1 || irq_seen != 5) { fail |= 1 << 2; }
  if(ld_pa(SLAVE_PENDING) & SOFT(5)) { fail |= 1 << 3; }   /* the handler cleared it */
  set_pil(15);
  st_pa(SLAVE_SET, SOFT(14));                  /* masked by PIL 15 */
  if(irq_count != 1) { fail |= 1 << 4; }
  st_pa(SLAVE_SET, SOFT(15));                  /* level 15 is not maskable: taken first */
  if(irq_count != 2 || irq_seen != 15) { fail |= 1 << 5; }
  set_pil(0);                                  /* then the pending 14 */
  if(irq_count != 3 || irq_seen != 14) { fail |= 1 << 6; }
  if(ld_pa(0xf1410010u) != 0) { fail |= 1 << 7; }          /* master target cpu */
  return fail;
}
