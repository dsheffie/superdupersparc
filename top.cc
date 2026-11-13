#include "top.hh"
#include <cstring>
#include <deque>
#include "sun4m.hh"
#include "ckpt.hh"

/* SPARC V8 Verilator testbench.  s = the architectural state the RTL's retire
 * stream writes back (and the memory image the RTL's memory port serves); ss =
 * the checker ISS (interpret.cc), stepped once per retired instruction.
 *
 * Devices: with --checkpoint (an ss10sim full-system checkpoint) the memory
 * port serves RAM below ram_size and the sun4m devices (sun4m.cc, the same code
 * ss10sim runs) above it.  The device side effects happen once: an RTL device
 * load reads the board and its value is queued for the checker's replay (the
 * RTL issues uncached loads only at the ROB head, so the queue is in retire
 * order); a device store is performed when the checker retires it, and the
 * RTL's later write is only compared against it.  Time is the retired
 * instruction count (ss->icnt), as in ss10sim, so a run follows the same
 * device timeline the checkpoint did.  The board's interrupt level drives the
 * core's irl; the checker takes an interrupt where the RTL reports it took one. */

bool globals::enClockFuncts = false;
uint64_t globals::cycle = 0;
bool globals::trace_retirement = false;
bool globals::trace_fp = false;
bool globals::report_syscalls = false;

static state_t *s = nullptr;
static state_t *ss = nullptr;

/* l2.sv's `ifdef VERILATOR` L2DBG descriptor-line tracer DPI probes are only
 * implemented in the henry full-system tb (henry_tb.cpp).  ooo_core does no L2
 * tracing, so give it no-op defs to satisfy the link. */
extern "C" void l2_line_log(int, unsigned long long, unsigned long long,
                            unsigned long long, int, int) {}
extern "C" void l2_chk_log(unsigned long long, int, int, int, int,
                           unsigned long long, unsigned long long) {}

/* Checkpoint-resume DPI seed hooks: at reset the RTL takes its integer
 * registers (rf4r2w), PSR/WIM/TBR (core.sv), icc, Y and the FSR (exec.sv), the
 * FP registers (fp_regfile) and SRMMU registers (mmu_preload) from the restored
 * checker state.  The FQ and the MMU fault registers start at their reset
 * values on both sides. */
static state_t *g_ckpt_state = nullptr;
extern "C" {
  int       have_checkpoint(void)               { return g_ckpt_state != nullptr; }
  int       have_ckpt_t(void)                   { return 0; }
  /* exec.sv's backing RF of the window registers: flat arch register regid */
  long long loadgpr(int regid) {
    if(g_ckpt_state == nullptr or regid < 0 or regid >= N_ARCH_REGS) {
      return 0;
    }
    return static_cast<long long>(g_ckpt_state->r[regid]);
  }
  /* fp_regfile's reset identity map holds the SPARC pairs at the even arch
   * entries (decode_sparc.sv fidx): f[2k] the high word, f[2k+1] the low */
  long long loadfpr(int regid) {
    if(g_ckpt_state == nullptr or (regid & 1) or regid >= 32) {
      return 0;
    }
    return static_cast<long long>((static_cast<uint64_t>(g_ckpt_state->f[regid]) << 32) | g_ckpt_state->f[regid + 1]);
  }
  /* physical register preg under core.sv's reset_preg map: only the globals
   * (arch 1..7 -> p1..p7) are mapped; the window registers start in the
   * backing RF (loadgpr) */
  long long loadprf(int preg, int depth) {
    (void)depth;
    if(g_ckpt_state == nullptr or preg < 1 or preg >= 8) {
      return 0;
    }
    return static_cast<long long>(g_ckpt_state->r[preg]);
  }
  int ckpt_sreg(int id) {
    if(g_ckpt_state == nullptr) {
      return 0;
    }
    switch(id)
      {
      case 0: return static_cast<int>(g_ckpt_state->get_psr());
      case 1: return static_cast<int>(g_ckpt_state->wim);
      case 2: return static_cast<int>(g_ckpt_state->tbr);
      case 3: return (g_ckpt_state->icc_n << 3) | (g_ckpt_state->icc_z << 2) | (g_ckpt_state->icc_v << 1) | g_ckpt_state->icc_c;
      case 4: return static_cast<int>(g_ckpt_state->y);
      case 5: return static_cast<int>(g_ckpt_state->fsr);
      default: return 0;
      }
  }
}

/* core.sv rtl_sregs: the RTL's committed PSR fields (the V8 layout: EF bit 12,
 * PIL 11:8, S 7, PS 6, ET 5, CWP 4:0) and WIM after its last retire cycle */
static uint32_t g_rtl_psr = 0, g_rtl_wim = 0;
static bool g_rtl_sregs_valid = false;
extern "C" void rtl_sregs(int psr, int wim) {
  g_rtl_psr = static_cast<uint32_t>(psr);
  g_rtl_wim = static_cast<uint32_t>(wim);
  g_rtl_sregs_valid = true;
}

/* tlb.sv tlb_fill: an RTL TLB fill, checked against the ISS walking the same VA
 * and context in its memory (which holds every retired store, as the RTL's
 * walker sees memory).  A difference is reported, not fatal: the first ones
 * localize a stale or mis-tagged translation. */
static uint64_t g_tlb_fills = 0, g_tlb_fill_bad = 0;
extern "C" void tlb_fill(int id, int va, int ctx, int ppn, int level, int c, int acc) {
  ++g_tlb_fills;
  if(ss == nullptr or not (ss->mmu_ctrl & MCR_E)) {
    return;
  }
  const uint32_t save_ctx = ss->mmu_ctx;
  ss->mmu_ctx = static_cast<uint32_t>(ctx);
  uint32_t pte = 0, lvl = 0;
  uint64_t pa = 0;
  const bool ok = debug_walk(ss, static_cast<uint32_t>(va), &pte, &lvl, &pa);
  ss->mmu_ctx = save_ctx;
  const uint32_t iss_ppn = (pte >> 8) & 0xffffff, iss_c = (pte >> 7) & 1, iss_acc = (pte >> 2) & 7;
  if(not ok or iss_ppn != static_cast<uint32_t>(ppn) or lvl != static_cast<uint32_t>(level) or
     iss_c != static_cast<uint32_t>(c) or iss_acc != static_cast<uint32_t>(acc)) {
    if(++g_tlb_fill_bad <= 10) {
      std::cout << "TLB FILL MISMATCH (" << (id ? "itlb" : "dtlb") << ") cycle " << globals::cycle
		<< " retired icnt " << ss->icnt << std::hex << ": va " << static_cast<uint32_t>(va)
		<< " ctx " << ctx << " rtl ppn " << ppn << " level " << level << " c " << c << " acc " << acc
		<< " | iss " << (ok ? "" : "(walk faults) ") << "ppn " << iss_ppn << " level " << lvl
		<< " c " << iss_c << " acc " << iss_acc << " (iss ctx now " << save_ctx << ")" << std::dec << "\n";
    }
  }
}

/* inbound DMA coherence: a device's DMA write to RAM (sun4m_t::dma_hook) does
 * not reach the RTL's memory image at once.  It queues per 16-byte line; each
 * line is snooped out of the RTL's caches (l2.sv snoop_req, WBINV: any dirty
 * copy written back, both levels invalidated -- as the MBus would) and only
 * then are the DMA bytes written into the image, so a partly-DMA'd line keeps
 * the CPU's dirty bytes and the DMA's win.  Until a line's snoop is done the
 * RTL can read the old data, the race a real coherent bus has too. */
struct dma_line_t {
  uint64_t line;
  uint8_t data[16];
  uint16_t mask;
};
static std::deque<dma_line_t> g_dma_lines;
static sun4m_t *g_board = nullptr;
static bool g_snoop_req = false, g_snoop_busy = false;
static uint64_t g_snoops = 0;
/* sun4m_t::dma_busy: a device's DMA is complete (its interrupt, which a driver
 * may also poll for) only once all its lines have landed -- else a process woken
 * by a disk read reads the page's old bytes (a Solaris CD boot: 6K lines still
 * queued when ld.so read a paged-in page) */
static bool rtl_dma_busy(void *ctx) {
  (void)ctx;
  return not g_dma_lines.empty();
}
static void rtl_dma_hook(void *ctx, uint64_t pa, const uint8_t *buf, uint32_t len) {
  (void)ctx;
  for(uint32_t i = 0; i < len; ) {
    const uint64_t a = pa + i;
    dma_line_t l;
    l.line = a & ~15ULL;
    l.mask = 0;
    const uint32_t off = static_cast<uint32_t>(a & 15);
    const uint32_t n = std::min<uint32_t>(16 - off, len - i);
    for(uint32_t k = 0; k < n; k++) {
      l.data[off + k] = buf[i + k];
      l.mask |= static_cast<uint16_t>(1u << (off + k));
    }
    g_dma_lines.push_back(l);
    i += n;
  }
}
/* before the clock edge: offer the next line's snoop */
template <typename T> static void snoop_drive(T *tb) {
  if(not g_snoop_req and not g_snoop_busy and not g_dma_lines.empty()) {
    tb->snoop_req_valid = 1;
    tb->snoop_req_addr = g_dma_lines.front().line;
    tb->snoop_req_wbinv = 1;
    g_snoop_req = true;
  }
}
/* after the clock edge: the L2 took it / finished it (then the bytes land) */
template <typename T> static void snoop_sample(T *tb) {
  if(g_snoop_req and tb->snoop_req_ack) {
    tb->snoop_req_valid = 0;
    g_snoop_req = false;
    g_snoop_busy = true;
  }
  if(g_snoop_busy and tb->snoop_done) {
    const dma_line_t &l = g_dma_lines.front();
    for(uint32_t k = 0; k < 16; k++) {
      if((l.mask >> k) & 1) {
	s->mem.set<uint8_t>(l.line + k, l.data[k]);
      }
    }
    g_dma_lines.pop_front();
    g_snoop_busy = false;
    ++g_snoops;
    if(g_dma_lines.empty() and g_board != nullptr) {
      g_board->dma_drained();
    }
  }
}

/* ---------------------------------------------------------------- devices */

static bool g_dev_error = false;

/* reads the PROM serves have no side effects: both sides read it directly */
static bool dev_plain(uint64_t pa) {
  return pa >= SUN4M_PROM_BASE and pa < SUN4M_PROM_BASE + SUN4M_PROM_SIZE;
}

struct dev_rec_t {
  uint64_t pa;
  uint32_t size, v;
  bool bus_error;
};

/* the checker's device space: loads replay what the RTL read, stores happen
 * here (at retirement, as in ss10sim) and wait for the RTL's to compare */
