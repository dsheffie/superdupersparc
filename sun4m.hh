#ifndef __SUN4M_HH__
#define __SUN4M_HH__

#include <cstdint>

/* sun4m (SPARCstation 20) physical device space.  Address map and register
 * behavior follow qemu's SS-20 (sparc_tests/ss20_qemu_mtree.txt) so the ISS can
 * be diffed against the reference machine running the same OBP:
 *   qemu-system-sparc -M SS-20 -cpu TI-SuperSparc-40 -m 256 -vga none
 * (behavior re-implemented from qemu's hw/ sources, not copied) */

class state_t;

#define SUN4M_PROM_BASE 0xff0000000ULL
#define SUN4M_PROM_SIZE (1u << 20)
#define SUN4M_NVRAM_SIZE 8192u
#define SUN4M_IOMMU_NREGS (0x4000u >> 2)
#define SUN4M_ECC_NREGS 9u

/* Z85C30 ESCC (two channels), register-compatible with qemu's escc.c with
 * it_shift=1: +0 B ctrl, +2 B data, +4 A ctrl, +6 A data.  chn[0] = B, chn[1] = A. */
class escc_t {
public:
  struct chn_t {
    uint8_t wregs[16] = {0};
    uint8_t rregs[16] = {0};
    uint32_t reg = 0;
    uint8_t rx = 0, tx = 0;
    bool rxint = false, txint = false;
    bool rxint_under_svc = false, txint_under_svc = false;
  };
  chn_t chn[2];
  bool disabled = false;    /* qemu "disabled": no keyboard/mouse behind it */
  bool console = false;     /* channel A transmit goes to stdout */
  bool irq = false;
  escc_t(bool disabled_, bool console_);
  uint32_t read(uint32_t off);
  void write(uint32_t off, uint32_t v);
private:
  void soft_reset(int c);
  void hard_reset(int c);
  bool irq_chn(int c) const;
  void update_irq();
  void set_txint(int c);
  void clr_txint(int c);
  void set_rxint(int c);
  void clr_rxint(int c);
};

/* slavio interrupt controller (qemu slavio_intctl.c): a per-CPU "slave"
 * register at 0xff1400000 + cpu*0x1000 (soft ints, level-14 CPU timer, level
 * 15) and the master/system register at 0xff1410000 (32 source bits mapped to
 * SPARC levels).  irl_out bit n set = level n requested of that CPU. */
#define SUN4M_MAX_CPUS 16
class intctl_t {
public:
  uint32_t slave_pending[SUN4M_MAX_CPUS] = {0};
  uint32_t irl_out[SUN4M_MAX_CPUS] = {0};
  uint32_t master_pending = 0;
  uint32_t master_disabled = 0;
  uint32_t target_cpu = 0;
  intctl_t();
  /* bit = system interrupt source (e.g. 15 serial, 19 system timer) */
  void set_irq(uint32_t bit, bool level);
  void set_cpu_timer_irq(uint32_t cpu, bool level);
  /* highest requested level for a CPU (0 = none): drives state_t::irl */
  uint32_t irl(uint32_t cpu) const;
  uint32_t read(uint64_t pa);
  void write(uint64_t pa, uint32_t v);
private:
  void check();
};

class sun4m_t {
public:
  intctl_t intctl;
  escc_t kbd_ms{true, false};     /* 0xff1000000: keyboard/mouse (disabled, as qemu -nographic) */
  escc_t serial{false, true};     /* 0xff1100000: ttya/ttyb */
  /* slavio misc byte registers */
  uint8_t aux1 = 0, aux2 = 0, diag = 0, mdm = 0;
  uint16_t leds = 0;
  uint32_t sysctrl = 0;
  uint8_t prom[SUN4M_PROM_SIZE] = {0};
  uint8_t nvram[SUN4M_NVRAM_SIZE] = {0};
  uint32_t iommu[SUN4M_IOMMU_NREGS] = {0};
  uint32_t ecc[SUN4M_ECC_NREGS] = {0};

  sun4m_t();
  bool load_prom(const char *fn);
  bool load_nvram(const char *fn);
  /* size is 1, 2 or 4 bytes; values in host order.  An access to an unassigned
   * address sets *bus_error (the CPU records an access bus error, FT=5). */
  uint32_t read(state_t *s, uint64_t pa, uint32_t size, bool *bus_error);
  void write(state_t *s, uint64_t pa, uint32_t size, uint32_t v, bool *bus_error);
  void update_irqs(state_t *s);
};

#endif
