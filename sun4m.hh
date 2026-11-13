#ifndef __SUN4M_HH__
#define __SUN4M_HH__

#include <cstdint>
#include <map>
#include <vector>

#include "scsi.hh"
#include "tcx.hh"
#include "cg14.hh"

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
    std::vector<uint8_t> queue;          /* qemu ESCCSERIOQueue (keyboard/mouse channels) */
  };
  chn_t chn[2];
  bool disabled = false;    /* qemu "disabled": no keyboard/mouse behind it */
  bool console = false;     /* channel A transmit goes to stdout */
  bool serio = false;       /* a Sun keyboard on channel A, a Sun mouse on channel B */
  bool irq = false;
  bool led_mode = false;                 /* the next keyboard byte is the LED state */
  int32_t mouse_dx = 0, mouse_dy = 0;
  uint8_t mouse_buttons = 0;             /* qemu sunmouse_buttons (0x80: a button changed) */
  escc_t(bool disabled_, bool console_, bool serio_ = false);
  /* host keyboard and mouse (qemu sunkbd_handle_event, sunmouse_handle_event +
   * sunmouse_sync): a Sun keycode, or motion (y down positive) and buttons
   * (bit 2 left, 1 middle, 0 right) */
  void kbd_event(uint8_t keycode, bool down);
  void mouse_event(int32_t dx, int32_t dy, uint8_t buttons);
  /* the keyboard channel has handed every byte to the CPU */
  bool kbd_idle() const;
  uint32_t read(uint32_t off);
  void write(uint32_t off, uint32_t v);
  /* host input (qemu serial_can_receive / serial_receive_byte): a byte for
   * channel c (1 = A, ttya) when its receiver is enabled and empty */
  bool can_receive(int c) const;
  void receive(int c, uint8_t v);
private:
  void soft_reset(int c);
  void hard_reset(int c);
  bool irq_chn(int c) const;
  void update_irq();
  void set_txint(int c);
  void clr_txint(int c);
  void set_rxint(int c);
  void clr_rxint(int c);
  void put_queue(int c, uint8_t v);
  uint8_t get_queue(int c);
  void kbd_command(uint8_t v);
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

/* NCR53C9x / FAS100A SCSI controller at 0xef0800000 (16 byte registers, 4 apart):
 * qemu 8.2 hw/scsi/esp.c as the sparc32 espdma's ESP (esp.cc), with the targets
 * of scsi.hh on its bus.  The espdma moves every DMA byte (the PDMA paths of
 * other ESP hosts do not exist here).  The request in flight -- qemu's
 * current_req and the async buffer -- is part of the state. */
struct esp_t {
  uint8_t rregs[16] = {0}, wregs[16] = {0};
  std::vector<uint8_t> fifo;       /* the 16-byte data FIFO */
  std::vector<uint8_t> cmdfifo;    /* the 32-byte message + command FIFO */
  bool tchi_written = false;
  int32_t ti_size = 0;             /* data still to move: > 0 in, < 0 out */
  uint8_t status = 0;              /* the target's status byte */
  bool dma = false;                /* the current command is a DMA command */
  bool do_cmd = false;             /* FIFO writes / TI collect message or command bytes */
  bool data_in_ready = false;
  uint8_t ti_cmd = 0;              /* the TI command (DMA bit included) running the transfer */
  uint32_t cmdfifo_cdb_offset = 0; /* message bytes ahead of the CDB in cmdfifo */
  uint8_t lun = 0;                 /* from the IDENTIFY message */
  bool identified = false;         /* this selection sent an IDENTIFY */
  bool dma_enabled = true;         /* the espdma enable line (qemu: 1 at realize) */
  uint8_t dma_cb = 0;              /* a DMA command waiting for the enable line (esp.cc) */
  int32_t cur_tgt = -1;            /* the selected target (qemu current_dev) */
  bool req_active = false;         /* a request in flight (qemu current_req) */
  bool req_sent = false;           /* its data buffer went to the ESP (scsi_req_continue) */
  scsi_req_t req;
  uint32_t async_off = 0, async_len = 0;  /* the part of req.buf still to move */
  bool irq = false;                /* to the espdma */
  bool irq_deferred = false;       /* a raise held until the DMA's writes land (dma_busy) */
};

/* Am7990 Lance Ethernet at 0xef0c00000 (RDP at +0, RAP at +2), the ledma's
 * chip (lance.cc).  Only what a driver needs to bring it up: INIT reads the
 * init block, STRT/STOP, and TDMD takes frames off the transmit ring.  There
 * is no network: transmitted frames are dropped and nothing is received. */
struct lance_t {
  uint16_t csr[4] = {0x0004, 0, 0, 0};   /* CSR0 = STOP at reset */
  uint16_t rap = 0;
  uint32_t tdra = 0, rdra = 0;           /* ring bases (24-bit Lance addresses) */
  uint32_t tlen = 1, rlen = 1;           /* ring lengths */
  uint32_t tx_idx = 0;                   /* next transmit descriptor */
};