class replay_dev : public dev_if {
public:
  std::deque<dev_rec_t> reads, writes;
  uint32_t read(state_t *st, uint64_t pa, uint32_t size, bool *bus_error) override {
    if(dev_plain(pa)) {
      return g_board->read(st, pa, size, bus_error);
    }
    if(reads.empty() or reads.front().pa != pa or reads.front().size != size) {
      std::cout << "DEVICE DESYNC: the checker loads " << size << " bytes at pa " << std::hex << pa
		<< " (pc " << st->pc << ") but the RTL read ";
      if(reads.empty()) {
	std::cout << "nothing";
      }
      else {
	std::cout << reads.front().size << " bytes at pa " << reads.front().pa;
      }
      std::cout << std::dec << "\n";
      g_dev_error = true;
      return 0;
    }
    dev_rec_t r = reads.front();
    reads.pop_front();
    *bus_error = r.bus_error;
    return r.v;
  }
  void write(state_t *st, uint64_t pa, uint32_t size, uint32_t v, bool *bus_error) override {
    g_board->write(st, pa, size, v, bus_error);
    writes.push_back(dev_rec_t{pa, size, v, *bus_error});
  }
};
static replay_dev g_replay;

/* one RTL access to device space (size 1, 2 or 4), at the board's current time */
static uint32_t rtl_dev_read(uint64_t pa, uint32_t size, bool *bus_error) {
  if(ss->icnt >= g_board->next_event_icnt) {
    g_board->timer_event(ss);
  }
  uint32_t v = g_board->read(ss, pa, size, bus_error);
  if(not dev_plain(pa)) {
    g_replay.reads.push_back(dev_rec_t{pa, size, v, *bus_error});
  }
  return v;
}

static void rtl_dev_write(uint64_t pa, uint32_t size, uint32_t v) {
  if(g_replay.writes.empty()) {
    std::cout << "DEVICE DESYNC: the RTL writes " << size << " bytes = " << std::hex << v << " at pa " << pa
	      << " that the checker never stored" << std::dec << "\n";
    g_dev_error = true;
    return;
  }
  dev_rec_t w = g_replay.writes.front();
  g_replay.writes.pop_front();
  if(w.pa != pa or w.size != size or w.v != v) {
    std::cout << "DEVICE DESYNC: the RTL writes " << size << " bytes = " << std::hex << v << " at pa " << pa
	      << ", the checker stored " << std::dec << w.size << " bytes = " << std::hex << w.v
	      << " at pa " << w.pa << std::dec << "\n";
    g_dev_error = true;
  }
}

/* the memory port's 16-byte line + byte mask to device accesses: each run of
 * enabled bytes is one access (an 8-byte run is two words, high then low, as
 * the checker's ldd/std make them).  data[i] holds bytes line+4i.. in host
 * order of the big-endian image (perform_word_load's layout). */
static void dev_line_access(bool store, uint64_t line, uint16_t mask, uint32_t data[4], bool *bus_error) {
  uint8_t bytes[16];
  for(int i = 0; i < 16; i++) {
    bytes[i] = static_cast<uint8_t>(data[i / 4] >> (8 * (i % 4)));
  }
  int k = 0;
  while(k < 16) {
    if(not ((mask >> k) & 1)) {
      ++k;
      continue;
    }
    int e = k;
    while(e < 16 and ((mask >> e) & 1)) {
      ++e;
    }
    for(int a = k; a < e; ) {
      uint32_t size = static_cast<uint32_t>(std::min(e - a, 4));
      if(size == 3) {
	size = 2;
      }
      uint64_t pa = line + a;
      if(store) {
	uint32_t v = 0;
	for(uint32_t b = 0; b < size; b++) {
	  v = (v << 8) | bytes[a + b];
	}
	rtl_dev_write(pa, size, v);
      }
      else {
	bool be = false;
	uint32_t v = rtl_dev_read(pa, size, &be);
	*bus_error |= be;
	for(uint32_t b = 0; b < size; b++) {
	  bytes[a + b] = static_cast<uint8_t>(v >> (8 * (size - 1 - b)));
	}
      }
      a += size;
    }
    k = e;
  }
  if(not store) {
    for(int i = 0; i < 4; i++) {
      data[i] = 0;
      for(int j = 0; j < 4; j++) {
	data[i] |= static_cast<uint32_t>(bytes[4 * i + j]) << (8 * j);
      }
    }
  }
}

/* SRMMU registers at reset (--mmu-ctrl/--mmu-ctpr/--mmu-ctx), until lda/sta to
 * ASI 0x4 reach the RTL's MMU: mmu.sv reads them at reset and the checker ISS
 * starts with the same values. */
static uint32_t g_mmu_preload[3] = {0x800 /* MCR_RESET: MBus mode */, 0, 0};
extern "C" int mmu_preload(int regid) {
  return static_cast<int>(g_mmu_preload[regid]);
}
/* the walker set R in a PTE, possibly for a wrong-path access the ISS never
 * makes: mirror it into the checker's memory so the halt-time compare agrees.
 * (The R bit is bit 5 of the big-endian word: the byte at pte_pa + 3.) */
extern "C" void mmu_set_ref(long long pte_pa, int pte) {
  (void)pte;
  uint64_t a = static_cast<uint64_t>(pte_pa) + 3;
  ss->mem.set<uint8_t>(a, ss->mem.get<uint8_t>(a) | 0x20);
}

/* the FP register compare: the RTL's architectural FP state is its FP retire RAT
 * (even arch entries: SPARC pairs, decode_sparc.sv fidx) over its FP PRF, both
 * mirrored here as they are written (fp_regfile.sv / core.sv); the PRF and the
 * retire RAT start as the reset seed (identity; zero, or the checkpoint's FP
 * registers -- loadfpr -- which main copies in here) */
static uint64_t g_rtl_fp_prf[1024] = {0};
static uint32_t g_rtl_fp_rrat[32] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
				    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31};
extern "C" void fp_prf_wr(int ptr, long long data) {
  g_rtl_fp_prf[ptr & 1023] = static_cast<uint64_t>(data);
}
extern "C" void fp_rrat_wr(int arch, int preg) {
  g_rtl_fp_rrat[arch & 31] = static_cast<uint32_t>(preg);
}
static uint64_t rtl_fp_pair(uint32_t k) {
  return g_rtl_fp_prf[g_rtl_fp_rrat[2 * k] & 1023];
}

/* the store check (r9999's, from rv64core): l1d.sv reports each store it writes
 * into the L1D array (wr_log, ENABLE_STORE_CHECK), the ISS each store it writes
 * into cacheable RAM (interpret.cc STORE_CHECK); both are program order, so the
 * first front-to-front mismatch is the root store -- a lost, extra or wrong
 * store, caught where it happens rather than when something reads it back */
#ifdef STORE_CHECK
std::deque<store_rec> g_iss_stores;
bool g_store_check = false;
static std::deque<store_rec> g_rtl_stores;
static bool g_store_diverged = false;
static uint64_t g_stores_checked = 0;
#endif
extern "C" void wr_log(long long pc, int rob_ptr, unsigned long long addr,
		       unsigned long long data, int is_atomic) {
  (void)rob_ptr;
  (void)is_atomic;
#ifdef STORE_CHECK
  if(g_store_check) {
    g_rtl_stores.emplace_back(static_cast<uint64_t>(pc), addr, data);
  }
#else
  (void)pc;
  (void)addr;
  (void)data;
#endif
}
#ifdef STORE_CHECK
static void drain_store_check() {
  while(not g_iss_stores.empty() and not g_rtl_stores.empty()) {
    const store_rec &i = g_iss_stores.front(), &r = g_rtl_stores.front();
    if((static_cast<uint32_t>(i.pc) != static_cast<uint32_t>(r.pc)) or (i.addr != r.addr) or (i.data != r.data)) {
      fprintf(stderr, "[STORE-CHECK] ROOT STORE DIVERGENCE at cycle %llu (%llu stores matched)\n"
	      "  ISS pc=%08x addr=%09llx data=%016llx\n"
	      "  RTL pc=%08x addr=%09llx data=%016llx\n",
	      static_cast<unsigned long long>(globals::cycle), static_cast<unsigned long long>(g_stores_checked),
	      static_cast<uint32_t>(i.pc), static_cast<unsigned long long>(i.addr), static_cast<unsigned long long>(i.data),
	      static_cast<uint32_t>(r.pc), static_cast<unsigned long long>(r.addr), static_cast<unsigned long long>(r.data));
      fprintf(stderr, "  [queues] ISS depth=%zu RTL depth=%zu\n", g_iss_stores.size(), g_rtl_stores.size());
      for(size_t k = 0; (k < 8) and (k < g_iss_stores.size()); k++) {
	fprintf(stderr, "    ISS[%zu] pc=%08x addr=%09llx data=%016llx\n", k, static_cast<uint32_t>(g_iss_stores[k].pc),
		static_cast<unsigned long long>(g_iss_stores[k].addr), static_cast<unsigned long long>(g_iss_stores[k].data));
      }
      for(size_t k = 0; (k < 8) and (k < g_rtl_stores.size()); k++) {
	fprintf(stderr, "    RTL[%zu] pc=%08x addr=%09llx data=%016llx\n", k, static_cast<uint32_t>(g_rtl_stores[k].pc),
		static_cast<unsigned long long>(g_rtl_stores[k].addr), static_cast<unsigned long long>(g_rtl_stores[k].data));
      }
      g_store_diverged = true;
      return;
    }
    g_iss_stores.pop_front();
    g_rtl_stores.pop_front();
    g_stores_checked++;
  }
}
#endif
extern "C" void l1d_wb_log(unsigned long long, unsigned long long, unsigned long long) {
}
extern "C" void rd_log(long long, unsigned long long, unsigned long long, int) {
}
extern "C" void l1d_fill(unsigned long long, long long, unsigned long long, unsigned long long,
			 unsigned long long) {
}
extern "C" void l1d_cacheop(unsigned long long, long long, unsigned long long, int) {
}
extern "C" void dirtydrop(unsigned long long cycle, long long pc, unsigned long long pa, int by_refill) {
  static uint64_t n = 0;
  if(n++ < 64) {
    fprintf(stderr, "[dirtydrop] cyc=%llu pc=%08x pa=%09llx store's dirty bit lost to %s\n",
	    cycle, (uint32_t)pc, pa, by_refill ? "a refill" : "an invalidate");
  }
}

static uint64_t insns_retired = 0;
static uint64_t pipestart = 0, pipeend = ~(0UL);
static pipeline_logger *pl = nullptr;
/* the instruction word at a pc for the pipeline log and the TIP report: through the
 * checker ISS's MMU state (ss), since the RTL-side image is physical and a VA read
 * there gives garbage once the MMU is on; the physical read when that fails */
static uint32_t insn_at(uint32_t pc, const state_t *s) {
  uint32_t iw = 0;
  if(ss != nullptr and debug_fetch(ss, pc, &iw)) {
    return iw;
  }
  return get_insn(pc, s);
}
static uint64_t l1d_misses = 0, l1d_insns = 0;
static uint64_t last_retire_cycle = 0, last_retire_pc  = 0;

