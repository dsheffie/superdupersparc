#include "top.hh"
#include <cstring>
#include <deque>

/* SPARC V8 Verilator testbench.  s = the architectural state the RTL's retire
 * stream writes back (and the memory image the RTL's memory port serves); ss =
 * the checker ISS (interpret.cc), stepped once per retired instruction.
 *
 * Devices: none yet -- the memory port is RAM only (sun4m.cc devices get wired
 * in with the SRMMU / sun4m phase). */

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

/* Checkpoint-resume DPI seed hooks (used by the henry full-system tb to inject a
 * fast-forwarded ISS state at reset).  ooo_core never resumes from a checkpoint, so
 * have_checkpoint() returns 0 -> the RTL seed branches are dead; these stubs only
 * satisfy the linker for the `ifdef VERILATOR` DPI imports in the core RTL. */
extern "C" {
  int       have_checkpoint(void)               { return 0; }
  int       have_ckpt_t(void)                   { return 0; }
  long long loadgpr(int regid)                  { (void)regid; return 0; }
  long long loadfpr(int regid)                  { (void)regid; return 0; }
}

/* l1d.sv's co-sim hooks (ENABLE_STORE_CHECK etc.); no SPARC consumer yet */
extern "C" void wr_log(long long, int, unsigned long long, unsigned long long, int) {
}
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
    pl->append(record_insns_retired, getAsmString(get_insn(pc, s), pc), pc, fetch_cycle, alloc_cycle, complete_cycle, retire_cycle, faulted,
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

int main(int argc, char **argv) {
  namespace po = boost::program_options;
  bool enable_checker = true, user = false;
  std::string pipelog, sparc_binary;
  std::string log_name = "log.txt";
  std::string pushout_name = "pushout.txt";
  std::string branch_name = "branch_info.txt";
  uint64_t heartbeat = 1UL<<36, start_trace_at = ~0UL;
  uint64_t max_cycle = 0, max_icnt = 0, mem_lat = 2;
  std::map<uint32_t, uint64_t> pushout_histo;
  std::map<uint64_t, double> tip_map;          /* full per-cycle attribution (TIP, ported from rv64core) */
  int64_t mem_reply_cycle = -1L;
  try {
    po::options_description desc("Options");
    desc.add_options()
      ("help", "Print help messages")
      ("checker,c", po::value<bool>(&enable_checker)->default_value(true), "use checker")
      ("file,f", po::value<std::string>(&sparc_binary), "sparc elf binary")
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
      ("maxicnt", po::value<uint64_t>(&max_icnt)->default_value(1UL<<50), "maximum icnt")
      ("trace,t", po::value<bool>(&globals::trace_retirement)->default_value(false), "trace retired instruction stream")
      ("starttrace,s", po::value<uint64_t>(&start_trace_at)->default_value(~0UL), "start tracing retired instructions")
      ;
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);
    if(vm.count("help") or sparc_binary.empty()) {
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
  initCapstone();
  load_elf(sparc_binary.c_str(), s);
  load_elf(sparc_binary.c_str(), ss);

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
  for(globals::cycle = 0; (globals::cycle < 4) && !Verilated::gotFinish(); ++globals::cycle) {
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
  while(!Verilated::gotFinish() && (globals::cycle < max_cycle) && (insns_retired < max_icnt)) {
    contextp->timeInc(1);
    tb->clk = 1;
    tb->eval();

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
      execSparc(ss);
      ++n_checks;
      last_check = 0;
      last_match_pc = rpc;
      if(ss->brk) {
	break;
      }
    }
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
	std::cout << "rtl registers:\n";
	dump_regs(s);
	break;
      }
    }

    ++last_retire;
    if(last_retire > (1U<<16) && not(tb->in_flush_mode)) {
      std::cerr << "no retire in " << last_retire << " cycles, last retired "
		<< std::hex << last_retired_pc << std::dec
		<< " " << getAsmString(get_insn(last_retired_pc, s), last_retired_pc)
		<< "\ncore state " << static_cast<int>(tb->core_state) << "\n";
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
      if(tb->mem_req_opcode == 4) { /* load line */
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
    out << "n_mispredicts = " << n_mispredicts
	<<  ", cycles = " << globals::cycle
	<< ", insns = " << insns_retired
	<< ", n_checks = " << n_checks
	<< "\n";
    out << static_cast<double>(insns_retired) / globals::cycle << " insn per cycle\n";
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
  

    out << "l1d cache hits = " << tb->l1d_cache_hits << "\n";
    out << "l1d cache accesses = " << tb->l1d_cache_accesses << "\n";
    out << "l1d hit rate = "
	      << 100.0 *(static_cast<double>(tb->l1d_cache_hits) / tb->l1d_cache_accesses)
	      << "\n";
    out << "l1i cache hits = " << tb->l1i_cache_hits << "\n";
    out << "l1i cache accesses = " << tb->l1i_cache_accesses << "\n";
    out << "l1i hit rate = "
	      << 100.0 *(static_cast<double>(tb->l1i_cache_hits) / tb->l1i_cache_accesses)
	      << "\n";

    out << "l2 cache hits = " << tb->l2_cache_hits << "\n";
    out << "l2 cache accesses = " << tb->l2_cache_accesses << "\n";


    out << "branch mispredict rate = "
	      << (static_cast<double>(n_mispredicts)/n_branches)*100.0
	      << "\n";

    out << "mispredicts per kiloinsn = "
	      << (static_cast<double>(n_mispredicts) / insns_retired) * 1000.0
	      << "\n";
    out << n_flush_cycles << " cycles spent flushing caches\n";
    out << n_loads << " cache line loads\n";
    out << n_stores << " cache line stores\n";
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
	   << getAsmString(get_insn(pc, s), pc) << ","
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
