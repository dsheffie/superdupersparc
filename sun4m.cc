#include <cstdio>
#include <cstring>

#include "sun4m.hh"
#include "interpret.hh"

/* SS-20 version registers (qemu ss20_hwdef) */
static const uint32_t IOMMU_VERSION = 0x13000000;
static const uint32_t ECC_VERSION = 0x20000000;     /* SMC: impl 2, ver 0 */
static const uint8_t IDREG[4] = {0xfe, 0x81, 0x01, 0x03};

/* IOMMU registers (word index) */
enum : uint32_t {
  IOMMU_CTRL = 0x0000 >> 2, IOMMU_BASE = 0x0004 >> 2,
  IOMMU_TLBFLUSH = 0x0014 >> 2, IOMMU_PGFLUSH = 0x0018 >> 2,
  IOMMU_AFSR = 0x1000 >> 2, IOMMU_AFAR = 0x1004 >> 2, IOMMU_AER = 0x1008 >> 2,
  IOMMU_SBCFG0 = 0x1010 >> 2, IOMMU_SBCFG3 = 0x101c >> 2,
  IOMMU_ARBEN = 0x2000 >> 2, IOMMU_MASK_ID = 0x3018 >> 2
};
static const uint32_t IOMMU_AFSR_RESV = 0x00800000;
static const uint32_t IOMMU_MID = 0x00000008;

/* ECC memory controller registers (word index) */
enum : uint32_t {
  ECC_MER = 0, ECC_MDR = 1, ECC_MFSR = 2, ECC_VCR = 3,
  ECC_MFAR0 = 4, ECC_MFAR1 = 5, ECC_DR = 6, ECC_ECR0 = 7, ECC_ECR1 = 8
};

/* ---------------------------------------------------------------- ESCC */

enum : uint32_t {
  W_CMD = 0, W_INTR = 1, W_IVEC = 2, W_RXCTRL = 3, W_TXCTRL1 = 4, W_TXCTRL2 = 5,
  W_SYNC1 = 6, W_SYNC2 = 7, W_TXBUF = 8, W_MINTR = 9, W_MISC1 = 10, W_CLOCK = 11,
  W_BRGLO = 12, W_BRGHI = 13, W_MISC2 = 14, W_EXTINT = 15
};
enum : uint32_t { R_STATUS = 0, R_SPEC = 1, R_IVEC = 2, R_INTR = 3, R_MISC = 10 };
static const uint8_t STATUS_RXAV = 0x01, STATUS_TXEMPTY = 0x04, STATUS_DCD = 0x08;
static const uint8_t STATUS_SYNC = 0x10, STATUS_CTS = 0x20, STATUS_TXUNDRN = 0x40, STATUS_BRK = 0x80;
static const uint8_t SPEC_ALLSENT = 0x01, SPEC_BITS8 = 0x06;
static const uint8_t INTR_TXINT = 0x02, INTR_PAR_SPEC = 0x04, INTR_RXMODEMSK = 0x18;
static const uint8_t INTR_RXINT1ST = 0x08, INTR_RXINTALL = 0x10, INTR_WTRQ_TXRX = 0x20;
static const uint8_t INTR_TXINTB = 0x02, INTR_RXINTB = 0x04, INTR_TXINTA = 0x10, INTR_RXINTA = 0x20;
static const uint8_t MINTR_VIS = 0x01, MINTR_NV = 0x02, MINTR_STATUSHI = 0x10, MINTR_SOFTIACK = 0x20;
static const uint8_t MINTR_RST_MASK = 0xc0, MINTR_RST_B = 0x40, MINTR_RST_A = 0x80;
static const uint8_t IVEC_TXINTB = 0x00, IVEC_LONOINT = 0x06, IVEC_LORXINTA = 0x0c, IVEC_LORXINTB = 0x04;
static const uint8_t IVEC_LOTXINTA = 0x08, IVEC_HINOINT = 0x60, IVEC_HIRXINTA = 0x30, IVEC_HIRXINTB = 0x20;
static const uint8_t IVEC_HITXINTA = 0x10;
static const uint8_t EXTINT_BRKINT = 0x80;
static const int CHN_B = 0, CHN_A = 1;

escc_t::escc_t(bool disabled_, bool console_) : disabled(disabled_), console(console_) {
  /* qemu escc_reset: registers zeroed except RR0 Tx-empty (the Sun PROM spins on it) */
  for(int c = 0; c < 2; c++) {
    chn[c].rregs[R_STATUS] = STATUS_TXEMPTY;
  }
}