static std::map<uint64_t, uint64_t> retire_map;

static uint64_t n_fetch[5] = {0};
static uint64_t n_resteer_bubble = 0;
static uint64_t n_fq_full = 0;

static uint64_t n_uq_full[3] = {0};
static uint64_t n_alloc[3] = {0};
static uint64_t n_rdy[3] = {0};

static uint64_t n_int_exec[2] = {0};
static uint64_t n_mem_exec[3] = {0};

static uint64_t q_full[3] = {0};
static uint64_t dq_empty =  0;
static uint64_t uq_full = 0;
static uint64_t n_active = 0;
static uint64_t rob_full = 0;

static uint64_t l1d_reqs = 0;
static uint64_t l1d_acks = 0;
static uint64_t l1d_stores = 0;

static std::map<int,uint64_t> block_distribution;
static std::map<int,uint64_t> restart_distribution;
static std::map<int,uint64_t> restart_ds_distribution;
static std::map<int,uint64_t> fault_distribution;
static std::map<int,uint64_t> branch_distribution;
static std::map<int,uint64_t> fault_to_restart_distribution;

static const char* l1d_stall_str[8] =
  {
   "no stall", //0
   "got miss", //1 
   "full memory queue", //2
   "not possible", //3
   "load retry", //4
   "store to same set", //5
   "cm block stall", //6
   "inflight rob ptr", //7
};
static uint64_t l1d_stall_reasons[8] = {0};

static bool pending_fault = false;
static uint64_t fault_start_cycle = 0;

void record_branches(int n_branches) {
  branch_distribution[n_branches]++;
}

// timer-IRQ trace DPI: only henry_tb records it (for its monitor `timer` query);
// ooo_core just needs the symbol, so this is a no-op here.
void log_timer_irq(void) {}

void record_faults(int n_faults) {
  fault_distribution[n_faults]++;
  if(n_faults && not(pending_fault)) {
    pending_fault = true;
    fault_start_cycle = globals::cycle;
  }
}

void record_restart(int cycles) {
  restart_distribution[cycles]++;
  pending_fault = false;

  fault_to_restart_distribution[(globals::cycle - fault_start_cycle)]++;
  fault_start_cycle = 0;
  //std::cout << "clearing fault took "
  //<< (globals::cycle - fault_start_cycle)
  //<< " cycles\n";
}

void record_ds_restart(int cycles) {
  restart_ds_distribution[cycles]++;
}


void record_l1d(int req, int ack, int ack_st, int blocked, int stall_reason) {
  l1d_reqs += req;
  l1d_acks += ack;
  l1d_stores += ack_st;
  block_distribution[__builtin_popcount(blocked)]++;
  l1d_stall_reasons[stall_reason&15]++;
}

static std::map<int, uint64_t> int_sched_rdy_map;

void report_exec(int int_valid, int int_ready,
		 int mem_valid, int mem_ready,
		 int fp_valid,  int fp_ready,
		 int intq_full, int memq_full,
		 int fpq_full,
		 int blocked_by_store,
		 int ready_int) {
  n_int_exec[0] += int_valid;
  n_int_exec[1] += int_ready;
  n_mem_exec[0] += mem_valid;
  n_mem_exec[1] += mem_ready;
  n_mem_exec[2] += blocked_by_store;
    
  q_full[0] += intq_full;
  q_full[1] += memq_full;
  q_full[2] += fpq_full;
  
  int_sched_rdy_map[__builtin_popcount(ready_int)]++;
}


void record_alloc(int rf,
		  int a1, int a2, int de,
		  int f1, int f2,
		  int r1, int r2, int active) {

  rob_full += rf;
  dq_empty += de;
  uq_full += f1;
  n_active += active;
  
  if(a2)
    ++n_alloc[2];
  else if(a1)
    ++n_alloc[1];
  else
    ++n_alloc[0];

  if(f2)
    ++n_uq_full[2];
  else if(f1)
    ++n_uq_full[1];
  else
    ++n_uq_full[0];
  
  if(r2)
    ++n_rdy[2];
  else if(r1)
    ++n_rdy[1];
  else
    ++n_rdy[0];
  
}


void record_fetch(int p1, int p2, int p3, int p4, 
		  long long pc1, long long pc2, long long pc3, long long pc4,
		  int bubble, int fq_full) {
  n_resteer_bubble += bubble;
  n_fq_full += fq_full;


  if(p1)
    ++n_fetch[1];
  else if(p2)
    ++n_fetch[2];
  else if(p3)
    ++n_fetch[3];
  else if(p4)
    ++n_fetch[4];
  else
    ++n_fetch[0];
}

static std::map<int, uint64_t> mem_lat_map, fp_lat_map, non_mem_lat_map;

int check_insn_bytes(long long pc, int data) {
  uint32_t insn = get_insn(pc, s);
  return (*reinterpret_cast<uint32_t*>(&data)) == insn;
}

static long long lrc = -1;
static uint64_t record_insns_retired = 0;

/* TOP-DOWN accounting (core.sv `ifdef TOPDOWN, --topdown).  core.sv reports, every
 * cycle, the state, how many uops the decode queue offered (0/1/2), how many
 * allocated and retired, and why an offered slot did not allocate.  Accumulated
 * only inside the --pipestart/--pipeend retired-insn window. */
namespace topdown {
  static bool enabled = false;
  static uint64_t cycles = 0, retired = 0, allocated = 0;
  static uint64_t fe_lat = 0, fe_bw = 0;        /* 0 offered / 1 offered (slots) */
  static uint64_t be[8] = {0};                  /* offered-not-allocated slots by reason */
  static uint64_t state_cyc[32] = {0};          /* cycles by core state */
}
extern "C" void topdown_cycle(int st, int avail, int nalloc, int nret, int be0, int be1) {
  if(!topdown::enabled || record_insns_retired < pipestart || record_insns_retired >= pipeend) {
    return;
  }
  topdown::cycles++;
  topdown::retired += nret;
  topdown::allocated += nalloc;
  topdown::state_cyc[st & 31]++;
  if(st == 2) {                                 /* ACTIVE: classify the 2 slots */
    if(avail == 0) {
      topdown::fe_lat += 2;
    }
    else if(avail == 1) {
      topdown::fe_bw += 1;
    }
    if(be0) {
      topdown::be[be0 & 7] += avail;            /* nothing allocated: every offered slot */
    }
    if(be1) {
      topdown::be[be1 & 7] += 1;
    }
  }
}
/* fetch groups (l1i.sv TOPDOWN): insns pushed into the fetch queue per cycle,
 * why the group ended, and fetch queue occupancy */
namespace topdown {
  static uint64_t f_cyc = 0, f_insns = 0;
  static uint64_t f_why_cyc[16] = {0}, f_why_insns[16] = {0};
  static uint64_t f_npush[8] = {0}, f_fqcnt[64] = {0};
}
extern "C" void topdown_fetch(int npush, int why, int fq_cnt) {
  if(!topdown::enabled || record_insns_retired < pipestart || record_insns_retired >= pipeend) {
    return;
  }
  topdown::f_cyc++;
  topdown::f_insns += npush;
  topdown::f_why_cyc[why & 15]++;
  topdown::f_why_insns[why & 15] += npush;
  topdown::f_npush[npush & 7]++;
  topdown::f_fqcnt[fq_cnt & 63]++;
}
/* per-uop stage stamps (core.sv / exec.sv TOPDOWN), keyed by rob index.  All in
 * globals::cycle; the ROB's completion stamp is on the core's own r_cycle and is
 * converted with the offset measured at retirement. */