class sun4m_t {
public:
  fw_cfg_t fw_cfg;
  sparc_dma_t espdma, ledma;
  esp_t esp;
  lance_t lance;
  tcx_t *tcx = nullptr;                /* SBus slot 2 framebuffer (main: --tcx) */
  cg14_t *cg14 = nullptr;              /* VSIMM framebuffer (main: --cg14) */
  bool have_kbd = false;               /* a Sun keyboard + mouse on kbd_ms (main: with --tcx) */
  scsi_dev_t *scsi[8] = {nullptr};     /* the ESP's targets (main: --scsi-disk / --scsi-cdrom) */
  state_t *io_s = nullptr;             /* the CPU state of the access in progress (DMA to RAM) */
  state_t *dma_mirror = nullptr;       /* a second RAM image DMA writes also land in (the RTL
					  testbench's memory: superdupersparc top.cc); null here */
  /* instead of dma_mirror: hand each DMA write to RAM to the RTL testbench,
   * which snoops the RTL's caches before the bytes reach its memory image */
  void (*dma_hook)(void *ctx, uint64_t pa, const uint8_t *buf, uint32_t len) = nullptr;
  void *dma_hook_ctx = nullptr;
  /* coherence with caches the DMA cannot see (Kodiak's ARM, which reads and writes
   * DRAM directly): called before the IOMMU reads an IOPTE or DMA reads RAM, and
   * before and after DMA writes RAM, for the bytes [pa, pa + len); the caller
   * snoops those lines out of the CPU's caches (null: the DMA is coherent) */
  void (*dma_snoop)(void *ctx, uint64_t pa, uint32_t len) = nullptr;
  void *dma_snoop_ctx = nullptr;
  /* a DMA completes only after its writes are visible to the CPU, as on the bus.
   * With dma_hook the RTL testbench queues the writes behind cache snoops: while
   * dma_busy says some are still queued, the ESP's interrupt -- its INT status
   * bit, the espdma's pending bit and the line, all of which a driver may poll --
   * is held, and the host calls dma_drained() once the queue empties (null: DMA
   * writes are visible at once) */
  bool (*dma_busy)(void *ctx) = nullptr;
  void *dma_busy_ctx = nullptr;
  void dma_drained();
  intctl_t intctl;
  slavio_ctr_t ctr[SUN4M_NTIMER_CPUS + 1];
  uint32_t ctr_user_mode = 0;          /* bit n: CPU n's counter is a user timer */
  uint32_t ns_shift = 4;               /* ns per instruction = 1 << ns_shift */
  uint64_t next_event_icnt = ~0ULL;    /* the main loop calls timer_event() at this icnt */
  uint64_t next_event_ns = ~0ULL;      /* ... the time of that event */
  uint64_t time_bias_ns = 0;           /* time skipped while the CPU was halted */
  /* an RTL co-simulation's clock (the kodiak testbench): when set, time is
   * clock_ns(clock_ctx) + time_bias_ns, not the instruction count, so the C++
   * timers count the RTL's cycles; next_event_ns says when timer_event is due */
  uint64_t (*clock_ns)(void *ctx) = nullptr;
  void *clock_ctx = nullptr;
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
    return (clock_ns != nullptr) ? now_ns(s) : now_ns(s) + (1ULL << ns_shift);
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
  /* the ESP (esp.cc): qemu hw/scsi/esp.c, function for function */
  void esp_raise_irq();
  void esp_lower_irq();
  void esp_dma_enable(bool level);
  void esp_hard_reset();
  void esp_soft_reset();
  void esp_bus_reset();
  void iommu_dma(const char *who, uint32_t dvma, uint8_t *buf, uint32_t len, bool to_mem);
  void esp_dma_mem(uint8_t *buf, uint32_t len, bool to_mem);
  void lance_reset();
  uint16_t lance_read(uint32_t reg);
  void lance_write(uint32_t reg, uint16_t v);
  uint16_t lance_rd16(uint32_t addr);
  void lance_wr16(uint32_t addr, uint16_t v);
  void lance_update_irq();
  void lance_init();
  void lance_transmit();
  uint32_t esp_get_tc() const;
  void esp_set_tc(uint32_t v);
  int esp_select();
  int32_t esp_get_cmd(uint32_t maxlen);
  void esp_do_command_phase();
  void esp_do_message_phase();
  void esp_do_cmd();
  void esp_handle_satn();
  void esp_handle_s_without_atn();
  void esp_handle_satn_stop();
  void esp_write_response();
  void esp_dma_done();
  void esp_do_dma();
  void esp_do_nodma();
  void esp_req_cancel();
  void esp_req_continue();
  void esp_command_complete();
  void esp_transfer_data(uint32_t len);
  void esp_handle_ti();
  uint8_t esp_read(uint32_t reg);
  void esp_write(uint32_t reg, uint8_t v);
  void ctr_schedule(const state_t *s);
  bool ctr_is_user(uint32_t idx) const {
    return idx != 0 and ((ctr_user_mode >> (idx - 1)) & 1);
  }
};

#endif