bool escc_t::irq_chn(int c) const {
  const chn_t &s = chn[c];
  uint8_t rxmode = s.wregs[W_INTR] & INTR_RXMODEMSK;
  return ((s.wregs[W_INTR] & INTR_TXINT) and s.txint) or
    ((rxmode == INTR_RXINT1ST or rxmode == INTR_RXINTALL) and s.rxint) or
    ((s.wregs[W_EXTINT] & EXTINT_BRKINT) and (s.rregs[R_STATUS] & STATUS_BRK));
}

void escc_t::update_irq() {
  irq = irq_chn(0) or irq_chn(1);
}

void escc_t::set_txint(int c) {
  chn_t &s = chn[c];
  chn_t &o = chn[c ^ 1];
  s.txint = true;
  if(s.rxint_under_svc) {
    return;
  }
  s.txint_under_svc = true;
  bool hi = s.wregs[W_MINTR] & MINTR_STATUSHI;
  if(c == CHN_A) {
    if(s.wregs[W_INTR] & INTR_TXINT) {
      s.rregs[R_INTR] |= INTR_TXINTA;
    }
    o.rregs[R_IVEC] = hi ? IVEC_HITXINTA : IVEC_LOTXINTA;
  }
  else {
    s.rregs[R_IVEC] = IVEC_TXINTB;
    if(s.wregs[W_INTR] & INTR_TXINT) {
      o.rregs[R_INTR] |= INTR_TXINTB;
    }
  }
  update_irq();
}

void escc_t::set_rxint(int c) {
  chn_t &s = chn[c];
  chn_t &o = chn[c ^ 1];
  bool hi = s.wregs[W_MINTR] & MINTR_STATUSHI;
  s.rxint = true;
  s.rxint_under_svc = true;
  if(c == CHN_A) {
    s.rregs[R_INTR] |= INTR_RXINTA;
    o.rregs[R_IVEC] = hi ? IVEC_HIRXINTA : IVEC_LORXINTA;
  }
  else {
    o.rregs[R_INTR] |= INTR_RXINTB;
    s.rregs[R_IVEC] = hi ? IVEC_HIRXINTB : IVEC_LORXINTB;
  }
  update_irq();
}

void escc_t::clr_txint(int c) {
  chn_t &s = chn[c];
  chn_t &o = chn[c ^ 1];
  bool hi = s.wregs[W_MINTR] & MINTR_STATUSHI;
  s.txint = false;
  s.txint_under_svc = false;
  if(c == CHN_A) {
    o.rregs[R_IVEC] = hi ? IVEC_HINOINT : IVEC_LONOINT;
    s.rregs[R_INTR] &= ~INTR_TXINTA;
  }
  else {
    o.rregs[R_INTR] &= ~INTR_TXINTB;
    s.rregs[R_IVEC] = hi ? IVEC_HINOINT : IVEC_LONOINT;
  }
  if(s.rxint) {
    set_rxint(c);
  }
  update_irq();
}

void escc_t::clr_rxint(int c) {
  chn_t &s = chn[c];
  chn_t &o = chn[c ^ 1];
  bool hi = s.wregs[W_MINTR] & MINTR_STATUSHI;
  s.rxint = false;
  s.rxint_under_svc = false;
  if(c == CHN_A) {
    o.rregs[R_IVEC] = hi ? IVEC_HINOINT : IVEC_LONOINT;
    s.rregs[R_INTR] &= ~INTR_RXINTA;
  }
  else {
    s.rregs[R_IVEC] = hi ? IVEC_HINOINT : IVEC_LONOINT;
    o.rregs[R_INTR] &= ~INTR_RXINTB;
  }
  if(s.txint) {
    set_txint(c);
  }
  update_irq();
}