namespace topdown {
  struct stamp_t { uint64_t a = 0, q = 0, i = 0, m = 0; };
  static stamp_t slot[64];
  /* per class (0 alu, 1 branch, 2 load, 3 store): n, and sums of alloc->sched,
   * sched->issue, issue->complete, alloc->complete, complete->retire */
  static uint64_t cls_n[4] = {0};
  static double cls_seg[4][5] = {{0}};
  static uint64_t cls_min[4][5];
  static bool min_init = false;
}
extern "C" void topdown_uop(int ev, int rob_ptr) {
  if(!topdown::enabled) {
    return;
  }
  topdown::stamp_t &e = topdown::slot[rob_ptr & 63];
  const uint64_t c = globals::cycle;
  switch(ev)
    {
    case 0: e = topdown::stamp_t(); e.a = c; break;   /* allocation: a fresh entry */
    case 1: e.q = c; break;                           /* enters the ALU scheduler */
    case 2: e.i = c; break;                           /* ALU execute starts */
    case 3: e.m = c; break;                           /* memory uop to address gen */
    default: break;
    }
}
extern "C" void topdown_retire_uop(int rob_ptr, long long alloc_c, long long complete_c,
                                   long long retire_c, int is_br, int is_store) {
  using namespace topdown;
  if(!enabled || record_insns_retired < pipestart || record_insns_retired >= pipeend) {
    return;
  }
  if(!min_init) {
    for(auto &r : cls_min) { for(auto &x : r) { x = ~0ull; } }
    min_init = true;
  }
  const stamp_t &e = slot[rob_ptr & 63];
  const long long off = (long long)globals::cycle - retire_c;     /* core r_cycle -> globals::cycle */
  const uint64_t c = (uint64_t)(complete_c + off), r = globals::cycle;
  if(e.a == 0 || c < e.a) {
    return;                                        /* no allocation stamp (window edge) */
  }
  int k;
  uint64_t start;                                  /* when it left the queue for execution */
  if(e.m) {
    k = is_store ? 3 : 2;
    start = e.m;
  }
  else if(e.i) {
    k = is_br ? 1 : 0;
    start = e.i;
  }
  else {
    return;                                        /* nop / never issued: skip */
  }
  const uint64_t q = e.m ? e.m : (e.q ? e.q : start);
  const uint64_t seg[5] = {q - e.a, start - q, c - start, c - e.a, r - c};
  cls_n[k]++;
  for(int j = 0; j < 5; j++) {
    cls_seg[k][j] += seg[j];
    cls_min[k][j] = std::min(cls_min[k][j], seg[j]);
  }
}
static void topdown_report() {
  using namespace topdown;
  static const char *st_name[16] = {"FLUSH_FOR_HALT","HALT","ACTIVE","DRAIN","RAT","DELAY_SLOT",
    "ALLOC_FOR_SERIALIZE","HALT_WAIT_FOR_RESTART","WAIT_FOR_SERIALIZE_AND_RESTART","ARCH_FAULT",
    "WRITE_EPC","EXCEPTION_DRAIN","SERIALIZE_IN_FAULTED_DELAY_SLOT",
    "WAIT_FOR_SERIALIZE_IN_FAULTED_DELAY_SLOT","CACHE_FLUSH","DEAD"};
  static const char *be_name[8] = {"-","ROB full","uop queue full","free list short",
    "oldest-first pending","pending fault","other","pairing rule"};
  const double slots = 2.0 * cycles;
  if(cycles == 0) {
    std::cout << "topdown: no cycles in window\n";
    return;
  }
  /* non-ACTIVE cycles: recovery after a mispredict/exception = bad speculation,
   * serialization = backend */
  uint64_t recov = 0, serial = 0;
  for(int i = 0; i < 16; i++) {
    if(i == 3 || i == 4 || i == 5 || i == 9 || i == 10 || i == 11 || i == 12 || i == 13) {
      recov += state_cyc[i];
    }
    else if(i != 2) {
      serial += state_cyc[i];
    }
  }
  uint64_t be_sum = 0;
  for(int i = 1; i < 8; i++) {
    be_sum += be[i];
  }
  const double squashed = (allocated > retired) ? (double)(allocated - retired) : 0.0;
  const double t_ret = retired / slots, t_bad = (squashed + 2.0 * recov) / slots;
  const double t_fe = (fe_lat + fe_bw) / slots, t_be = (be_sum + 2.0 * serial) / slots;
  std::cout << "==== TOP-DOWN (retired-insn window " << pipestart << ".." << pipeend
            << ", " << cycles << " cycles, " << (uint64_t)slots << " slots, IPC "
            << (double)retired / cycles << ") ====\n";
  printf("  retiring        %5.1f%%\n", 100 * t_ret);
  printf("  bad speculation %5.1f%%   (squashed uops %.0f + recovery %lu cyc)\n", 100 * t_bad, squashed, (unsigned long)recov);
  printf("  frontend bound  %5.1f%%   (latency: nothing offered %5.1f%%, bandwidth: 1 of 2 offered %5.1f%%)\n",
         100 * t_fe, 100 * fe_lat / slots, 100 * fe_bw / slots);
  printf("  backend bound   %5.1f%%   (serializing states %lu cyc)\n", 100 * t_be, (unsigned long)serial);
  for(int i = 1; i < 8; i++) {
    if(be[i]) {
      printf("      %-22s %5.1f%%\n", be_name[i], 100 * be[i] / slots);
    }
  }
  static const char *cls_name[4] = {"alu", "branch", "load", "store"};
  printf("  stage latency, mean (min) cycles:   alloc->sched   sched->issue   issue->complete   alloc->complete   complete->retire\n");
  for(int k = 0; k < 4; k++) {
    if(cls_n[k] == 0) {
      continue;
    }
    printf("    %-7s n=%-6lu", cls_name[k], (unsigned long)cls_n[k]);
    for(int j = 0; j < 5; j++) {
      printf("   %6.2f (%2lu)", cls_seg[k][j] / cls_n[k], (unsigned long)cls_min[k][j]);
    }
    printf("\n");
  }
  printf("    (memory ops: 'sched' = dispatch from the memory uop queue to address generation)\n");
  printf("  (sum %.1f%%)  cycles by state:", 100 * (t_ret + t_bad + t_fe + t_be));
  for(int i = 0; i < 16; i++) {
    if(state_cyc[i]) {
      printf(" %s=%lu", st_name[i], (unsigned long)state_cyc[i]);
    }
  }
  printf("\n");
  if(f_cyc) {
    static const char *why_name[10] = {"full group of 4","cut at 16B line end","cut before taken cflow",
      "cflow insn alone","delay slot alone","fetch queue full","resteer bubble","miss/tlb/other state",
      "restart/flush","group + taken br + ds"};
    printf("  fetch: %.3f insns/cycle over %lu cycles; group size hist:", (double)f_insns / f_cyc,
           (unsigned long)f_cyc);
    for(int i = 0; i <= 4; i++) {
      printf(" %d=%.1f%%", i, 100.0 * f_npush[i] / f_cyc);
    }
    printf("\n    why the group ended      %%cycles   insns/group\n");
    for(int i = 0; i < 10; i++) {
      if(f_why_cyc[i]) {
        printf("    %-24s %6.1f%%   %.2f\n", why_name[i], 100.0 * f_why_cyc[i] / f_cyc,
               (double)f_why_insns[i] / f_why_cyc[i]);
      }
    }
    double occ = 0;
    printf("    fetch queue occupancy:");
    for(int i = 0; i < 64; i++) {
      occ += (double)i * f_fqcnt[i];
      if(f_fqcnt[i]) {
        printf(" %d=%.1f%%", i, 100.0 * f_fqcnt[i] / f_cyc);
      }
    }
    printf("  (mean %.2f)\n", occ / f_cyc);
  }
}

/* pipetrace stage events (+define+PIPETRACE hooks in core/exec/l1d), keyed by rob
 * index: cleared at allocation, appended by the pipe, attached to the record
 * when pt_retire names the rob slot record_retirement is about to retire. */
namespace pt {
  static std::list<std::pair<uint64_t, char>> ev[64];
  static int cur = -1;
}
extern "C" void pt_alloc(int rob_ptr) {
  pt::ev[rob_ptr & 63].clear();
}
extern "C" void pt_event(int rob_ptr, int letter, long long cycle) {
  if(pl != nullptr) {
    pt::ev[rob_ptr & 63].emplace_back((uint64_t)cycle, (char)letter);
  }
}
extern "C" void pt_retire(int rob_ptr) {
  pt::cur = rob_ptr & 63;
}

void record_retirement(long long pc, long long fetch_cycle, long long alloc_cycle, long long complete_cycle, long long retire_cycle,
		       int faulted , int is_mem, int is_fp, int missed_l1d) {

  //if(pc == 0x2033c || pc == 0x20340 || pc == 0x20344 || pc == 0x20348) {
  //auto i = getAsmString(get_insn(pc, s), pc);
  //std::cout << std::hex << pc << std::dec << " " << i << " : " << alloc_cycle << "," << complete_cycle << "," << retire_cycle << "," << faulted << "\n";
  //}
  uint32_t insn = get_insn(pc, s);
  uint64_t delta = retire_cycle - last_retire_cycle;

  if(retire_cycle < lrc) {
    std::cout << "retirement cycle out-of-order\n";
    exit(-1);
  }
  lrc = retire_cycle;
  
  if(is_mem) {
    //auto i = getAsmString(insn, pc);
    //std::cout << std::hex << pc << std::dec << " " << i << " : " << alloc_cycle << ","
    //<< complete_cycle << "," << retire_cycle << "," << faulted << "\n";
    //std::cout << std::hex << pc << std::dec << " " << i << " : "
    mem_lat_map[(complete_cycle-alloc_cycle)]++;
    //<< (complete_cycle-alloc_cycle) << "\n";    
  }
  else if(is_fp) {
    fp_lat_map[(complete_cycle-alloc_cycle)]++;
  }
  else {
    non_mem_lat_map[(complete_cycle-alloc_cycle)]++;
  }
  //if(delta == 3) {
  //std::cout << "curr = " << std::hex << pc << std::dec << " : " << getAsmString(get_insn(pc, s), pc) << "\n";
  //std::cout << "last = " << std::hex << last_retire_pc << std::dec << " : " << getAsmString(get_insn(last_retire_pc, s), last_retire_pc) << "\n";
  //}
  //std::cout << "delta = " << delta << "\n";
  retire_map[delta]++;
  
  last_retire_cycle = retire_cycle;
  last_retire_pc = pc;
  
  if(missed_l1d) {
    //std::cout << "pc = " << std::hex << pc << " missed cache " << std::dec
    //<< " : " << getAsmString(get_insn(pc, s), pc)
    //<< "\n";
    ++l1d_misses;
  }
  l1d_insns += is_mem;
  
  if((pl != nullptr) and (record_insns_retired >= pipestart) and (record_insns_retired < pipeend)) {
    static const std::list<std::pair<uint64_t, char>> no_events;
    pl->append(record_insns_retired, getAsmString(insn_at(pc, s), pc), pc, fetch_cycle, alloc_cycle, complete_cycle, retire_cycle, faulted,
	       (pt::cur >= 0) ? pt::ev[pt::cur] : no_events);
  }
  pt::cur = -1;
  ++record_insns_retired;
}


/* the memory port presents a 16B line and a 16-bit byte mask; s->mem holds the
 * big-endian image, the port carries host-order words of it (as r9999 did) */
static uint32_t perform_word_load(state_t *s, uint32_t addr, uint16_t m) {
  uint32_t d = 0;
  uint32_t k = addr & 15;
  for(int j = 0; j < 4; j++) {
    if(((m >> k) & 1)) {
      uint32_t by = s->mem.get<uint8_t>(addr + j);
      d |= (by << (j*8));
    }
    k++;
  }
  return d;
}

static void perform_word_store(state_t *s, uint32_t addr, uint16_t m, uint32_t d) {
  uint32_t k = addr & 15;
  for(int j = 0; j < 4; j++) {
    if(((m >> k) & 1)) {
      s->mem.set<uint8_t>(addr + j, (d >> (8*j)) & 0xff);
    }
    k++;
  }
}

static inline void clock_tb(Vcore_l1d_l1i *tb) {
  tb->clk = 1;
  tb->eval();
  tb->clk = 0;
  tb->eval();
}

static void dump_regs(const state_t *st) {
  for(uint32_t i = 0; i < N_ARCH_REGS; i += 8) {
    std::cout << "r[" << std::dec << i << "]" << std::hex;
    for(uint32_t j = i; (j < (i + 8)) && (j < N_ARCH_REGS); j++) {
      std::cout << " " << st->r[j];
    }
    std::cout << std::dec << "\n";
  }
}

/* (as in ss10sim main.cc) --scsi-disk / --scsi-cdrom: "[ID:]image" targets on the ESP's bus; without an
 * ID the next free one from first_id up (the initiator, the ESP, is ID 7) */
static bool attach_scsi(sun4m_t *m, const std::vector<std::string> &specs, scsi_dev_t::type_t t,
			uint32_t first_id) {
  uint32_t next = first_id;
  for(const std::string &spec : specs) {
    uint32_t id;
    std::string path = spec;
    const size_t colon = spec.find(':');
    if(colon == 1 and spec[0] >= '0' and spec[0] <= '6') {
      id = spec[0] - '0';
      path = spec.substr(2);
    }
    else {
      while(next < 7 and m->scsi[next] != nullptr) {
	next++;
      }
      id = next;
    }
    if(id >= 7 or m->scsi[id] != nullptr) {
      fprintf(stderr, "scsi: no free target ID for '%s'\n", spec.c_str());
      return false;
    }
    scsi_dev_t *d = new scsi_dev_t(t, path);
    if(not d->ok()) {
      delete d;
      return false;
    }
    m->scsi[id] = d;
    fprintf(stderr, "scsi: target %u: %s\n", id, path.c_str());
  }
  return true;
}

