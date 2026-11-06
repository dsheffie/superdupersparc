#ifndef __SUN4M_HH__
#define __SUN4M_HH__

#include <cstdint>
#include <map>
#include <vector>

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

/* slavio counter/timers (qemu slavio_timer.c): timer 0 = the system timer
 * (0xff1310000, intctl source 19), 1..SUN4M_NTIMER_CPUS = the per-CPU counters
 * (0xff1300000 + n*0x1000, the CPU's level-14 line).  A counter counts 500 ns
 * periods in bits [30:9] up to its limit, then wraps, sets bit 31 (reached) and
 * raises its interrupt; limit 0 free-runs with no interrupt.  A CPU counter in
 * user-timer mode (the system timer's mode register) is instead a 63-bit
 * counter the CPU starts/stops.  Time = (icnt << ns_shift) + time_bias_ns
 * (qemu -icount shift=N,sleep=off): deterministic, and a CPU halted by the APC
 * skips straight to the next timer event, as qemu's icount warp does. */
#define SUN4M_NTIMER_CPUS 4
#define SUN4M_NUM_CPUS 1
struct slavio_ctr_t {
  uint64_t limit = 0;       /* bits [30:9] (63:9 user), as written */
  uint64_t start_ns = 0;    /* counter mode: when the count was last 0 */
  uint64_t next_ns = 0;     /* counter mode: next limit match */
  uint64_t ubase = 0;       /* user mode: count when last started/written */
  uint32_t count = 0, counthigh = 0;   /* last value read out (user writes keep the other half) */
  uint32_t reached = 0;
  bool run = false;         /* the status register's start/stop bit */
  bool on = false;          /* counting: a counter always (once started), a user timer while run */
  bool irq = false;
};

/* qemu fw_cfg (hw/nvram/fw_cfg.c, the sun4m memory-mapped form, no DMA): a
 * 16-bit big-endian selector at 0xd00000510 and a byte-wide data port at
 * 0xd00000512 that streams the selected item.  OpenBIOS reads the -kernel boot
 * parameters from it.  Integers are stored little-endian, as qemu does. */
#define SUN4M_FW_CFG_BASE 0xd00000510ULL
class fw_cfg_t {
public:
  std::map<uint16_t, std::vector<uint8_t>> items;
  uint16_t cur = 0xffff;
  uint32_t off = 0;
  void add_bytes(uint16_t key, const void *p, size_t n);
  void add_i16(uint16_t key, uint16_t v);
  void add_i32(uint16_t key, uint32_t v);
  void add_i64(uint16_t key, uint64_t v);
  void select(uint16_t key);
  uint8_t read();
};

/* 82077-style floppy controller at 0xff1700000 (qemu hw/block/fdc.c as the
 * sun4m SUNW,fdtwo: no DMA, no drive attached, interrupt = intctl source 22).
 * Models the command/result FIFO protocol for the commands OpenBIOS and Linux
 * issue when probing (SPECIFY, RECALIBRATE, SENSE INTERRUPT, DUMPREG,
 * PERPENDICULAR, CONFIGURE, LOCK, VERSION, PART ID); anything else answers
 * "invalid command".  Register offsets: 0 SRA, 1 SRB, 2 DOR, 3 TDR, 4 MSR (read)
 * / DSR (write), 5 FIFO, 7 DIR (read) / CCR (write). */
class fdc_t {
public:
  enum phase_t { CMD, RESULT };
  uint8_t sra = 0, srb = 0, dor = 0, msr = 0, dsr = 0;
  uint8_t status0 = 0;
  uint8_t fifo[16] = {0};
  uint32_t pos = 0, len = 1;
  phase_t phase = CMD;
  uint32_t reset_sensei = 0;
  uint8_t timer0 = 0, timer1 = 0, config = 0x60, precomp = 0, lock = 0, perpendicular = 0;
  bool irq = false;
  fdc_t();
  uint8_t read(uint32_t reg);
  void write(uint32_t reg, uint8_t v);
private:
  void reset(bool do_irq);
  void raise_irq();
  void reset_irq();
  void to_command();
  void to_result(uint32_t n);
  void execute();
};

/* sun4m DMA2 engine (qemu hw/dma/sparc32_dma.c): espdma at 0xef0400000 and
 * ledma at 0xef0400010, four registers each: 0 CSR, 1 address, 2 count, 3 the
 * ledma address high bits.  The attached chip's interrupt lands in CSR bit 0
 * and goes out (espdma: intctl source 18, ledma: 16) when CSR.INTREN is set;
 * CSR.RESET pulses the chip's reset, CSR.EN its DMA-enable line. */
struct sparc_dma_t {
  uint32_t r[4] = {0xa0000000u, 0, 0, 0};
  bool irq = false;          /* the line to the interrupt controller */
};