void escc_t::soft_reset(int c) {
  chn_t &s = chn[c];
  s.reg = 0;
  s.rx = s.tx = 0;
  s.rxint = s.txint = false;
  s.rxint_under_svc = s.txint_under_svc = false;
  s.wregs[W_CMD] = 0;
  s.wregs[W_INTR] &= INTR_PAR_SPEC | INTR_WTRQ_TXRX;
  s.wregs[W_RXCTRL] &= ~0x01;
  s.wregs[W_TXCTRL1] |= 0x04;
  s.wregs[W_TXCTRL2] &= 0x01 | 0x60;
  s.wregs[W_MINTR] &= ~MINTR_SOFTIACK;
  s.wregs[W_MISC1] &= 0x60;
  s.wregs[W_MISC2] &= 0x01 | 0x02 | 0x40 | 0x80;
  s.wregs[W_MISC2] |= 0x20;
  s.wregs[W_EXTINT] = 0x08 | 0x10 | 0x20 | 0x40 | 0x80;
  s.rregs[R_STATUS] &= STATUS_DCD | STATUS_SYNC | STATUS_CTS | STATUS_BRK;
  s.rregs[R_STATUS] |= STATUS_TXEMPTY | STATUS_TXUNDRN;
  if(disabled) {
    s.rregs[R_STATUS] |= STATUS_DCD | STATUS_SYNC | STATUS_CTS;
  }
  s.rregs[R_SPEC] &= SPEC_ALLSENT;
  s.rregs[R_SPEC] |= SPEC_BITS8;
  s.rregs[R_INTR] = 0;
  s.rregs[R_MISC] &= 0x40;
}

void escc_t::hard_reset(int c) {
  chn_t &s = chn[c];
  soft_reset(c);
  s.wregs[W_MINTR] &= MINTR_VIS | MINTR_NV;
  s.wregs[W_MINTR] |= MINTR_RST_B | MINTR_RST_A;
  s.wregs[W_MISC1] = 0;
  s.wregs[W_CLOCK] = 0x08;
  s.wregs[W_MISC2] &= 0x40 | 0x80;
  s.wregs[W_MISC2] |= 0x10 | 0x20;
}

uint32_t escc_t::read(uint32_t off) {
  int c = (off >> 2) & 1;
  chn_t &s = chn[c];
  if(((off >> 1) & 1) == 0) {       /* control */
    uint32_t v = s.rregs[s.reg];
    s.reg = 0;
    return v;
  }
  s.rregs[R_STATUS] &= ~STATUS_RXAV;
  clr_rxint(c);
  return s.rx;                      /* (no keyboard/mouse queue: the kbd ESCC is disabled) */
}

void escc_t::write(uint32_t off, uint32_t v) {
  int c = (off >> 2) & 1;
  chn_t &s = chn[c];
  v &= 0xff;
  if(((off >> 1) & 1) == 0) {       /* control */
    uint32_t newreg = 0;
    switch(s.reg)
      {
      case W_CMD:
	newreg = v & 0x07;
	switch(v & 0x38)
	  {
	  case 0x08:                    /* point high */
	    newreg |= 0x08;
	    break;
	  case 0x28:                    /* reset Tx int pending */
	    clr_txint(c);
	    break;
	  case 0x38:                    /* reset highest IUS */
	    if(s.rxint_under_svc) {
	      s.rxint_under_svc = false;
	      if(s.txint) {
		set_txint(c);
	      }
	    }
	    else if(s.txint_under_svc) {
	      s.txint_under_svc = false;
	    }
	    update_irq();
	    break;
	  default:
	    break;
	  }
	break;
      case W_RXCTRL:
	s.wregs[s.reg] = v;
	if(v & 0x10) {
	  s.rregs[R_STATUS] |= STATUS_SYNC;
	}
	break;
      case W_TXCTRL1:
	s.wregs[s.reg] = v;
	s.rregs[R_SPEC] |= SPEC_ALLSENT;
	break;
      case W_BRGLO:
      case W_BRGHI:
	s.wregs[s.reg] = v;
	s.rregs[s.reg] = v;
	break;
      case W_MINTR:
	/* qemu keeps no WR9 value: only the reset commands act */
	switch(v & MINTR_RST_MASK)
	  {
	  case MINTR_RST_B:
	    soft_reset(CHN_B);
	    return;
	  case MINTR_RST_A:
	    soft_reset(CHN_A);
	    return;
	  case MINTR_RST_MASK:
	    hard_reset(CHN_B);
	    hard_reset(CHN_A);
	    return;
	  default:
	    break;
	  }
	break;
      default:                         /* WR1,2,5,6,7,8,10,11,14,15 */
	s.wregs[s.reg] = v;
	break;
      }
    s.reg = (s.reg == 0) ? newreg : 0;
    return;
  }
  /* data */
  s.txint = false;
  update_irq();
  s.tx = static_cast<uint8_t>(v);
  if(s.wregs[W_TXCTRL2] & 0x08) {     /* Tx enabled */
    if(s.wregs[W_MISC2] & 0x10) {     /* local loopback */
      s.rx = s.tx;
      s.rregs[R_STATUS] |= STATUS_RXAV;
      set_rxint(c);
    }
    else if(console and c == CHN_A) {
      fputc(s.tx, stdout);
      fflush(stdout);
    }
  }
  s.rregs[R_STATUS] |= STATUS_TXEMPTY;
  s.rregs[R_SPEC] |= SPEC_ALLSENT;
  set_txint(c);
}