int main(int argc, char **argv) {
  namespace po = boost::program_options;
  bool enable_checker = true, user = false;
  std::string pipelog, sparc_binary;
  std::string log_name = "log.txt";
  std::string pushout_name = "pushout.txt";
  std::string branch_name = "branch_info.txt";
  uint64_t heartbeat = 1UL<<36, start_trace_at = ~0UL;
  uint64_t max_cycle = 0, max_icnt = 0, mem_lat = 2;
  /* --warmup: retire this many instructions before measuring.  A checkpoint resumes
   * with every cache, TLB and predictor cold; the stats file (-l) then covers only
   * the --maxicnt instructions after the warm-up (the RTL's own counters printed at
   * the end still cover the whole run). */
  uint64_t warmup = 0;
  struct {
    uint64_t cycle = 0, insns = 0, mispredicts = 0, l1d_hits = 0, l1d_acc = 0;
    uint64_t l2_hits = 0, l2_acc = 0, loads = 0, stores = 0;
  } w0;
  /* MBus mode, data cache enabled (DE), MMU-off accesses cacheable (AC): an elf
   * runs cached, as the RTL caches only with DE (and AC with the MMU off) */
  std::string mmu_ctrl = "0x8900", mmu_ctpr = "0", mmu_ctx = "0";
  std::string ckpt_file, tcx_rom;
  std::vector<std::string> scsi_disks, scsi_cdroms;
  bool cg14 = false;
  bool no_kbd = false;
  std::map<uint32_t, uint64_t> pushout_histo;
  std::map<uint64_t, double> tip_map;          /* full per-cycle attribution (TIP, ported from rv64core) */
  int64_t mem_reply_cycle = -1L;
  try {
    po::options_description desc("Options");
    desc.add_options()
      ("help", "Print help messages")
      ("checker,c", po::value<bool>(&enable_checker)->default_value(true), "use checker")
      ("file,f", po::value<std::string>(&sparc_binary), "sparc elf binary")
      ("checkpoint", po::value<std::string>(&ckpt_file), "full system: resume an ss10sim checkpoint (sun4m devices, interrupts) instead of an elf")
      ("scsi-disk", po::value<std::vector<std::string>>(&scsi_disks)->composing(),
       "with --checkpoint: [ID:]image, the same SCSI disks the checkpoint was taken with (written in place: use a copy)")
      ("scsi-cdrom", po::value<std::vector<std::string>>(&scsi_cdroms)->composing(),
       "with --checkpoint: [ID:]image, a SCSI CD-ROM (default ID 6)")
      ("tcx", po::value<std::string>(&tcx_rom)->implicit_value("/usr/share/qemu/QEMU,tcx.bin"),
       "with --checkpoint: the checkpoint has a TCX (its FCode PROM)")
      ("cg14", po::bool_switch(&cg14), "with --checkpoint: the checkpoint has a CG14")
      ("no-kbd", po::bool_switch(&no_kbd), "with --tcx/--cg14: no keyboard (as ss10sim --no-kbd; Solaris runs)")
      ("user,u", po::bool_switch(&user), "checker ISS: linux user-mode emulation (syscalls + window spill/fill)")
      ("heartbeat,h", po::value<uint64_t>(&heartbeat)->default_value(1<<24), "heartbeat for stats")
      ("log,l", po::value<std::string>(&log_name), "stats log filename")
      ("pushout", po::value<std::string>(&pushout_name), "pushout log filename")
      ("branch", po::value<std::string>(&branch_name), "branch log filename")
      ("memlat,m", po::value<uint64_t>(&mem_lat)->default_value(4), "memory latency")
      ("pipelog,p", po::value<std::string>(&pipelog), "log for pipeline tracing")
      ("pipestart", po::value<uint64_t>(&pipestart)->default_value(0), "when to start logging")
      ("pipeend", po::value<uint64_t>(&pipeend)->default_value(~0UL), "when to stop logging")
      ("topdown", po::value<bool>(&topdown::enabled)->default_value(false), "top-down slot accounting over the pipestart..pipeend window (build with +define+TOPDOWN)")
      ("maxcycle", po::value<uint64_t>(&max_cycle)->default_value(1UL<<34), "maximum cycles")
      ("maxicnt", po::value<uint64_t>(&max_icnt)->default_value(1UL<<50), "maximum icnt (after --warmup)")
      ("warmup", po::value<uint64_t>(&warmup)->default_value(0), "instructions retired before the stats (-l) start counting")
      ("trace,t", po::value<bool>(&globals::trace_retirement)->default_value(false), "trace retired instruction stream")
      ("mmu-ctrl", po::value<std::string>(&mmu_ctrl), "SRMMU control register at reset (sim: until ASI 0x4 is plumbed)")
      ("mmu-ctpr", po::value<std::string>(&mmu_ctpr), "SRMMU context table pointer at reset")
      ("mmu-ctx", po::value<std::string>(&mmu_ctx), "SRMMU context at reset")
      ("starttrace,s", po::value<uint64_t>(&start_trace_at)->default_value(~0UL), "start tracing retired instructions")
      ;
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);
    if(vm.count("help") or (sparc_binary.empty() and ckpt_file.empty())) {
      std::cout << desc << "\n";
      return -1;
    }
  }
  catch(po::error &e) {
    std::cerr <<"command-line error : " << e.what() << "\n";
    return -1;
  }

  std::map<uint32_t, uint64_t> mispredicts;
  uint64_t inflight[32] = {0};
  uint32_t max_inflight = 0;

  const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
  contextp->commandArgs(argc, argv);

  sparse_mem *sm0 = new sparse_mem();
  sparse_mem *sm1 = new sparse_mem();
  s = new state_t(*sm0);
  ss = new state_t(*sm1);
  ss->user_emu = user;
  initState(s);
  initState(ss);
#ifdef STORE_CHECK
  g_store_check = enable_checker;