/* NCR53C9x / FAS100A SCSI controller at 0xef0800000 (16 byte registers, 4 apart;
 * qemu 8.2 hw/scsi/esp.c as the sparc32 espdma's ESP).  No SCSI devices are
 * attached, so a selection always ends in a timeout (disconnect).  DMA command
 * reads go through the espdma address register; their bytes are not needed
 * (nobody answers), only the address advance. */
struct esp_t {
  uint8_t rregs[16] = {0}, wregs[16] = {0};
  uint8_t fifo[16] = {0};
  uint32_t fifo_n = 0;
  bool tchi_written = false;
  bool dma = false;          /* the current command is a DMA command */
  bool dma_enabled = true;   /* the espdma enable line (qemu: 1 at realize) */
  bool satn_pending = false; /* a DMA Select With ATN waiting for the enable line */
  bool irq = false;          /* to the espdma */
};

class sun4m_t {
public:
  fw_cfg_t fw_cfg;
  sparc_dma_t espdma, ledma;
  esp_t esp;
  intctl_t intctl;
  slavio_ctr_t ctr[SUN4M_NTIMER_CPUS + 1];
  uint32_t ctr_user_mode = 0;          /* bit n: CPU n's counter is a user timer */
  uint32_t ns_shift = 4;               /* ns per instruction = 1 << ns_shift */
  uint64_t next_event_icnt = ~0ULL;    /* the main loop calls timer_event() at this icnt */
  uint64_t next_event_ns = ~0ULL;      /* ... the time of that event */
  uint64_t time_bias_ns = 0;           /* time skipped while the CPU was halted */
  bool cpu_halted = false;             /* an APC (0xefa000000) write: halt until an interrupt */
  int64_t rtc_base = 1767225600;       /* the RTC at time 0: 2026-01-01T00:00:00 UTC (--rtc-base) */
  bool reset_req = false;              /* a SYS_RESET write: the main loop resets the machine */
  escc_t kbd_ms{true, false};     /* 0xff1000000: keyboard/mouse (disabled, as qemu -nographic) */
  escc_t serial{false, true};     /* 0xff1100000: ttya/ttyb */
  /* slavio misc byte registers */
  uint8_t aux1 = 0, aux2 = 0, diag = 0, mdm = 0;
  fdc_t fdc;
  uint16_t leds = 0;
  uint32_t sysctrl = 0;
  uint8_t prom[SUN4M_PROM_SIZE] = {0};
  uint8_t nvram[SUN4M_NVRAM_SIZE] = {0};
  uint32_t iommu[SUN4M_IOMMU_NREGS] = {0};
  uint32_t ecc[SUN4M_ECC_NREGS] = {0};

  sun4m_t();
  bool load_prom(const char *fn);   /* an ELF (OpenBIOS) loads at vaddr - 0xffd00000 */
  bool load_nvram(const char *fn);
  /* size is 1, 2 or 4 bytes; values in host order.  An access to an unassigned
   * address sets *bus_error (the CPU records an access bus error, FT=5). */
  uint32_t read(state_t *s, uint64_t pa, uint32_t size, bool *bus_error);
  void write(state_t *s, uint64_t pa, uint32_t size, uint32_t v, bool *bus_error);
  void update_irqs(state_t *s);
  void timer_event(state_t *s);
  /* system reset (qemu_system_reset): every device back to its reset state at
   * time now; the PROM, NVRAM, diag and system-control registers survive */
  void reset_devices(uint64_t now);
  uint64_t now_ns(const state_t *s) const;
  /* the time a device access sees: qemu's icount clock has already counted
   * the instruction doing the I/O */
  uint64_t io_now_ns(const state_t *s) const {
    return now_ns(s) + (1ULL << ns_shift);
  }
  /* halted: jump time to the next timer event and run it; false if none is due */
  bool warp_to_next_event(state_t *s);
private:
  uint64_t ctr_user_count(const slavio_ctr_t &t, uint64_t now) const;
  uint32_t ctr_read(state_t *s, uint32_t idx, uint32_t reg);
  void ctr_write(state_t *s, uint32_t idx, uint32_t reg, uint32_t v);
  void ctr_restart(slavio_ctr_t &t, uint64_t now);
  void dma_write(state_t *s, sparc_dma_t &d, bool is_esp, uint32_t reg, uint32_t v);
  void dma_set_irq(sparc_dma_t &d, bool level);
  void esp_hard_reset();
  void esp_set_irq(bool raise);
  void esp_select_atn();
  uint8_t esp_read(uint32_t reg);
  void esp_write(uint32_t reg, uint8_t v);
  void ctr_schedule(const state_t *s);
  bool ctr_is_user(uint32_t idx) const {
    return idx != 0 and ((ctr_user_mode >> (idx - 1)) & 1);
  }
};

#endif