/* ---------------------------------------------------------------- interrupt controller */

static const uint32_t MASTER_IRQ_MASK = ~0x0fa2007fu;
static const uint32_t MASTER_DISABLE = 0x80000000u;
static const uint32_t CPU_SOFTIRQ_MASK = 0xfffe0000u;
static const uint32_t CPU_IRQ_INT15_IN = 1u << 15;
static const uint32_t CPU_IRQ_TIMER_IN = 1u << 14;
static const uint32_t INTBIT_TO_LEVEL[32] = {
  2, 3, 5, 7, 9, 11, 13, 2,   3, 5, 7, 9, 11, 13, 12, 12,
  6, 13, 4, 10, 8, 9, 11, 0,  0, 0, 0, 15, 15, 15, 15, 0,
};

intctl_t::intctl_t() {
  master_disabled = ~MASTER_IRQ_MASK;   /* everything masked at reset */
  check();
}

void intctl_t::check() {
  uint32_t pending = master_pending & ~master_disabled;
  for(uint32_t i = 0; i < SUN4M_MAX_CPUS; i++) {
    uint32_t pil = 0;
    if(pending and not (master_disabled & MASTER_DISABLE) and i == target_cpu) {
      for(uint32_t j = 0; j < 32; j++) {
	if(((pending >> j) & 1) and INTBIT_TO_LEVEL[j]) {
	  pil |= 1u << INTBIT_TO_LEVEL[j];
	}
      }
    }
    /* the slave register also shows the (unmasked) hard interrupts for display */
    slave_pending[i] &= CPU_SOFTIRQ_MASK | CPU_IRQ_INT15_IN | CPU_IRQ_TIMER_IN;
    if(i == target_cpu) {
      for(uint32_t j = 0; j < 32; j++) {
	if(((master_pending >> j) & 1) and INTBIT_TO_LEVEL[j]) {
	  slave_pending[i] |= 1u << INTBIT_TO_LEVEL[j];
	}
      }
    }
    /* level 15 and the CPU timer are masked only by MASTER_DISABLE */
    if(not (master_disabled & MASTER_DISABLE)) {
      pil |= slave_pending[i] & (CPU_IRQ_INT15_IN | CPU_IRQ_TIMER_IN);
    }
    pil |= (slave_pending[i] & CPU_SOFTIRQ_MASK) >> 16;
    irl_out[i] = pil;
  }
}

void intctl_t::set_irq(uint32_t bit, bool level) {
  uint32_t pil = INTBIT_TO_LEVEL[bit];
  if(pil == 0) {
    return;
  }
  if(level) {
    master_pending |= 1u << bit;
  }
  else {
    master_pending &= ~(1u << bit);
  }
  if(pil == 15) {
    for(uint32_t i = 0; i < SUN4M_MAX_CPUS; i++) {
      if(level) {
	slave_pending[i] |= 1u << 15;
      }
      else {
	slave_pending[i] &= ~(1u << 15);
      }
    }
  }
  check();
}

void intctl_t::set_cpu_timer_irq(uint32_t cpu, bool level) {
  if(level) {
    slave_pending[cpu] |= CPU_IRQ_TIMER_IN;
  }
  else {
    slave_pending[cpu] &= ~CPU_IRQ_TIMER_IN;
  }
  check();
}

uint32_t intctl_t::irl(uint32_t cpu) const {
  uint32_t p = irl_out[cpu] & 0xfffe;
  return (p == 0) ? 0 : (31 - __builtin_clz(p));
}

uint32_t intctl_t::read(uint64_t pa) {
  if(pa >= 0xff1410000ULL) {                 /* master */
    switch((pa - 0xff1410000ULL) >> 2)
      {
      case 0: return master_pending & ~MASTER_DISABLE;
      case 1: return master_disabled & MASTER_IRQ_MASK;
      case 4: return target_cpu;
      default: return 0;
      }
  }
  uint32_t cpu = static_cast<uint32_t>((pa - 0xff1400000ULL) >> 12);
  return (((pa >> 2) & 3) == 0) ? slave_pending[cpu] : 0;
}