#endif
  initCapstone();
  if(not ckpt_file.empty()) {
    /* both the RTL's memory image (s) and the checker (ss) start from it; the
     * board is the checker's copy of the devices.  Both need the framebuffers
     * the checkpoint has before it loads; only the board gets the disks (the
     * RTL side's copy is discarded) */
    for(state_t *st : {s, ss}) {
      st->sun4m = new sun4m_t();
      if(not tcx_rom.empty()) {
	st->sun4m->tcx = new tcx_t();
	if(not st->sun4m->tcx->load_rom(tcx_rom)) {
	  std::cerr << "cannot read the TCX FCode " << tcx_rom << "\n";
	  return -1;
	}
      }
      if(cg14) {
	st->sun4m->cg14 = new cg14_t();
      }
      st->sun4m->have_kbd = (st->sun4m->tcx != nullptr or st->sun4m->cg14 != nullptr) and not no_kbd;
    }
    if(not attach_scsi(ss->sun4m, scsi_disks, scsi_dev_t::type_t::disk, 0) or
       not attach_scsi(ss->sun4m, scsi_cdroms, scsi_dev_t::type_t::cdrom, 6)) {
      return -1;
    }
    if(not load_checkpoint(ckpt_file.c_str(), s) or not load_checkpoint(ckpt_file.c_str(), ss)) {
      return -1;
    }
    delete s->sun4m;
    s->sun4m = nullptr;
    g_board = ss->sun4m;
    g_board->dma_hook = rtl_dma_hook;  /* device DMA writes reach the RTL's memory image after a snoop */
    g_board->dma_busy = rtl_dma_busy;  /* ... and complete once they all have */
    if(ss->npc != ss->pc + 4) {
      std::cerr << "checkpoint: npc " << std::hex << ss->npc << " is not pc + 4 (" << ss->pc << std::dec
		<< "): the RTL resumes from one pc\n";
      return -1;
    }
    /* what the RTL does not seed starts at its reset value on both sides */
    for(state_t *st : {s, ss}) {
      st->fq_addr = st->fq_insn = 0;
      st->mmu_fsr = st->mmu_far = 0;
    }
    std::cerr << "checkpoint: the FQ and the MMU fault registers start at their reset values\n";
    ss->dev = &g_replay;
    ss->ext_irq = true;
    g_ckpt_state = ss;
    /* fp_regfile seeds phys i = arch i from loadfpr at reset without an
     * fp_prf_wr: give the compare's mirror the same values */
    for(int i = 0; i < 32; i++) {
      g_rtl_fp_prf[i] = static_cast<uint64_t>(loadfpr(i));
    }
    g_mmu_preload[0] = ss->mmu_ctrl;
    g_mmu_preload[1] = ss->mmu_ctpr;
    g_mmu_preload[2] = ss->mmu_ctx;
    fprintf(stderr, "checkpoint: mmu ctrl %08x ctpr %08x ctx %x\n", ss->mmu_ctrl, ss->mmu_ctpr, ss->mmu_ctx);
  }
  else {
    load_elf(sparc_binary.c_str(), s);
    load_elf(sparc_binary.c_str(), ss);
    g_mmu_preload[0] = std::stoul(mmu_ctrl, nullptr, 0);
    g_mmu_preload[1] = std::stoul(mmu_ctpr, nullptr, 0) & ~3u;
    g_mmu_preload[2] = std::stoul(mmu_ctx, nullptr, 0) & 0xffffu;
    ss->mmu_ctrl = g_mmu_preload[0];
    ss->mmu_ctpr = g_mmu_preload[1];
    ss->mmu_ctx = g_mmu_preload[2];
  }

  std::unique_ptr<Vcore_l1d_l1i> tb(new Vcore_l1d_l1i);
  uint64_t last_match_pc = 0;
  uint64_t last_retire = 0, last_check = 0;
  uint64_t last_retired_pc = 0;
  uint64_t mismatches = 0, n_stores = 0, n_loads = 0;
  uint64_t n_branches = 0, n_mispredicts = 0, n_checks = 0, n_flush_cycles = 0;
  bool incorrect = false;

  //assert reset
  tb->retire_allowed = 1;
  tb->mem_rsp_bad = 0;
  /* a checkpoint resume seeds the register file one entry per bank per reset
   * cycle (rf4r2w.sv): hold reset past its depth */
  /* >= 128 cycles: exec.sv seeds its backing RF of the window registers one
   * entry per reset cycle (and rf4r2w a checkpoint's PRF, HALF per bank) */
  const uint64_t reset_cycles = g_ckpt_state ? 2 * (1u << 10) : 256;
  for(globals::cycle = 0; (globals::cycle < reset_cycles) && !Verilated::gotFinish(); ++globals::cycle) {
    contextp->timeInc(1);
    tb->mem_rsp_valid = 0;
    tb->reset = 1;
    clock_tb(tb.get());
    ++globals::cycle;
  }
  tb->resume_pc = s->pc;
  contextp->timeInc(1);
  tb->reset = 0;
  clock_tb(tb.get());
  while(!tb->ready_for_resume) {
    ++globals::cycle;
    clock_tb(tb.get());
  }
  ++globals::cycle;
  tb->resume = 1;
  clock_tb(tb.get());
  ++globals::cycle;
  tb->resume = 0;
  clock_tb(tb.get());

  if(not(pipelog.empty())) {
    pl = new pipeline_logger(pipelog);
  }

  ++globals::cycle;
  tb->resume = 1;
  tb->resume_pc = s->pc;
  clock_tb(tb.get());
  ++globals::cycle;
  tb->resume = 0;
  clock_tb(tb.get());
  //done with initialize
  globals::cycle = 0;

  tb->single_step = 0;
  tb->step = 0;
  double t0 = timestamp();
  bool irq_pending = false;
  uint32_t irq_pc = 0, irq_level = 0;
  while(!Verilated::gotFinish() && (globals::cycle < max_cycle) && (insns_retired < (max_icnt + warmup))) {
    if(g_board) {
      /* an APC halt (sun4m.cc) holds retirement; time skips to the next timer
       * event until an interrupt is requested (ss10sim's rule) */
      if(g_board->cpu_halted) {
	if(ss->et and ss->irl != 0) {
	  g_board->cpu_halted = false;
	}
	else if(not g_board->warp_to_next_event(ss)) {
	  std::cout << "FAIL: the CPU halted with no timer event to wake it\n";
	  incorrect = true;
	  break;
	}
      }
      tb->retire_allowed = g_board->cpu_halted ? 0 : 1;
      tb->irl = ss->irl;
    }
    else {
      tb->irl = 0;
    }
    contextp->timeInc(1);
    snoop_drive(tb.get());
    tb->clk = 1;
    tb->eval();
    snoop_sample(tb.get());
    if(tb->trap_taken and ((tb->trap_taken_tt & 0xf0) == 0x10) and (tb->trap_taken_tt & 0xf)) {
      /* an interrupt: its TRAP_L2 retires with the interrupted pc, which the
       * checker then takes the interrupt at instead of executing */
      irq_pending = true;
      irq_pc = tb->trap_taken_pc;
      irq_level = tb->trap_taken_tt & 0xf;
    }

    if(tb->retire_reg_valid) {
      s->r[tb->retire_reg_ptr] = tb->retire_reg_data;
    }
    if(tb->branch_pc_valid) {
      ++n_branches;
    }
    if(tb->branch_fault) {
      mispredicts[tb->branch_pc]++;
      ++n_mispredicts;
    }
    if(tb->in_flush_mode) {
      ++n_flush_cycles;
    }

    /* TIP: full per-cycle attribution (rv64core top.cc parity). ROB-empty ->
     * blame last-retired (stall is upstream/fetch); nothing retires -> blame the
     * true ROB head (dbg_head_pc); something retires -> split 1.0/total across the
     * retiring ops. sum(tip) == total cycles. */
    if(tb->dbg_head_status & 0x1) {
      tip_map[last_retired_pc] += 1.0;
    }
    else if(!(tb->retire_valid || tb->retire_two_valid)) {
      tip_map[tb->dbg_head_pc] += 1.0;
    }
    else {
      double total = static_cast<double>(tb->retire_valid) + static_cast<double>(tb->retire_two_valid);
      tip_map[tb->retire_pc] += 1.0 / total;
      if(tb->retire_two_valid) {
	tip_map[tb->retire_two_pc] += 1.0 / total;
      }
    }

    /* the checker: the ISS must be at each retiring pc, then steps once.  It
     * holds that invariant across annulled slots and traps because the ISS
     * steps exactly the instructions that retire. */
    uint64_t retire_pcs[2];
    int n_retire = 0;
    if(tb->retire_valid) {
      retire_pcs[n_retire++] = tb->retire_pc;
      if(tb->retire_two_valid) {
	retire_pcs[n_retire++] = tb->retire_two_pc;
      }
    }
    for(int i = 0; i < n_retire; i++) {
      const uint32_t rpc = static_cast<uint32_t>(retire_pcs[i]);
      ++insns_retired;
      if(insns_retired == warmup) {
	w0.cycle = globals::cycle;
	w0.insns = insns_retired;
	w0.mispredicts = n_mispredicts;
	w0.l1d_hits = tb->l1d_cache_hits;
	w0.l1d_acc = tb->l1d_cache_accesses;
	w0.l2_hits = tb->l2_cache_hits;
	w0.l2_acc = tb->l2_cache_accesses;
	w0.loads = n_loads;
	w0.stores = n_stores;
	std::cout << "warm-up done at cycle " << globals::cycle << "\n";
      }
      if(last_retire > 1) {
	pushout_histo[rpc] += last_retire;
      }
      last_retire = 0;
      last_retired_pc = rpc;
      if(insns_retired >= start_trace_at) {
	globals::trace_retirement = true;
      }
      if(((insns_retired % heartbeat) == 0) or globals::trace_retirement) {
	std::cout << "retiring "
		  << std::hex << rpc << std::dec
		  << " cycle " << globals::cycle
		  << " " << getAsmString(get_insn(rpc, s), rpc)
		  << std::fixed
		  << ", " << static_cast<double>(insns_retired) / globals::cycle << " IPC "
		  << ", insns_retired " << insns_retired
		  << ", mispredict pki " << (static_cast<double>(n_mispredicts) / insns_retired) * 1000.0
		  << std::defaultfloat << " \n";
      }
      if(not(enable_checker)) {
	continue;
      }
      if(rpc != ss->pc) {
	if(++last_check > 2) {
	  incorrect = true;
	  std::cout << "COSIM DESYNC: rtl pc " << std::hex << rpc
		    << " != sim pc " << ss->pc << std::dec
		    << " -- control flow diverged, last match "
		    << std::hex << last_match_pc << std::dec << "\n";
	  break;
	}
	continue;
      }
      if(g_board and i == 0 and tb->retire_insn != 0) {
	/* the retired instruction word against what the checker fetches there: a
	 * difference is a bad fetch (translation or I-cache) caught at retirement */
	uint32_t iw = 0;
	if(debug_fetch(ss, rpc, &iw) and iw != static_cast<uint32_t>(tb->retire_insn)) {
	  static uint64_t n_bad_fetch = 0;
	  if(n_bad_fetch++ < 10) {
	    std::cout << "BAD FETCH at pc " << std::hex << rpc << ": rtl " << tb->retire_insn << " "
		      << getAsmString(tb->retire_insn, rpc) << ", memory " << iw << " " << getAsmString(iw, rpc)
		      << std::dec << " (retired " << insns_retired << ", cycle " << globals::cycle << ")\n";
	  }
	}
      }
      if(g_board and ss->icnt >= g_board->next_event_icnt) {
	g_board->timer_event(ss);
      }
      if(irq_pending and rpc == irq_pc) {
	take_interrupt(ss, irq_level);
	irq_pending = false;
      }
      else {
	execSparc(ss);
      }
      ++n_checks;
      last_check = 0;
      last_match_pc = rpc;
      if(ss->brk) {
	/* the RTL retired an instruction the ISS trapped on into error mode
	 * (the RTL should have halted on it, without retiring it) */
	if(ss->error_mode) {
	  std::cout << "FAIL: the RTL retired pc " << std::hex << rpc << std::dec
		    << ", where the ISS took a trap into error mode\n";
	  incorrect = true;
	}
	break;
      }
    }
    if(g_dev_error) {
      incorrect = true;
    }
#ifdef STORE_CHECK
    drain_store_check();
    if(g_store_diverged) {
      incorrect = true;
    }
#endif
    if(incorrect or (enable_checker and ss->brk)) {
      break;
    }

    if(tb->retire_reg_two_valid) {
      s->r[tb->retire_reg_two_ptr] = tb->retire_reg_two_data;
    }
    if(tb->retire_y_valid) {
      s->y = tb->retire_y_data;
    }

    /* architectural compare once the cycle's writebacks have landed: the RTL's
     * retired registers (s) against the ISS (ss) */
    if(enable_checker and (n_retire != 0)) {
      for(uint32_t i = 0; i < N_ARCH_REGS; i++) {
	if(s->r[i] != ss->r[i]) {
	  ++mismatches;
	  std::cout << "register r[" << i << "] does not match : rtl "
		    << std::hex << s->r[i] << " simulator " << ss->r[i] << std::dec
		    << " after " << std::hex << last_match_pc << std::dec
		    << " : " << getAsmString(get_insn(last_match_pc, s), last_match_pc) << "\n";
	  incorrect = true;
	}
      }
      for(uint32_t k = 0; k < 16; k++) {
	const uint64_t iss = (static_cast<uint64_t>(ss->f[2 * k]) << 32) | ss->f[2 * k + 1];
	const uint64_t rtl = rtl_fp_pair(k);
	if(rtl != iss) {
	  ++mismatches;
	  std::cout << "fp register d" << (2 * k) << " (f" << (2 * k) << ":f" << (2 * k + 1)
		    << ") does not match : rtl " << std::hex << rtl << " simulator " << iss << std::dec
		    << " after " << std::hex << last_match_pc << std::dec
		    << " : " << getAsmString(get_insn(last_match_pc, s), last_match_pc) << "\n";
	  incorrect = true;
	}
      }
      if(g_rtl_sregs_valid and not ss->user_emu) {   /* (user emulation models a process, not the PSR) */
	/* the PSR fields the RTL holds outside the PRF (icc rides in the PRF and
	 * shows up through the branches that read it) */
	const uint32_t psr_mask = (1u << 12) | (0xfu << 8) | (1u << 7) | (1u << 6) | (1u << 5) | 0x1fu;
	const uint32_t iss_psr = ss->get_psr() & psr_mask;
	const uint32_t wim_mask = (1u << NWINDOWS) - 1;
	if((g_rtl_psr & psr_mask) != iss_psr or (g_rtl_wim & wim_mask) != (ss->wim & wim_mask)) {
	  ++mismatches;
	  std::cout << "PSR/WIM does not match : rtl psr " << std::hex << (g_rtl_psr & psr_mask) << " wim "
		    << (g_rtl_wim & wim_mask) << " simulator psr " << iss_psr << " wim " << (ss->wim & wim_mask)
		    << std::dec << " (psr bits: EF 12, PIL 11:8, S 7, PS 6, ET 5, CWP 4:0) after "
		    << std::hex << last_match_pc << std::dec
		    << " : " << getAsmString(get_insn(last_match_pc, s), last_match_pc) << "\n";
	  incorrect = true;
	}
      }
      if(s->y != ss->y) {
	++mismatches;
	std::cout << "Y does not match : rtl " << std::hex << s->y << " simulator " << ss->y << std::dec
		  << " after " << std::hex << last_match_pc << std::dec
		  << " : " << getAsmString(get_insn(last_match_pc, s), last_match_pc) << "\n";
	incorrect = true;
      }
      if(incorrect) {
	std::cout << "iss: pc " << std::hex << ss->pc << " npc " << ss->npc << " psr " << ss->get_psr()
		  << " wim " << ss->wim << std::dec << "\n";
	if(g_board) {
	  /* the instruction at the mismatch through each side's memory image (and
	   * the checker's MMU state): a difference means the RTL's memory diverged */
	  uint32_t iw_rtl = 0, iw_iss = 0;
	  state_t probe(*sm0);
	  probe.mmu_ctrl = ss->mmu_ctrl;
	  probe.mmu_ctpr = ss->mmu_ctpr;
	  probe.mmu_ctx = ss->mmu_ctx;
	  probe.ram_size = ss->ram_size;
	  {
	    uint32_t pte = 0, lvl = 0;
	    uint64_t wpa = 0;
	    if(debug_walk(ss, static_cast<uint32_t>(last_match_pc), &pte, &lvl, &wpa)) {
	      std::cout << "walk for " << std::hex << last_match_pc << ": level " << lvl << " pte " << pte << " pa " << wpa << std::dec << "\n";
	    }
	  }
	  bool ok_rtl = debug_fetch(&probe, static_cast<uint32_t>(last_match_pc), &iw_rtl);
	  bool ok_iss = debug_fetch(ss, static_cast<uint32_t>(last_match_pc), &iw_iss);
	  std::cout << "insn at " << std::hex << last_match_pc << ": rtl image " << (ok_rtl ? "" : "(no xlate) ") << iw_rtl
		    << " " << getAsmString(iw_rtl, last_match_pc) << ", iss image " << (ok_iss ? "" : "(no xlate) ") << iw_iss
		    << " " << getAsmString(iw_iss, last_match_pc) << std::dec << "\n";
	}
	std::cout << "rtl registers:\n";
	dump_regs(s);
	std::cout << "iss registers:\n";
	dump_regs(ss);
	break;
      }
    }

    ++last_retire;
    if(g_board and g_board->cpu_halted) {
      last_retire = 0;
    }
    /* FLUSH_FOR_HALT (core state 0) walks the whole L2 before got_break: with a
     * 512KB L2 that alone is ~2^16 cycles with nothing retiring */
    if(tb->core_state == 0) {
      last_retire = 0;
    }
    if(last_retire > (1U<<16) && not(tb->in_flush_mode)) {
      std::cerr << "no retire in " << last_retire << " cycles, last retired "
		<< std::hex << last_retired_pc << std::dec
		<< " " << getAsmString(get_insn(last_retired_pc, s), last_retired_pc)
		<< "\ncore state " << static_cast<int>(tb->core_state)
		<< ", rob head pc " << std::hex << tb->dbg_head_pc << " status " << static_cast<int>(tb->dbg_head_status) << std::dec
		<< ", checker pc " << std::hex << ss->pc << std::dec << " irl " << ss->irl << " pil " << ss->pil << " et " << ss->et
		<< ", lsu device reads queued " << g_replay.reads.size() << " writes " << g_replay.writes.size()
		<< ", l1i state " << static_cast<int>(tb->l1i_state) << " l1d state " << static_cast<int>(tb->l1d_state) << "\n";
      break;
    }
    if(tb->got_break) {
      /* the RTL halted in error mode (a trap with ET=0) at epc, without retiring
       * that instruction: the ISS must take the same trap into error mode */
      std::cout << "RTL error mode at pc " << std::hex << tb->epc << std::dec << "\n";
      if(enable_checker) {
	if(ss->pc == static_cast<uint32_t>(tb->epc)) {
	  execSparc(ss);
	}
	/* the L1D and L2 were flushed (FLUSH_FOR_HALT) before got_break, so sm0 is
	 * the RTL's final memory.  It must match the ISS's byte for byte: the
	 * register compare never sees a bad store that is not loaded back (a dead
	 * window spill, say) */
	uint64_t n_bad_pages = 0, first_bad = 0;
	for(uint64_t pa = 0; pa < sparse_mem::sz; pa += sparse_mem::pgsize) {
	  if(memcmp(sm0->mem + pa, sm1->mem + pa, sparse_mem::pgsize) != 0) {
	    if(n_bad_pages == 0) {
	      first_bad = pa;
	      while(sm0->mem[first_bad] == sm1->mem[first_bad]) {
		++first_bad;
	      }
	    }
	    ++n_bad_pages;
	  }
	}
	if(n_bad_pages != 0) {
	  std::cout << "FAIL: memory differs in " << n_bad_pages << " pages, first at "
		    << std::hex << first_bad << " : rtl " << static_cast<uint32_t>(sm0->mem[first_bad])
		    << " simulator " << static_cast<uint32_t>(sm1->mem[first_bad]) << std::dec << "\n";
	  incorrect = true;
	}
	else if(ss->error_mode) {
	  std::cout << "PASS: RTL and ISS halt in error mode at the same pc\n";
	}
	else {
	  std::cout << "FAIL: the ISS is at pc " << std::hex << ss->pc << std::dec
		    << ", not in error mode at the RTL's\n";
	  incorrect = true;
	}
      }
      break;
    }
    else if(tb->got_ud) {
      std::cerr << "GOT UD for " << std::hex << tb->epc << std::dec
		<< " " << getAsmString(get_insn(tb->epc, s), tb->epc) << "\n";
      break;
    }
    else if(tb->got_bad_addr) {
      std::cerr << "GOT BAD VA for " << std::hex << tb->epc << std::dec
		<< " " << getAsmString(get_insn(tb->epc, s), tb->epc) << "\n";
      break;
    }
    inflight[tb->inflight & 31]++;
    max_inflight = std::max(max_inflight, static_cast<uint32_t>(tb->inflight));

    //negedge
    tb->mem_rsp_valid = 0;
    if(tb->mem_req_valid && (mem_reply_cycle == -1)) {
      mem_reply_cycle = globals::cycle + (tb->mem_req_opcode == 4 ? 1 : 2)*mem_lat;
    }
    if(mem_reply_cycle == static_cast<int64_t>(globals::cycle)) {
      uint16_t m = tb->mem_req_mask;
      last_retire = 0;
      mem_reply_cycle = -1;
      assert(tb->mem_req_valid);
      tb->mem_rsp_bad = 0;
      const uint64_t pa = tb->mem_req_addr;
      /* an uncached ldstub/swap (mem_op_t MEM_LDSTUB 8 / MEM_SWAP 9, l1d.sv):
       * the memory side's atomic read-modify-write -- answer the old line, write
       * the store data under the mask */
      const bool atomic = (tb->mem_req_opcode == 8) or (tb->mem_req_opcode == 9);
      if(g_board and pa >= s->ram_size) {
	/* sun4m device space (uncached, so one access per request) */
	uint32_t d[4] = {0, 0, 0, 0};
	bool be = false;
	if(tb->mem_req_opcode == 7) {
	  for(int i = 0; i < 4; i++) {
	    d[i] = tb->mem_req_store_data[i];
	  }
	}
	dev_line_access(tb->mem_req_opcode == 7, pa & ~15ULL, m, d, &be);
	if(atomic and not be) {
	  uint32_t w[4];
	  for(int i = 0; i < 4; i++) {
	    w[i] = tb->mem_req_store_data[i];
	  }
	  dev_line_access(true, pa & ~15ULL, m, w, &be);
	}
	if(tb->mem_req_opcode == 4 or atomic) {
	  for(int i = 0; i < 4; i++) {
	    tb->mem_rsp_load_data[i] = d[i];
	  }
	  tb->mem_rsp_bad = be ? 1 : 0;
	}
	tb->mem_rsp_valid = 1;
      }
      else if(atomic) {
	assert((tb->mem_req_addr & 0xf) == 0);
	for(int i = 0; i < 4; i++) {
	  uint32_t ea = (tb->mem_req_addr + 4*i) & (~0U);
	  tb->mem_rsp_load_data[i] = perform_word_load(s, ea, 0xffff);
	  perform_word_store(s, ea, m, tb->mem_req_store_data[i]);
	}
	++n_loads;
	++n_stores;
      }
      else if(tb->mem_req_opcode == 4) { /* load line */
	for(int i = 0; i < 4; i++) {
	  uint32_t ea = (tb->mem_req_addr + 4*i) & (~0U);
	  tb->mem_rsp_load_data[i] = perform_word_load(s, ea, m);
	}
	assert((tb->mem_req_addr & 0xf) == 0);
	++n_loads;
      }
      else if(tb->mem_req_opcode == 7) { /* store line */
	for(int i = 0; i < 4; i++) {
	  uint32_t ea = (tb->mem_req_addr + 4*i) & (~0U);
	  perform_word_store(s, ea, m, tb->mem_req_store_data[i]);
	}
	++n_stores;
      }
      tb->mem_rsp_valid = 1;
    }

    tb->clk = 0;
    tb->eval();
    ++globals::cycle;
  }

  tb->final();
  t0 = timestamp() - t0;

  if(!incorrect) {
    std::ofstream out(log_name);
    /* everything below the warm-up line is measured from it (w0 is zero without one) */
    const uint64_t m_cycles = globals::cycle - w0.cycle, m_insns = insns_retired - w0.insns;
    if(warmup != 0) {
      out << "warmup = " << warmup << " insns, " << w0.cycle << " cycles\n";
    }
    out << "n_mispredicts = " << (n_mispredicts - w0.mispredicts)
	<<  ", cycles = " << m_cycles
	<< ", insns = " << m_insns
	<< ", n_checks = " << n_checks
	<< "\n";
    out << static_cast<double>(m_insns) / m_cycles << " insn per cycle\n";
    double avg_inflight = 0, sum = 0;
    for(int i = 0; i < 32; i++) {
      if(inflight[i] == 0) continue;
      avg_inflight += i * inflight[i];
      sum += inflight[i];
      //printf("inflight[%d] = %lu\n", i, inflight[i]);
    }
    avg_inflight /= sum;
    out << insns_retired << " insns retired\n";

  
    out << "avg insns in ROB = " << avg_inflight
	      << ", max inflight = " << max_inflight << "\n";
  

    out << "l1d cache hits = " << (tb->l1d_cache_hits - w0.l1d_hits) << "\n";
    out << "l1d cache accesses = " << (tb->l1d_cache_accesses - w0.l1d_acc) << "\n";
    out << "l1d hit rate = "
	      << 100.0 *(static_cast<double>(tb->l1d_cache_hits - w0.l1d_hits) / (tb->l1d_cache_accesses - w0.l1d_acc))
	      << "\n";
    out << "l1i cache hits = " << tb->l1i_cache_hits << "\n";
    out << "l1i cache accesses = " << tb->l1i_cache_accesses << "\n";
    out << "l1i hit rate = "
	      << 100.0 *(static_cast<double>(tb->l1i_cache_hits) / tb->l1i_cache_accesses)
	      << "\n";

    out << "l2 cache hits = " << (tb->l2_cache_hits - w0.l2_hits) << "\n";
    out << "l2 cache accesses = " << (tb->l2_cache_accesses - w0.l2_acc) << "\n";


    out << "branch mispredict rate = "
	      << (static_cast<double>(n_mispredicts)/n_branches)*100.0
	      << "\n";

    out << "mispredicts per kiloinsn = "
	      << (static_cast<double>(n_mispredicts - w0.mispredicts) / m_insns) * 1000.0
	      << "\n";
    out << n_flush_cycles << " cycles spent flushing caches\n";
    out << (n_loads - w0.loads) << " cache line loads\n";
    out << (n_stores - w0.stores) << " cache line stores\n";
    out << l1d_misses << " l1d misses\n";
    out << l1d_insns << " insns access the l1d\n";

    uint64_t total_fetch = 0, total_fetch_cycles = 0;
    for(int i = 0; i < 5; i++) {
      //out << "n_fetch[" << i << "] = " << n_fetch[i] << "\n";
      total_fetch_cycles += n_fetch[i];
      total_fetch += n_fetch[i] * i;
    }
    out << "avg fetch = " << static_cast<double>(total_fetch) / total_fetch_cycles << "\n";
    out << "resteer bubble = " << n_resteer_bubble << "\n";
    out << "front-end queues full = " << n_fq_full << "\n";
    double total_fetch_cap = 0.0;

  
    // for(int i = 0; i < 3; i++) {
    //   out << "uq_full[" << i << "] = " << n_uq_full[i] << "\n";
    // }
    // for(int i = 0; i < 3; i++) {
    //   out << "alloc[" << i << "] = " << n_alloc[i] << "\n";
    // }
    out << n_int_exec[0] << " cycles where int exec queue is not empty\n";
    out << n_int_exec[1] << " cycles where int exec queue dispatches\n";
    out << n_mem_exec[0] << " cycles where mem exec queue is not empty\n";
    out << n_mem_exec[1] << " cycles where mem exec queue dispatches\n";
    out << n_mem_exec[2] << " cycles where mem exec queue is blocked by a store\n";

    out << q_full[0] << " cycles with int queue full\n";
    out << q_full[1] << " cycles with mem queue full\n";
    out << dq_empty  << " cycles with an empty decode queue\n";
    out << uq_full   << " cycles with a  full uop queue\n";
    out << n_active << " cycles where the machine is in active state\n";
    out << rob_full << " cycles where the rob is full\n";
  
    //for(int i = 0; i < 3; i++) {
    //out << "insn ready " << i
    //		<< " "
    //<< n_rdy[i] << "\n";
    //}
    double avg_restart = 0.0;
    uint64_t total_restart = 0, accum_restart = 0;
    for(auto &p : restart_distribution) {
      avg_restart += (p.first * p.second);
      total_restart += p.second;
    }
    for(auto &p : restart_distribution) {
      accum_restart += p.second;
      if(accum_restart >= (total_restart/2)) {
	out << p.first << " median flush cycles\n";
	break;
      }
    }
    if(total_restart != 0) {
      out << avg_restart << " cycles spent in pipeline flush\n";
      avg_restart /= total_restart;
      out << total_restart << " times pipeline was flushed\n";
      out << avg_restart << " cycles to flush on avg\n";
      out << restart_distribution.begin()->first << " min cycles to flush\n";
      out << restart_distribution.rbegin()->first << " max cycles to flush\n";
    }
    
    double avg_ds_restart = 0.0;
    uint64_t total_ds_restart = 0, accum_ds_restart = 0;
    for(auto &p : restart_ds_distribution) {
      avg_ds_restart += (p.first * p.second);
      total_ds_restart += p.second;
    }
    for(auto &p : restart_ds_distribution) {
      accum_ds_restart += p.second;
      if(accum_ds_restart >= (total_ds_restart/2)) {
	out << p.first << " median delay slot flush cycles\n";
	break;
      }
    }
    if(total_ds_restart != 0) {
      out << avg_ds_restart << " cycles spent waiting for delay slot in flush\n";
      avg_ds_restart /= total_ds_restart;
      out << avg_ds_restart << " cycles waiting on delay slot on avg\n";
      out << restart_ds_distribution.begin()->first << " min cycles for delay slot\n";
      out << restart_ds_distribution.rbegin()->first << " max cycles for delay slot\n";
    }
    for(auto &p : fault_distribution) {
      out << p.first << " faults inflight, " << p.second << " times\n";
    }
    for(auto &p : branch_distribution) {
      out << p.first << " branches inflight, " << p.second << " times\n";
    }
    for(auto &p : fault_to_restart_distribution) {
      out << p.first << " cycles before restart, " << p.second << " times\n";
    }
    dump_histo(branch_name, mispredicts, s);
    uint64_t total_pushout = 0;
    for(auto &p : pushout_histo) {
      total_pushout += p.second;
    }
    out << total_pushout << " cycles of pushout\n";
    dump_histo(pushout_name, pushout_histo, s);

    /* TIP dump (rv64core-format: PC:disasm,cycles,per-kiloinsn), sorted desc */
    {
      double tip_total = 0.0;
      for(auto &p : tip_map) { tip_total += p.second; }
      std::cout << "tip cycles  = " << tip_total << "\n";
      std::vector<std::pair<uint64_t,double>> tv(tip_map.begin(), tip_map.end());
      std::sort(tv.begin(), tv.end(), [](const std::pair<uint64_t,double> &a, const std::pair<uint64_t,double> &b){ return a.second > b.second; });
      std::ofstream tf("tip.txt");
      for(auto &p : tv) {
	uint32_t pc = static_cast<uint32_t>(p.first);
	tf << std::hex << p.first << std::dec << ":"
	   << getAsmString(insn_at(pc, s), pc) << ","
	   << p.second << ","
	   << (insns_retired ? (p.second / insns_retired) * 1000.0 : 0.0) << "\n";
      }
      tf.close();
    }

    //std::ofstream branch_info("retire_info.csv");
    uint64_t total_retire = 0, total_cycle = 0;
    for(auto &p : retire_map) {
      total_retire += p.second;
    }
    for(auto &p : retire_map) {
      //branch_info << p.first << "," << p.second << "," << static_cast<double>(p.second) / total_retire << "\n";
      total_cycle += (p.first * p.second);
    }
    //branch_info.close();
    int median_int_rdy;
    double avg_int_rdy = histo_mean_median(int_sched_rdy_map, median_int_rdy);
    out << "avg int rdy insn = " << avg_int_rdy << "\n";
    out << "median int rdy insn = " << median_int_rdy << "\n";
    
    int median_mem_lat = 0;
    double avg_mem_lat = histo_mean_median(mem_lat_map, median_mem_lat);
    out << "avg mem alloc to complete = " << avg_mem_lat << "\n";
    out << "median mem alloc to complete = " << median_mem_lat << "\n";

    avg_mem_lat = histo_mean_median(non_mem_lat_map, median_mem_lat);
    out << "avg non-mem alloc to complete = " << avg_mem_lat << "\n";
    out << "median non-mem alloc to complete = " << median_mem_lat << "\n";

    
    out << "l1d_reqs = " << l1d_reqs << "\n";
    out << "l1d_acks = " << l1d_acks << "\n";
    out << "l1d_stores = " << l1d_stores << "\n";
    out << "l1d tput = " << (static_cast<double>(l1d_acks) /l1d_reqs) << "\n";
    
    //for(auto &p :block_distribution) {
    //out << p.first << "," << p.second << "\n";
    //}
    for(int i = 1; i < 8; i++) {
      if(l1d_stall_reasons[i] != 0) {
	out << l1d_stall_reasons[i] << " " << l1d_stall_str[i] << "\n";
      }
    }
    std::cout << "total_retire = " << total_retire << "\n";
    std::cout << "total_cycle  = " << total_cycle << "\n";
    std::cout << "total ipc    = " << static_cast<double>(total_retire) / total_cycle << "\n";
#ifdef STORE_CHECK
    std::cout << "stores checked = " << g_stores_checked << " (unmatched: ISS " << g_iss_stores.size()
	      << ", RTL " << g_rtl_stores.size() << ")\n";
#endif
    /* L1D/L1I/L2 access+hit counters (l1d.sv).  Tied off at the henry_soc level,
     * so nothing has ever read them -- print here to establish WHAT THEY COUNT
     * before wiring them to AXI regs. */
    std::cout << "[ctr] l1d acc=" << tb->l1d_cache_accesses << " hit=" << tb->l1d_cache_hits;
    if(tb->l1d_cache_accesses) std::cout << " (" << (100.0*tb->l1d_cache_hits)/tb->l1d_cache_accesses << "%)";
    std::cout << "\n[ctr] l1i acc=" << tb->l1i_cache_accesses << " hit=" << tb->l1i_cache_hits;
    std::cout << "\n[ctr] l2  acc=" << tb->l2_cache_accesses  << " hit=" << tb->l2_cache_hits << "\n";
    if(topdown::enabled) {
      topdown_report();
    }

    out.close();
  }
  else {
    std::cout << "instructions retired = " << insns_retired << "\n";
  /* L1D/L1I/L2 access+hit counters (l1d.sv r_cache_accesses/r_cache_hits).  These
   * have never been read by anything -- they are tied off at the henry_soc level
   * -- so print them here to establish WHAT THEY COUNT before anyone wires them
   * to AXI regs and draws conclusions from them. */
  std::cout << "[ctr] l1d_accesses = " << tb->l1d_cache_accesses
            << "  l1d_hits = " << tb->l1d_cache_hits;
  if(tb->l1d_cache_accesses) {
    std::cout << "  (" << (100.0*tb->l1d_cache_hits)/tb->l1d_cache_accesses << "% hit)";
  }
  std::cout << "\n[ctr] l1i_accesses = " << tb->l1i_cache_accesses
            << "  l1i_hits = " << tb->l1i_cache_hits << "\n";
  std::cout << "[ctr] l2_accesses  = " << tb->l2_cache_accesses
            << "  l2_hits  = " << tb->l2_cache_hits << "\n";
  }
  
  /* the checks with no failure of their own: how much they saw */
  std::cout << "tlb fills checked = " << g_tlb_fills << ", mismatched = " << g_tlb_fill_bad << "\n";
  std::cout << "dma line snoops = " << g_snoops << " (" << g_dma_lines.size() << " still queued)\n";
  std::cout << "simulation took " << t0 << " seconds, " << (insns_retired/t0)
	    << " insns per second\n";



  delete s;
  delete ss;
  if(pl) {
    delete pl;
  }
  stopCapstone();
  return incorrect ? -1 : EXIT_SUCCESS;
}
