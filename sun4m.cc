#include <algorithm>
#include <cstdio>
#include <cstring>
#include <ctime>

#include "sun4m.hh"
#include "interpret.hh"
#include "loadelf.hh"

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

escc_t::escc_t(bool disabled_, bool console_, bool serio_) : disabled(disabled_), console(console_), serio(serio_) {
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

bool escc_t::can_receive(int c) const {
  const chn_t &s = chn[c];
  return (s.wregs[W_RXCTRL] & 0x01) and not (s.rregs[R_STATUS] & STATUS_RXAV);
}

void escc_t::receive(int c, uint8_t v) {
  chn_t &s = chn[c];
  s.rregs[R_STATUS] |= STATUS_RXAV;
  s.rx = v;
  set_rxint(c);
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
  return serio ? get_queue(c) : s.rx;
}

/* qemu put_queue / get_queue: the keyboard and mouse send through a 256-byte
 * queue; every byte (re)raises receive-available */
void escc_t::put_queue(int c, uint8_t v) {
  chn_t &s = chn[c];
  if(s.queue.size() >= 256) {
    return;
  }
  s.queue.push_back(v);
  receive(c, 0);
}

uint8_t escc_t::get_queue(int c) {
  chn_t &s = chn[c];
  if(s.queue.empty()) {
    return 0;
  }
  const uint8_t v = s.queue.front();
  s.queue.erase(s.queue.begin());
  if(not s.queue.empty()) {
    receive(c, 0);
  }
  return v;
}

/* qemu handle_kbd_command: reset answers ff, the type (4), 7f idle; the
 * layout query answers fe and the DIP switches (0x21, en-us); the byte after
 * set-LEDs is the LED state */
void escc_t::kbd_command(uint8_t v) {
  if(led_mode) {
    led_mode = false;
    return;
  }
  switch(v)
    {
    case 0x01:
      chn[CHN_A].queue.clear();
      put_queue(CHN_A, 0xff);
      put_queue(CHN_A, 0x04);
      put_queue(CHN_A, 0x7f);
      break;
    case 0x0e:
      led_mode = true;
      break;
    case 0x07:
    case 0x0f:
      chn[CHN_A].queue.clear();
      put_queue(CHN_A, 0xfe);
      put_queue(CHN_A, 0x21);
      break;
    default:
      break;
    }
}

bool escc_t::kbd_idle() const {
  return chn[CHN_A].queue.empty() and not (chn[CHN_A].rregs[R_STATUS] & STATUS_RXAV);
}

void escc_t::kbd_event(uint8_t keycode, bool down) {
  if(serio) {
    put_queue(CHN_A, down ? keycode : (keycode | 0x80));
  }
}

/* qemu sunmouse_sync: a 5-byte Mouse Systems packet -- 0x87 ^ buttons, dx,
 * dy (each clamped to +-127; any rest goes in later packets), two zero
 * motion bytes */
void escc_t::mouse_event(int32_t dx, int32_t dy, uint8_t buttons) {
  if(not serio) {
    return;
  }
  mouse_dx += dx;
  mouse_dy -= dy;
  if(buttons != (mouse_buttons & 0x07)) {
    mouse_buttons = buttons | 0x80;
  }
  while(mouse_dx != 0 or mouse_dy != 0 or (mouse_buttons & 0x80)) {
    mouse_buttons &= ~0x80;
    put_queue(CHN_B, 0x87 ^ mouse_buttons);
    const int32_t x = std::max(-127, std::min(127, mouse_dx));
    put_queue(CHN_B, static_cast<uint8_t>(x));
    mouse_dx -= x;
    const int32_t y = std::max(-127, std::min(127, mouse_dy));
    put_queue(CHN_B, static_cast<uint8_t>(y));
    mouse_dy -= y;
    put_queue(CHN_B, 0);
    put_queue(CHN_B, 0);
  }
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
    else if(serio and c == CHN_A and not disabled) {
      kbd_command(s.tx);
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

/* ---------------------------------------------------------------- fw_cfg */

void fw_cfg_t::add_bytes(uint16_t key, const void *p, size_t n) {
  const uint8_t *b = static_cast<const uint8_t *>(p);
  items[key] = std::vector<uint8_t>(b, b + n);
}
void fw_cfg_t::add_i16(uint16_t key, uint16_t v) {
  uint8_t b[2] = {static_cast<uint8_t>(v), static_cast<uint8_t>(v >> 8)};
  add_bytes(key, b, 2);
}
void fw_cfg_t::add_i32(uint16_t key, uint32_t v) {
  uint8_t b[4];
  for(int i = 0; i < 4; i++) {
    b[i] = static_cast<uint8_t>(v >> (8 * i));
  }
  add_bytes(key, b, 4);
}
void fw_cfg_t::add_i64(uint16_t key, uint64_t v) {
  uint8_t b[8];
  for(int i = 0; i < 8; i++) {
    b[i] = static_cast<uint8_t>(v >> (8 * i));
  }
  add_bytes(key, b, 8);
}
void fw_cfg_t::select(uint16_t key) {
  cur = key;
  off = 0;
}
uint8_t fw_cfg_t::read() {
  /* an unknown item, or past its end, reads 0 */
  auto it = items.find(cur);
  if(it == items.end() or off >= it->second.size()) {
    return 0;
  }
  return it->second[off++];
}

/* ------------------------------------------------------------------- fdc */

enum : uint8_t {
  FD_SRA_NDRV2 = 0x40, FD_SRA_INTPEND = 0x80, FD_DOR_NRESET = 0x04, FD_DOR_DMAEN = 0x08,
  FD_DSR_SWRESET = 0x80, FD_DSR_PWRDOWN = 0x40, FD_MSR_CMDBUSY = 0x10, FD_MSR_DIO = 0x40,
  FD_MSR_RQM = 0x80, FD_SR0_SEEK = 0x20, FD_SR0_INVCMD = 0x80, FD_SR0_RDYCHG = 0xc0
};
static const uint32_t FD_RESET_SENSEI_COUNT = 4;
static const uint8_t FD_LAST_SECT = 0xff;   /* an empty drive's last sector, as qemu's DUMPREG shows */

fdc_t::fdc_t() {
  reset(false);
}

void fdc_t::raise_irq() {
  if(not (sra & FD_SRA_INTPEND)) {
    irq = true;
    sra |= FD_SRA_INTPEND;
  }
  reset_sensei = 0;
}

void fdc_t::reset_irq() {
  status0 = 0;
  if(sra & FD_SRA_INTPEND) {
    irq = false;
    sra &= ~FD_SRA_INTPEND;
  }
}

void fdc_t::to_command() {
  phase = CMD;
  pos = 0;
  len = 1;
  msr = (msr & ~(FD_MSR_CMDBUSY | FD_MSR_DIO)) | FD_MSR_RQM;
}

void fdc_t::to_result(uint32_t n) {
  phase = RESULT;
  len = n;
  pos = 0;
  msr |= FD_MSR_CMDBUSY | FD_MSR_RQM | FD_MSR_DIO;
}

/* qemu fdctrl_reset: the sun4m controller has no DMA channel and one (empty) drive */
void fdc_t::reset(bool do_irq) {
  reset_irq();
  sra = FD_SRA_NDRV2;
  srb = 0xc0;
  dor = FD_DOR_NRESET;
  msr = FD_MSR_RQM;
  reset_sensei = 0;
  to_command();
  if(do_irq) {
    status0 |= FD_SR0_RDYCHG;
    raise_irq();
    reset_sensei = FD_RESET_SENSEI_COUNT;
  }
}

/* the number of parameter bytes after the command byte */
static uint32_t fdc_params(uint8_t cmd) {
  switch(cmd)
    {
    case 0x03: return 2;   /* SPECIFY */
    case 0x07: return 1;   /* RECALIBRATE */
    case 0x12: return 1;   /* PERPENDICULAR MODE */
    case 0x13: return 3;   /* CONFIGURE */
    default: return 0;     /* SENSE INTERRUPT, DUMPREG, VERSION, PART ID, LOCK, unknown */
    }
}

void fdc_t::execute() {
  uint8_t cmd = fifo[0];
  if((cmd & 0x7f) == 0x14) {                 /* LOCK */
    lock = (cmd & 0x80) ? 1 : 0;
    fifo[0] = lock << 4;
    to_result(1);
    return;
  }
  switch(cmd)
    {
    case 0x03:                               /* SPECIFY */
      timer0 = (fifo[1] >> 4) & 0xf;
      timer1 = fifo[2] >> 1;
      dor = (fifo[2] & 1) ? (dor & ~FD_DOR_DMAEN) : (dor | FD_DOR_DMAEN);
      to_command();
      break;
    case 0x07:                               /* RECALIBRATE: track 0, seek-end interrupt */
      dor = (dor & ~3) | (fifo[1] & 3);
      to_command();
      status0 |= FD_SR0_SEEK;
      raise_irq();
      break;
    case 0x08:                               /* SENSE INTERRUPT STATUS */
      if(reset_sensei > 0) {
	fifo[0] = FD_SR0_RDYCHG + FD_RESET_SENSEI_COUNT - reset_sensei;
	reset_sensei--;
      }
      else if(not (sra & FD_SRA_INTPEND)) {
	fifo[0] = FD_SR0_INVCMD;
	to_result(1);
	return;
      }
      else {
	fifo[0] = (status0 & ~0x07) | (dor & 3);
      }
      fifo[1] = 0;                           /* the track: every drive sits at 0 */
      to_result(2);
      reset_irq();
      status0 = FD_SR0_RDYCHG;
      break;
    case 0x0e:                               /* DUMPREG */
      fifo[0] = fifo[1] = fifo[2] = fifo[3] = 0;
      fifo[4] = timer0;
      fifo[5] = (timer1 << 1) | ((dor & FD_DOR_DMAEN) ? 1 : 0);
      fifo[6] = FD_LAST_SECT;
      fifo[7] = (lock << 7) | (perpendicular << 2);
      fifo[8] = config;
      fifo[9] = precomp;
      to_result(10);
      break;
    case 0x10:                               /* VERSION: 82078 */
      fifo[0] = 0x90;
      to_result(1);
      break;
    case 0x12:                               /* PERPENDICULAR MODE */
      if(fifo[1] & 0x80) {
	perpendicular = fifo[1] & 7;
      }
      to_command();
      break;
    case 0x13:                               /* CONFIGURE */
      config = fifo[2];
      precomp = fifo[3];
      to_command();
      break;
    case 0x18:                               /* PART ID: stepping 1 */
      fifo[0] = 0x41;
      to_result(1);
      break;
    default:
      fprintf(stderr, "sun4m: fdc: unmodeled command 0x%02x\n", cmd);
      fifo[0] = FD_SR0_INVCMD;
      to_result(1);
      break;
    }
}

uint8_t fdc_t::read(uint32_t reg) {
  switch(reg & 7)
    {
    case 0: return sra;
    case 1: return srb;
    case 2: return dor;
    case 3: return 0;
    case 4:
      dsr &= ~FD_DSR_PWRDOWN;
      return msr;
    case 5: {
      dsr &= ~FD_DSR_PWRDOWN;
      if(not (msr & FD_MSR_RQM) or not (msr & FD_MSR_DIO)) {
	return 0;
      }
      uint8_t v = fifo[pos % sizeof(fifo)];
      if(++pos == len) {
	msr &= ~FD_MSR_RQM;
	to_command();
	reset_irq();
      }
      return v;
    }
    default: return 0;
    }
}

void fdc_t::write(uint32_t reg, uint8_t v) {
  switch(reg & 7)
    {
    case 2:                                  /* DOR: leaving reset resets the controller */
      if((v & FD_DOR_NRESET) and not (dor & FD_DOR_NRESET)) {
	reset(true);
	dsr &= ~FD_DSR_PWRDOWN;
      }
      dor = v;
      break;
    case 4:                                  /* DSR */
      if(not (dor & FD_DOR_NRESET)) {
	return;
      }
      if(v & FD_DSR_SWRESET) {
	dor &= ~FD_DOR_NRESET;
	reset(true);
	dor |= FD_DOR_NRESET;
      }
      if(v & FD_DSR_PWRDOWN) {
	reset(true);
      }
      dsr = v;
      break;
    case 5: {                                /* FIFO: command and parameter bytes */
      if(not (dor & FD_DOR_NRESET) or not (msr & FD_MSR_RQM) or (msr & FD_MSR_DIO)) {
	return;
      }
      dsr &= ~FD_DSR_PWRDOWN;
      uint32_t p = pos++;
      fifo[p % sizeof(fifo)] = v;
      if(pos == len) {
	msr &= ~FD_MSR_RQM;
      }
      if(p == 0) {
	len = fdc_params(v) + 1;
	if(len > 1) {
	  msr |= FD_MSR_RQM;
	}
	msr |= FD_MSR_CMDBUSY;
      }
      if(pos == len) {
	execute();
      }
      break;
    }
    default:                                 /* TDR, CCR: no effect without a drive */
      break;
    }
}

/* ------------------------------------------------------------- DMA, ESP */

enum : uint32_t {
  DMA_INTR = 0x1, DMA_INTREN = 0x10, DMA_DRAIN_FIFO = 0x40, DMA_RESET = 0x80, DMA_EN = 0x200,
  DMA_LOADED = 0x04000000, DMA_CSR_RO_MASK = 0xfe000007, DMA_VER = 0xa0000000
};

/* qemu dma_set_irq: the chip's interrupt input */
void sun4m_t::dma_set_irq(sparc_dma_t &d, bool level) {
  if(level) {
    d.r[0] |= DMA_INTR;
    if(d.r[0] & DMA_INTREN) {
      d.irq = true;
    }
  }
  else if(d.r[0] & DMA_INTR) {
    d.r[0] &= ~DMA_INTR;
    if(d.r[0] & DMA_INTREN) {
      d.irq = false;
    }
  }
}

/* qemu dma_mem_write (the ESP is the espdma's chip, the Lance the ledma's;
 * the Lance has no use for the enable line) */
void sun4m_t::dma_write(state_t *s, sparc_dma_t &d, bool is_esp, uint32_t reg, uint32_t v) {
  (void)s;
  if(reg != 0) {
    if(reg == 1) {
      d.r[0] |= DMA_LOADED;
    }
    d.r[reg] = v;
    return;
  }
  if(v & DMA_INTREN) {
    if(d.r[0] & DMA_INTR) {
      d.irq = true;
    }
  }
  else if(d.r[0] & (DMA_INTR | DMA_INTREN)) {
    d.irq = false;
  }
  if(v & DMA_RESET) {
    if(is_esp) {             /* the ESP's reset input: a soft reset */
      esp_soft_reset();
    }
    else {
      lance_reset();         /* qemu ledma reset: pcnet_h_reset */
    }
  }
  else if(v & DMA_DRAIN_FIFO) {
    v &= ~DMA_DRAIN_FIFO;
  }
  else if(v == 0) {
    v = DMA_DRAIN_FIFO;
  }
  if(is_esp and (v & DMA_EN) and not (d.r[0] & DMA_EN)) {
    esp_dma_enable(true);    /* qemu esp_dma_enable: run a deferred DMA command */
  }
  else if(is_esp and not (v & DMA_EN) and (d.r[0] & DMA_EN)) {
    esp_dma_enable(false);
  }
  v &= ~DMA_CSR_RO_MASK;
  v |= DMA_VER;
  d.r[0] = (d.r[0] & DMA_CSR_RO_MASK) | v;
}

/* the ESP itself (qemu hw/scsi/esp.c) is in esp.cc */

/* ------------------------------------------------------- counter/timers */

static const uint64_t CTR_PERIOD_NS = 500;
static const uint32_t CTR_COUNT_MASK32 = 0xfffffe00u;
static const uint32_t CTR_LIMIT_MASK32 = 0x7fffffffu;
static const uint64_t CTR_MAX_COUNT64 = 0x7ffffffffffffe00ULL;
static const uint64_t CTR_MAX_COUNT32 = 0x7ffffe00ULL;
static const uint32_t CTR_REACHED = 0x80000000u;
enum : uint32_t { CTR_LIMIT = 0, CTR_COUNTER = 1, CTR_NORST = 2, CTR_STATUS = 3, CTR_MODE = 4 };

/* counter mode: periods between limit matches (qemu's ptimer limit,
 * LIMIT_TO_PERIODS: the count shows 0, 512, ... up to limit - 1024, then wraps) */
static uint64_t ctr_wrap(const slavio_ctr_t &t) {
  uint64_t l = (t.limit != 0) ? t.limit : CTR_MAX_COUNT32;
  uint64_t n = (l >> 9) - 1;
  return (n == 0) ? 1 : n;
}

uint64_t sun4m_t::now_ns(const state_t *s) const {
  return (s->icnt << ns_shift) + time_bias_ns;
}

bool sun4m_t::warp_to_next_event(state_t *s) {
  if(next_event_ns == ~0ULL) {
    return false;
  }
  uint64_t now = now_ns(s);
  if(next_event_ns > now) {
    time_bias_ns += next_event_ns - now;
  }
  timer_event(s);
  return true;
}

/* qemu reads a counter as limit - ((c + 1) << 9) with c = floor(time to the
 * next match / 500 ns) (ptimer_get_count): the elapsed periods round UP */
static uint64_t ctr_periods_up(uint64_t elapsed_ns) {
  return (elapsed_ns + CTR_PERIOD_NS - 1) / CTR_PERIOD_NS;
}

uint64_t sun4m_t::ctr_user_count(const slavio_ctr_t &t, uint64_t now) const {
  uint64_t v = t.ubase;
  if(t.on) {
    v += ctr_periods_up(now - t.start_ns) << 9;
  }
  return v & CTR_MAX_COUNT64;
}

void sun4m_t::ctr_restart(slavio_ctr_t &t, uint64_t now) {
  t.start_ns = now;
  t.next_ns = now + ctr_wrap(t) * CTR_PERIOD_NS;
}

void sun4m_t::ctr_schedule(const state_t *s) {
  (void)s;
  uint64_t next = ~0ULL;
  for(uint32_t i = 0; i <= SUN4M_NTIMER_CPUS; i++) {
    if(ctr[i].on and not ctr_is_user(i) and ctr[i].next_ns < next) {
      next = ctr[i].next_ns;
    }
  }
  /* the first instruction at or after the match */
  next_event_ns = next;
  if(next == ~0ULL) {
    next_event_icnt = ~0ULL;
  }
  else {
    uint64_t rel = (next > time_bias_ns) ? (next - time_bias_ns) : 0;
    next_event_icnt = (rel + (1ULL << ns_shift) - 1) >> ns_shift;
  }
}

void sun4m_t::timer_event(state_t *s) {
  uint64_t now = now_ns(s);
  for(uint32_t i = 0; i <= SUN4M_NTIMER_CPUS; i++) {
    slavio_ctr_t &t = ctr[i];
    if(not t.on or ctr_is_user(i) or now < t.next_ns) {
      continue;
    }
    uint64_t step = ctr_wrap(t) * CTR_PERIOD_NS;
    t.next_ns += ((now - t.next_ns) / step + 1) * step;
    /* free-run (limit 0): no match, no interrupt */
    if(t.limit != 0) {
      t.reached = CTR_REACHED;
      t.irq = true;
    }
  }
  update_irqs(s);
  ctr_schedule(s);
}

uint32_t sun4m_t::ctr_read(state_t *s, uint32_t idx, uint32_t reg) {
  slavio_ctr_t &t = ctr[idx];
  uint64_t now = io_now_ns(s);
  uint32_t v = 0;
  switch(reg)
    {
    case CTR_LIMIT:
      if(ctr_is_user(idx)) {               /* user timer MSW */
	uint64_t c = ctr_user_count(t, now);
	t.count = static_cast<uint32_t>(c) & CTR_COUNT_MASK32;
	t.counthigh = static_cast<uint32_t>(c >> 32);
	v = t.counthigh | t.reached;
      }
      else {                               /* the limit; the read clears the interrupt */
	t.irq = false;
	t.reached = 0;
	update_irqs(s);
	v = static_cast<uint32_t>(t.limit) & CTR_LIMIT_MASK32;
      }
      break;
    case CTR_COUNTER:
      if(ctr_is_user(idx)) {               /* user timer LSW */
	uint64_t c = ctr_user_count(t, now);
	t.count = static_cast<uint32_t>(c) & CTR_COUNT_MASK32;
	t.counthigh = static_cast<uint32_t>(c >> 32);
	v = t.count;
      }
      else {
	uint64_t c = CTR_MAX_COUNT32 - 512;  /* a counter never started (qemu: count 0) */
	if(t.on) {
	  /* periods into the current wrap, rounded up; a match that is due but
	   * not yet processed reads as the last count before the wrap */
	  uint64_t n = ctr_wrap(t);
	  c = (now >= t.next_ns) ? (n << 9) :
	    (ctr_periods_up(now - (t.next_ns - n * CTR_PERIOD_NS)) << 9);
	}
	v = (static_cast<uint32_t>(c) & static_cast<uint32_t>(CTR_MAX_COUNT32)) | t.reached;
      }
      break;
    case CTR_STATUS:
      v = (idx > 0) ? t.run : 0;
      break;
    case CTR_MODE:
      v = ctr_user_mode;
      break;
    default:
      break;
    }
  return v;
}

void sun4m_t::ctr_write(state_t *s, uint32_t idx, uint32_t reg, uint32_t v) {
  slavio_ctr_t &t = ctr[idx];
  uint64_t now = io_now_ns(s);
  switch(reg)
    {
    case CTR_LIMIT:
      if(ctr_is_user(idx)) {               /* user timer MSW: reset the count to it */
	t.limit = CTR_MAX_COUNT64;
	t.counthigh = v & static_cast<uint32_t>(CTR_MAX_COUNT64 >> 32);
	t.reached = 0;
	t.ubase = (static_cast<uint64_t>(t.counthigh) << 32) | t.count;
	t.start_ns = now;
      }
      else {                               /* new limit, count back to 0 */
	t.irq = false;
	t.limit = v & CTR_MAX_COUNT32;
	ctr_restart(t, now);
      }
      break;
    case CTR_COUNTER:
      if(ctr_is_user(idx)) {               /* user timer LSW */
	t.limit = CTR_MAX_COUNT64;
	t.count = v & CTR_COUNT_MASK32;
	t.reached = 0;
	t.ubase = (static_cast<uint64_t>(t.counthigh) << 32) | t.count;
	t.start_ns = now;
      }
      break;
    case CTR_NORST: {
      /* new limit, count kept.  (qemu keeps its ptimer's down-count, so its
       * shown count jumps by the limit difference; this keeps the shown count
       * and moves the next match.  Only the limit-0 free-run form is common.) */
      uint64_t p = (now - t.start_ns) / CTR_PERIOD_NS;
      t.limit = v & CTR_MAX_COUNT32;
      uint64_t n = ctr_wrap(t);
      t.start_ns = now - (p % n) * CTR_PERIOD_NS;
      t.next_ns = t.start_ns + n * CTR_PERIOD_NS;
      break;
    }
    case CTR_STATUS:
      if(ctr_is_user(idx)) {               /* start/stop the user timer */
	if((v & 1) and not t.on) {
	  t.start_ns = now;
	  t.on = true;
	}
	else if(not (v & 1) and t.on) {
	  t.ubase = ctr_user_count(t, now);
	  t.on = false;
	}
      }
      t.run = v & 1;
      break;
    case CTR_MODE:
      if(idx != 0) {
	break;
      }
      for(uint32_t i = 0; i < SUN4M_NUM_CPUS; i++) {
	uint32_t bit = 1u << i;
	slavio_ctr_t &c = ctr[i + 1];
	if((v & bit) == (ctr_user_mode & bit)) {
	  continue;
	}
	if(v & bit) {                      /* counter -> user timer, count 0 */
	  c.irq = false;
	  c.on = c.run;
	  c.limit = CTR_MAX_COUNT64;
	  c.ubase = 0;
	  c.count = 0;
	  c.counthigh = 0;
	  c.start_ns = now;
	  ctr_user_mode |= bit;
	}
	else {                             /* user timer -> counter (always counting) */
	  c.on = true;
	  ctr_restart(c, now);
	  ctr_user_mode &= ~bit;
	}
      }
      break;
    default:
      break;
    }
  update_irqs(s);
  ctr_schedule(s);
}

/* 0xff1300000 + n*0x1000 (CPU n, 0x10) and 0xff1310000 (system, 0x14):
 * the timer index (0 = system, n + 1 = CPU n), or -1 */
static int ctr_index(uint64_t pa) {
  if(pa >= 0xff1310000ULL and pa < 0xff1310014ULL) {
    return 0;
  }
  if(pa >= 0xff1300000ULL and pa < 0xff1300000ULL + 0x1000ULL * SUN4M_NTIMER_CPUS and (pa & 0xff0) == 0) {
    return static_cast<int>((pa - 0xff1300000ULL) >> 12) + 1;
  }
  return -1;
}

sun4m_t::sun4m_t() {
  reset_devices(0);
}

void sun4m_t::reset_devices(uint64_t now) {
  intctl = intctl_t();
  kbd_ms = escc_t(not have_kbd, false, have_kbd);
  serial = escc_t(false, true);
  aux1 = aux2 = mdm = 0;     /* qemu slavio_misc_reset: config, aux1/2, modem ctl */
  fdc = fdc_t();
  espdma = sparc_dma_t();
  ledma = sparc_dma_t();
  esp = esp_t();
  esp_hard_reset();          /* qemu esp_hard_reset at realize */
  lance_reset();
  if(tcx != nullptr) {
    tcx->reset();
  }
  if(cg14 != nullptr) {
    cg14->reset();
  }
  for(scsi_dev_t *d : scsi) {
    if(d != nullptr) {
      d->reset();            /* power-on reset: a unit attention */
    }
  }
  /* power-on reset values, as qemu's iommu_reset / ecc_realize+ecc_reset */
  memset(iommu, 0, sizeof(iommu));
  memset(ecc, 0, sizeof(ecc));
  iommu[IOMMU_CTRL] = IOMMU_VERSION;
  iommu[IOMMU_ARBEN] = IOMMU_MID;
  iommu[IOMMU_AFSR] = IOMMU_AFSR_RESV;
  iommu[IOMMU_AER] = 0x3;                  /* MBus masters 0x8 and 0x9 enabled */
  iommu[IOMMU_MASK_ID] = 0x23000000;
  ecc[ECC_MER] = ECC_VERSION & 0xff000ffcu;
  ecc[ECC_MDR] = 0x20;
  ecc[ECC_MFAR0] = 0x07c00000;
  /* qemu slavio_timer_reset: the system timer and each present CPU's counter
   * free-run from the reset */
  for(uint32_t i = 0; i <= SUN4M_NTIMER_CPUS; i++) {
    ctr[i] = slavio_ctr_t();
  }
  ctr_user_mode = 0;
  for(uint32_t i = 0; i <= SUN4M_NUM_CPUS; i++) {
    ctr[i].on = true;
    ctr[i].run = true;
    ctr_restart(ctr[i], now);
  }
  next_event_icnt = ~0ULL;   /* free-running counters schedule nothing */
  next_event_ns = ~0ULL;
  cpu_halted = false;
  reset_req = false;
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
  /* qemu's prom_init: an ELF (OpenBIOS, linked at 0xffd00000) loads its
   * segments into the PROM at vaddr - 0xffd00000; anything else is a raw image */
  uint32_t entry = 0;
  uint64_t total = 0;
  bool fits = true;
  auto seg = [&](uint32_t vaddr, const uint8_t *data, uint32_t filesz, uint32_t memsz) {
    uint64_t off = static_cast<uint64_t>(vaddr) - 0xffd00000ULL;
    if(vaddr < 0xffd00000u or off + memsz > SUN4M_PROM_SIZE) {
      fits = false;
      return;
    }
    memset(&prom[off], 0, memsz);
    memcpy(&prom[off], data, filesz);
  };
  if(for_each_elf_segment(fn, seg, &entry, &total)) {
    if(not fits) {
      fprintf(stderr, "sun4m: prom elf %s does not fit at 0xffd00000\n", fn);
      return false;
    }
    fprintf(stderr, "sun4m: loaded prom elf %s (%llu bytes)\n", fn, static_cast<unsigned long long>(total));
    return true;
  }
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

/* M48T08 clock registers at the top of the NVRAM (qemu m48t59_read, sun4m
 * base year 1968).  The time is rtc_base plus whole seconds of simulated time,
 * as qemu -rtc base=...,clock=vm, so runs are deterministic. */
static uint8_t m48t08_clock(uint32_t off, const uint8_t *nvram, int64_t t) {
  time_t tt = static_cast<time_t>(t);
  struct tm tm;
  gmtime_r(&tt, &tm);
  switch(off)
    {
    case 0x1ff8: return nvram[off];                                   /* control */
    case 0x1ff9: return (nvram[off] & 0x80) | bcd(tm.tm_sec);         /* seconds, stop bit */
    case 0x1ffa: return bcd(tm.tm_min);
    case 0x1ffb: return bcd(tm.tm_hour);
    case 0x1ffc: return nvram[off] | tm.tm_wday;                      /* day of week, century bits */
    case 0x1ffd: return bcd(tm.tm_mday);
    case 0x1ffe: return bcd(tm.tm_mon + 1);
    case 0x1fff: return bcd((tm.tm_year + 1900 - 1968) % 100);
    default: break;
    }
  return nvram[off];
}

/* The DBRI's 0x30-byte ID PROM at slot e + 0x1000.  OBP's onboard probe
 * creates the DBRI node, adds the audio properties, then runs this as FCode;
 * qemu leaves it empty, which leaves a node with no name that NeXTSTEP's
 * autoconf dereferences (proplen(node, "name") fails -> NULL strcmp, Data
 * access exception).  The real contents aren't dumped; this is a minimal
 * FCode that gives the node what a real SS-20 shows:
 *   " SUNW,DBRIe" device-name  10000 my-space 100 reg  (SUNW,DBRIe@e,10000) */
static const uint64_t DBRI_PROM_BASE = 0xee0001000ULL;
static const uint8_t dbri_prom[0x30] = {
  0xf1, 0x08, 0x03, 0x5b, 0x00, 0x00, 0x00, 0x25,   /* start1, checksum, length */
  0x12, 0x0a, 'S', 'U', 'N', 'W', ',', 'D', 'B', 'R', 'I', 'e',
  0x02, 0x01,                                       /* device-name */
  0x10, 0x00, 0x01, 0x00, 0x00,                     /* b(lit) 0x10000 */
  0x01, 0x03,                                       /* my-space */
  0x10, 0x00, 0x00, 0x01, 0x00,                     /* b(lit) 0x100 */
  0x01, 0x16,                                       /* reg */
  0x00,                                             /* end0 */
};

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
  intctl.set_irq(19, ctr[0].irq);    /* system timer -> level 10 */
  intctl.set_irq(22, fdc.irq);       /* floppy -> level 11 */
  intctl.set_irq(18, espdma.irq);    /* espdma (ESP) -> level 4 */
  intctl.set_irq(16, ledma.irq);     /* ledma (Lance) -> level 6 */
  for(uint32_t i = 0; i < SUN4M_NTIMER_CPUS; i++) {
    intctl.set_cpu_timer_irq(i, ctr[i + 1].irq);   /* CPU counter -> level 14 */
  }
  s->irl = intctl.irl(0);
}

uint32_t sun4m_t::read(state_t *s, uint64_t pa, uint32_t size, bool *bus_error) {
  io_s = s;
  if(tcx != nullptr and pa >= tcx_t::BASE and pa < tcx_t::BASE + tcx_t::SPAN) {
    return tcx->read(pa - tcx_t::BASE, size);
  }
  if(cg14 != nullptr and ((pa >= cg14_t::REG_BASE and pa < cg14_t::REG_BASE + cg14_t::REG_SPAN) or
			  (pa >= cg14_t::VRAM_BASE and pa < cg14_t::VRAM_BASE + cg14_t::VRAM_SPAN))) {
    return cg14->read(pa, size);
  }
  if(pa >= SUN4M_PROM_BASE and pa < SUN4M_PROM_BASE + SUN4M_PROM_SIZE) {
    return be_read(&prom[pa - SUN4M_PROM_BASE], size);
  }
  if(pa >= 0xff1200000ULL and pa < 0xff1200000ULL + SUN4M_NVRAM_SIZE) {
    uint32_t off = static_cast<uint32_t>(pa - 0xff1200000ULL);
    uint32_t v = 0;
    for(uint32_t i = 0; i < size; i++) {
      v = (v << 8) | m48t08_clock(off + i, nvram, rtc_base + static_cast<int64_t>(io_now_ns(s) / 1000000000ULL));
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
  if(int ci = ctr_index(pa); ci >= 0) {
    return ctr_read(s, static_cast<uint32_t>(ci), static_cast<uint32_t>(pa & 0x1f) >> 2);
  }
  if(pa == SUN4M_FW_CFG_BASE + 2 and size == 1) {
    return fw_cfg.read();
  }
  if(pa >= 0xef0400000ULL and pa < 0xef0400024ULL and size == 4) {
    uint32_t off = static_cast<uint32_t>(pa - 0xef0400000ULL);
    if(off >= 0x20) {
      return ledma.r[1];     /* qemu's ledma alias */
    }
    return ((off < 0x10) ? espdma : ledma).r[(off & 0xf) >> 2];
  }
  if(pa >= 0xef0800000ULL and pa < 0xef0800040ULL and size == 1) {
    uint32_t v = esp_read(static_cast<uint32_t>(pa - 0xef0800000ULL) >> 2);
    update_irqs(s);
    return v;
  }
  if(pa == 0xefa000000ULL and size == 1) {
    return 0;                /* APC (qemu: reads 0) */
  }
  if(pa >= 0xef0c00000ULL and pa < 0xef0c00004ULL) {
    uint32_t v = lance_read(static_cast<uint32_t>(pa >> 1) & 1);
    update_irqs(s);
    return v;
  }
  if(pa >= 0xff1700000ULL and pa < 0xff1700008ULL) {
    uint32_t v = fdc.read(static_cast<uint32_t>(pa & 7));
    update_irqs(s);
    return v;
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
  if(pa >= DBRI_PROM_BASE and pa + size <= DBRI_PROM_BASE + sizeof(dbri_prom)) {
    return be_read(&dbri_prom[pa - DBRI_PROM_BASE], size);
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
  io_s = s;
  if(tcx != nullptr and pa >= tcx_t::BASE and pa < tcx_t::BASE + tcx_t::SPAN) {
    tcx->write(pa - tcx_t::BASE, size, v);
    return;
  }
  if(cg14 != nullptr and ((pa >= cg14_t::REG_BASE and pa < cg14_t::REG_BASE + cg14_t::REG_SPAN) or
			  (pa >= cg14_t::VRAM_BASE and pa < cg14_t::VRAM_BASE + cg14_t::VRAM_SPAN))) {
    cg14->write(pa, size, v);
    return;
  }
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
  if(int ci = ctr_index(pa); ci >= 0) {
    ctr_write(s, static_cast<uint32_t>(ci), static_cast<uint32_t>(pa & 0x1f) >> 2, v);
    return;
  }
  if(pa == SUN4M_FW_CFG_BASE and size == 2) {
    fw_cfg.select(static_cast<uint16_t>(v));
    return;
  }
  if(pa >= 0xef0400000ULL and pa < 0xef0400024ULL and size == 4) {
    uint32_t off = static_cast<uint32_t>(pa - 0xef0400000ULL);
    if(off >= 0x20) {
      dma_write(s, ledma, false, 1, v);
    }
    else if(off < 0x10) {
      dma_write(s, espdma, true, off >> 2, v);
    }
    else {
      dma_write(s, ledma, false, (off & 0xf) >> 2, v);
    }
    update_irqs(s);
    return;
  }
  if(pa >= 0xef0800000ULL and pa < 0xef0800040ULL and size == 1) {
    esp_write(static_cast<uint32_t>(pa - 0xef0800000ULL) >> 2, static_cast<uint8_t>(v));
    update_irqs(s);
    return;
  }
  if(pa == 0xefa000000ULL and size == 1) {
    cpu_halted = true;       /* APC: idle the CPU until an interrupt */
    return;
  }
  if(pa >= 0xef0c00000ULL and pa < 0xef0c00004ULL) {
    lance_write(static_cast<uint32_t>(pa >> 1) & 1, static_cast<uint16_t>(v));
    update_irqs(s);
    return;
  }
  if(pa >= 0xff1700000ULL and pa < 0xff1700008ULL) {
    fdc.write(static_cast<uint32_t>(pa & 7), static_cast<uint8_t>(v));
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
      if(v & 1) {                          /* SYS_RESET: RESETSTAT tells the PROM it was one */
	fprintf(stderr, "sun4m: system reset at pc 0x%x icnt %llu\n", s->pc,
		static_cast<unsigned long long>(s->icnt));
	sysctrl = 0x2;
	reset_req = true;
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