void intctl_t::write(uint64_t pa, uint32_t v) {
  if(pa >= 0xff1410000ULL) {                 /* master */
    switch((pa - 0xff1410000ULL) >> 2)
      {
      case 2:                                /* clear = enable */
	master_disabled &= ~(v & MASTER_IRQ_MASK);
	break;
      case 3:                                /* set = disable (pending unaffected) */
	master_disabled |= v & MASTER_IRQ_MASK;
	break;
      case 4:
	target_cpu = v & (SUN4M_MAX_CPUS - 1);
	break;
      default:
	return;
      }
    check();
    return;
  }
  uint32_t cpu = static_cast<uint32_t>((pa - 0xff1400000ULL) >> 12);
  switch((pa >> 2) & 3)
    {
    case 1:                                  /* clear pending soft ints */
      slave_pending[cpu] &= ~(v & (CPU_SOFTIRQ_MASK | CPU_IRQ_INT15_IN));
      break;
    case 2:                                  /* set soft int */
      slave_pending[cpu] |= v & CPU_SOFTIRQ_MASK;
      break;
    default:
      return;
    }
  check();
}

/* ---------------------------------------------------------------- sun4m */

sun4m_t::sun4m_t() {
  /* power-on reset values, as qemu's iommu_reset / ecc_realize+ecc_reset */
  iommu[IOMMU_CTRL] = IOMMU_VERSION;
  iommu[IOMMU_ARBEN] = IOMMU_MID;
  iommu[IOMMU_AFSR] = IOMMU_AFSR_RESV;
  iommu[IOMMU_AER] = 0x3;                  /* MBus masters 0x8 and 0x9 enabled */
  iommu[IOMMU_MASK_ID] = 0x23000000;
  ecc[ECC_MER] = ECC_VERSION & 0xff000ffcu;
  ecc[ECC_MDR] = 0x20;
  ecc[ECC_MFAR0] = 0x07c00000;
}

static bool load_file(const char *fn, uint8_t *buf, size_t max, const char *what) {
  FILE *fp = fopen(fn, "rb");
  if(fp == nullptr) {
    fprintf(stderr, "sun4m: can't open %s %s\n", what, fn);
    return false;
  }
  size_t n = fread(buf, 1, max, fp);
  fclose(fp);
  fprintf(stderr, "sun4m: loaded %zu byte %s\n", n, what);
  return n > 0;
}

bool sun4m_t::load_prom(const char *fn) {
  return load_file(fn, prom, SUN4M_PROM_SIZE, "prom");
}

bool sun4m_t::load_nvram(const char *fn) {
  return load_file(fn, nvram, SUN4M_NVRAM_SIZE, "nvram");
}

static inline uint32_t be_read(const uint8_t *p, uint32_t size) {
  uint32_t v = 0;
  for(uint32_t i = 0; i < size; i++) {
    v = (v << 8) | p[i];
  }
  return v;
}

static inline uint8_t bcd(uint32_t v) {
  return static_cast<uint8_t>(((v / 10) << 4) | (v % 10));
}

/* M48T08 clock registers at the top of the NVRAM.  The time is FIXED
 * (1995-09-11 00:00:00) so ISS runs are deterministic. */
static uint8_t m48t08_clock(uint32_t off, const uint8_t *nvram) {
  switch(off)
    {
    case 0x1ff8: return nvram[off];   /* control */
    case 0x1ff9: return bcd(0);       /* seconds */
    case 0x1ffa: return bcd(0);       /* minutes */
    case 0x1ffb: return bcd(0);       /* hours */
    case 0x1ffc: return bcd(1);       /* day of week */
    case 0x1ffd: return bcd(11);      /* date */
    case 0x1ffe: return bcd(9);       /* month */
    case 0x1fff: return bcd(95);      /* year */
    default: break;
    }
  return nvram[off];
}

/* devices that exist but are not modeled: reads 0, writes dropped, no error
 * (qemu's empty-slot / unimplemented-device regions) */
static bool is_quiet_region(uint64_t pa) {
  static const uint64_t quiet[][2] = {
    {0x090000000ULL, 0x2000}, {0x094000000ULL, 0x2000},       /* VSIMM empty slots */
    {0x098000000ULL, 0x2000}, {0x09c000000ULL, 0x2000},
    {0xee0001000ULL, 0x30}, {0xee0010000ULL, 0x100},          /* DBRI */
    {0xef4800000ULL, 0x20},                                    /* bpp */
    {0xf80000000ULL, 0x2000},                                  /* SX */
  };
  for(const auto &q : quiet) {
    if(pa >= q[0] and pa < q[0] + q[1]) {
      return true;
    }
  }
  return false;
}

/* per-CPU slaves 0xff1400000 + n*0x1000 (0x10 each), master 0xff1410000 (0x14) */
static bool is_intctl(uint64_t pa) {
  if(pa >= 0xff1410000ULL and pa < 0xff1410014ULL) {
    return true;
  }
  return pa >= 0xff1400000ULL and pa < 0xff1410000ULL and (pa & 0xff0) == 0;
}

/* re-sample the interrupt sources into the controller and the controller into
 * CPU 0's interrupt request level */
void sun4m_t::update_irqs(state_t *s) {
  intctl.set_irq(14, kbd_ms.irq);    /* keyboard/mouse ESCC -> level 12 */
  intctl.set_irq(15, serial.irq);    /* serial ESCC -> level 12 */
  s->irl = intctl.irl(0);
}

uint32_t sun4m_t::read(state_t *s, uint64_t pa, uint32_t size, bool *bus_error) {
  if(pa >= SUN4M_PROM_BASE and pa < SUN4M_PROM_BASE + SUN4M_PROM_SIZE) {
    return be_read(&prom[pa - SUN4M_PROM_BASE], size);
  }
  if(pa >= 0xff1200000ULL and pa < 0xff1200000ULL + SUN4M_NVRAM_SIZE) {
    uint32_t off = static_cast<uint32_t>(pa - 0xff1200000ULL);
    uint32_t v = 0;
    for(uint32_t i = 0; i < size; i++) {
      v = (v << 8) | m48t08_clock(off + i, nvram);
    }
    return v;
  }
  if(pa >= 0xfe0000000ULL and pa < 0xfe0004000ULL) {
    return iommu[(pa - 0xfe0000000ULL) >> 2];
  }
  if(pa >= 0xf00000000ULL and pa < 0xf00000000ULL + 4*SUN4M_ECC_NREGS) {
    uint32_t r = static_cast<uint32_t>(pa - 0xf00000000ULL) >> 2;
    return (r == ECC_ECR1) ? ecc[ECC_ECR0] : ecc[r];   /* (qemu aliases ECR1 to ECR0) */
  }
  if(pa >= 0xef0000000ULL and pa < 0xef0000004ULL) {
    return be_read(&IDREG[pa - 0xef0000000ULL], size);
  }
  if(pa >= 0xff1000000ULL and pa < 0xff1000008ULL) {
    uint32_t v = kbd_ms.read(static_cast<uint32_t>(pa - 0xff1000000ULL));
    update_irqs(s);
    return v;
  }
  if(pa >= 0xff1100000ULL and pa < 0xff1100008ULL) {
    uint32_t v = serial.read(static_cast<uint32_t>(pa - 0xff1100000ULL));
    update_irqs(s);
    return v;
  }
  if(is_intctl(pa)) {
    return intctl.read(pa);
  }
  switch(pa)
    {
    case 0xff1800000ULL: return aux1;     /* (aux1 overlays the slavio config reg on SS-20) */
    case 0xff1a00000ULL: return diag;
    case 0xff1a01000ULL: return aux2;
    case 0xff1b00000ULL: return mdm;
    case 0xff1600000ULL: return leds;
    case 0xff1f00000ULL: return sysctrl;
    default: break;
    }
  if(is_quiet_region(pa)) {
    return 0;
  }
  fprintf(stderr, "sun4m: unassigned read%u pa 0x%llx pc 0x%x icnt %llu\n", size * 8,
	  static_cast<unsigned long long>(pa), s->pc, static_cast<unsigned long long>(s->icnt));
  *bus_error = true;
  return 0;
}

static void iommu_write(uint32_t *regs, uint32_t r, uint32_t v) {
  switch(r)
    {
    case IOMMU_CTRL:
      regs[r] = (v & 0x1d) | IOMMU_VERSION;
      break;
    case IOMMU_BASE:
      regs[r] = v & 0x07fffc00;
      break;
    case IOMMU_AER:
      regs[r] = (v & 0x801f000f) | 0x1;
      break;
    case IOMMU_AFSR:
      regs[r] = (v & 0xff0fffff) | IOMMU_AFSR_RESV;
      break;
    case IOMMU_ARBEN:
      regs[r] = (v & 0x001f0000) | IOMMU_MID;
      break;
    case IOMMU_MASK_ID:
      regs[r] |= v & 0x00ffffff;
      break;
    default:
      if(r >= IOMMU_SBCFG0 and r <= IOMMU_SBCFG3) {
	regs[r] = v & 0x00010003;
      }
      else {
	regs[r] = v;
      }
      break;
    }
}

static void ecc_write(uint32_t *regs, uint32_t r, uint32_t v) {
  switch(r)
    {
    case ECC_MER: regs[r] = ECC_VERSION | (v & 0xbff); break;
    case ECC_MDR: regs[r] = v & 0x7fffffff; break;
    case ECC_MFSR: case ECC_VCR: case ECC_DR: case ECC_ECR0: regs[r] = v; break;
    case ECC_ECR1: regs[ECC_ECR0] = v; break;
    default: break;
    }
}

void sun4m_t::write(state_t *s, uint64_t pa, uint32_t size, uint32_t v, bool *bus_error) {
  if(pa >= 0xff1200000ULL and pa < 0xff1200000ULL + SUN4M_NVRAM_SIZE) {
    uint32_t off = static_cast<uint32_t>(pa - 0xff1200000ULL);
    for(uint32_t i = 0; i < size; i++) {
      nvram[off + i] = static_cast<uint8_t>(v >> (8 * (size - 1 - i)));
    }
    return;
  }
  if(pa >= 0xfe0000000ULL and pa < 0xfe0004000ULL) {
    iommu_write(iommu, static_cast<uint32_t>(pa - 0xfe0000000ULL) >> 2, v);
    return;
  }
  if(pa >= 0xf00000000ULL and pa < 0xf00000000ULL + 4*SUN4M_ECC_NREGS) {
    ecc_write(ecc, static_cast<uint32_t>(pa - 0xf00000000ULL) >> 2, v);
    return;
  }
  if(pa >= 0xff1000000ULL and pa < 0xff1000008ULL) {
    kbd_ms.write(static_cast<uint32_t>(pa - 0xff1000000ULL), v);
    update_irqs(s);
    return;
  }
  if(pa >= 0xff1100000ULL and pa < 0xff1100008ULL) {
    serial.write(static_cast<uint32_t>(pa - 0xff1100000ULL), v);
    update_irqs(s);
    return;
  }
  if(is_intctl(pa)) {
    intctl.write(pa, v);
    update_irqs(s);
    return;
  }
  switch(pa)
    {
    case 0xff1800000ULL:                  /* aux1: the floppy TC pulse bit never sticks */
      aux1 = static_cast<uint8_t>(v & ~0x02u);
      return;
    case 0xff1a00000ULL:
      diag = static_cast<uint8_t>(v);
      return;
    case 0xff1a01000ULL: {                /* aux2: power-off / power-fail int clear */
      uint8_t a = static_cast<uint8_t>((v & 0x03) | (aux2 & 0x20));
      if(a & 0x02) {
	a &= 0x01;
      }
      aux2 = a;
      if(a & 0x01) {
	fprintf(stderr, "sun4m: software power-off at pc 0x%x\n", s->pc);
	s->brk = true;
      }
      return;
    }
    case 0xff1b00000ULL:
      mdm = static_cast<uint8_t>(v);
      return;
    case 0xff1600000ULL:
      leds = static_cast<uint16_t>(v);
      return;
    case 0xff1f00000ULL:
      if(v & 1) {                          /* SYS_RESET */
	fprintf(stderr, "sun4m: system reset requested at pc 0x%x (not modeled)\n", s->pc);
	sysctrl = 0x2;
	s->brk = true;
      }
      return;
    default:
      break;
    }
  if(is_quiet_region(pa)) {
    return;
  }
  fprintf(stderr, "sun4m: unassigned write%u pa 0x%llx = 0x%x pc 0x%x icnt %llu\n", size * 8,
	  static_cast<unsigned long long>(pa), v, s->pc, static_cast<unsigned long long>(s->icnt));
  *bus_error = true;
}
