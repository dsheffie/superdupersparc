#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <random>
#include <set>
#include <string>
#include <boost/program_options.hpp>

#include "Vtb_decode_sparc.h"
#include "interpret.hh"
#include "sun4m.hh"
#include "disassemble.hh"
#include "globals.hh"

/* decode_sparc.sv unit test, with the ISS (interpret.cc) as the reference.
 *
 * Each case is a random instruction word in a random PSR.{S,ET,EF} / CWP / WIM
 * state.  The decoder is evaluated combinationally and the ISS executes the same
 * instruction once from a matching state, with every register seeded randomly:
 *   traps    the ISS took a decode-time trap (illegal, privileged, fp/cp
 *            disabled, window overflow/underflow) <=> the decoder emits II with
 *            that trap type;
 *   dst      the integer / FP registers the ISS changed are the decoder's dst
 *            (ldd's second register and a double's odd half are allowed too);
 *   sources  srcA/srcB/srcC and the immediate follow the V8 formats (the
 *            flat window index of interpret.hh widx), checked here directly;
 *   cwp      next_cwp is the ISS's CWP after a SAVE/RESTORE. */

namespace globals {
  bool enClockFuncts = false;
  uint64_t icountMIPS = 0;
  uint64_t cycle = 0;
  bool trace_retirement = false;
  bool trace_fp = false;
  bool report_syscalls = false;
  bool ip28 = false;
};

static const uint32_t PC = 0x1000;

static bool decode_tt(uint32_t tt) {
  switch(tt)
    {
    case TT_ILLEGAL:
    case TT_PRIVILEGED:
    case TT_FP_DISABLED:
    case TT_WIN_OVERFLOW:
    case TT_WIN_UNDERFLOW:
    case TT_CP_DISABLED:
      return true;
    default:
      return false;
    }
}

static inline uint32_t sext13(uint32_t insn) {
  return static_cast<uint32_t>(static_cast<int32_t>(insn << 19) >> 19);
}

static inline uint32_t fidx(uint32_t r, bool dbl) {
  return dbl ? (r & ~1u) : r;
}

int main(int argc, char **argv) {
  namespace po = boost::program_options;
  uint64_t n_cases = 1000000, seed = 1;
  uint32_t max_fail = 20;
  try {
    po::options_description desc("Options");
    desc.add_options()
      ("help", "print help")
      ("cases,n", po::value<uint64_t>(&n_cases), "random instructions to check")
      ("seed,s", po::value<uint64_t>(&seed), "rng seed")
      ("maxfail", po::value<uint32_t>(&max_fail), "stop after this many failures");
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);
    if(vm.count("help")) {
      std::cout << desc << "\n";
      return 1;
    }
  }
  catch(po::error &e) {
    std::cerr << "command line error : " << e.what() << "\n";
    return 1;
  }

  std::mt19937_64 rng(seed);
  Vtb_decode_sparc *tb = new Vtb_decode_sparc;
  sparse_mem mem;
  state_t *s = new state_t(mem);
  initState(s);
  /* a bypass-ASI access to an unassigned PA needs the sun4m bus (a bus error) */
  s->sun4m = new sun4m_t();
  initCapstone();

  uint64_t n_fail = 0, n_traps = 0, n_dst = 0, n_ii = 0;
  uint32_t tt_seen[256] = {0};
  for(uint64_t n = 0; (n < n_cases) and (n_fail < max_fail); n++) {
    uint32_t insn = static_cast<uint32_t>(rng());
    const uint32_t r = static_cast<uint32_t>(rng());
    /* uniform words almost never hit a defined opf: 3/4 of the FPops get one */
    if((insn >> 30) == 2 and (((insn >> 19) & 0x3e) == 0x34) and ((r >> 24) & 3) != 0) {
      static const uint32_t opfs[] = {
	0x001, 0x005, 0x009, 0x029, 0x02a, 0x041, 0x042, 0x045, 0x046, 0x049, 0x04a, 0x04d,
	0x04e, 0x069, 0x0c4, 0x0c8, 0x0c9, 0x0c6, 0x0d1, 0x0d2, 0x051, 0x052, 0x055, 0x056};
      insn = (insn & ~(0x1ffu << 5)) | (opfs[(r >> 26) % (sizeof(opfs) / sizeof(opfs[0]))] << 5);
    }
    const bool su = r & 1, et = (r >> 1) & 1, ef = (r >> 2) & 1;
    const uint32_t cwp = (r >> 3) % NWINDOWS;
    const uint32_t wim = (r >> 8) & ((1u << NWINDOWS) - 1);

    /* ISS: a fresh state for one instruction.  Register values stay small so
     * random addresses touch few pages of the sparse memory.  The register seed
     * is fixed per case so a second run differs only in icc / fcc. */
    const uint64_t reg_seed = rng();
    uint32_t r0[N_ARCH_REGS], f0[32], y0 = 0;
    auto run_iss = [&](uint32_t icc_in, uint32_t fcc_in) {
    std::mt19937_64 rrng(reg_seed);
    s->pc = PC;
    s->npc = PC + 4;
    s->s = su;
    s->ps = false;
    s->et = et;
    s->ef = ef;
    s->cwp = cwp;
    s->wim = wim;
    s->pil = 0;
    s->irl = 0;
    s->tbr = 0;
    s->brk = false;
    s->error_mode = false;
    s->last_tt = 0xffffffffu;
    s->mmu_ctrl = MCR_RESET;
    s->mmu_ctpr = s->mmu_ctx = s->mmu_fsr = s->mmu_far = 0;
    s->bus_error = false;
    for(uint32_t k = 0; k < N_ARCH_REGS; k++) {
      s->r[k] = (k == 0) ? 0 : (static_cast<uint32_t>(rrng()) & 0xfffcu);
    }
    for(uint32_t k = 0; k < 32; k++) {
      s->f[k] = static_cast<uint32_t>(rrng());
    }
    s->y = static_cast<uint32_t>(rrng());
    y0 = s->y;
    s->icc_n = (icc_in >> 16) & 1;
    s->icc_z = (icc_in >> 17) & 1;
    s->icc_v = (icc_in >> 18) & 1;
    s->icc_c = (icc_in >> 19) & 1;
    s->fsr = fcc_in << FSR_FCC_SHIFT;
    mem.set<uint32_t>(PC, __builtin_bswap32(insn));
    for(uint32_t k = 0; k < N_ARCH_REGS; k++) {
      r0[k] = s->r[k];
    }
    for(uint32_t k = 0; k < 32; k++) {
      f0[k] = s->f[k];
    }
    execSparc(s);
    };
    const uint32_t icc0 = r & (15u << 16), fcc0 = (r >> 20) & 3;
    const uint32_t op = insn >> 30, op3 = (insn >> 19) & 63, rd = (insn >> 25) & 31;
    const uint32_t rs1 = (insn >> 14) & 31, rs2 = insn & 31;
    const bool imm = (insn >> 13) & 1;

    /* reads of icc / fcc, by difference: rerun with a random nonzero set of icc
     * bits flipped (not always all four: mulscc reads only N ^ V), then
     * with fcc changed, and see whether anything the instruction produced moved.
     * Not for memory ops (swap / ldstub change memory between runs; none read
     * the condition codes). */
    struct out_t {
      uint32_t tt, pc, npc, y, icc, fcc, cwp, r[N_ARCH_REGS], f[32];
      bool operator!=(const out_t &o) const { return memcmp(this, &o, sizeof(*this)) != 0; }
    };
    auto snap = [&]() {
      out_t o;
      memset(&o, 0, sizeof(o));
      o.tt = s->last_tt;
      o.pc = s->pc;
      o.npc = s->npc;
      o.y = s->y;
      o.icc = (s->icc_n << 16) | (s->icc_z << 17) | (s->icc_v << 18) | (s->icc_c << 19);
      o.fcc = (s->fsr >> FSR_FCC_SHIFT) & 3;
      o.cwp = s->cwp;
      memcpy(o.r, s->r, sizeof(o.r));
      memcpy(o.f, s->f, sizeof(o.f));
      return o;
    };
    /* an op that leaves icc (fcc) alone passes the flipped value straight
     * through: equal outputs, or outputs apart by exactly the flip, are both
     * "did not read" for that field */
    bool reads_icc = false, reads_fcc = false;
    if(op != 3) {
      const uint32_t fflip = 1 + ((r >> 28) % 3);
      const uint32_t iflip = (1 + (reg_seed >> 60) % 15) << 16;
      run_iss(icc0 ^ iflip, fcc0);
      out_t a = snap();
      run_iss(icc0, fcc0 ^ fflip);
      out_t b = snap();
      run_iss(icc0, fcc0);
      const out_t o = snap();
      if(a.icc == (o.icc ^ iflip)) {
	a.icc = o.icc;
      }
      if(b.fcc == (o.fcc ^ fflip)) {
	b.fcc = o.fcc;
      }
      reads_icc = (a != o);
      reads_fcc = (b != o);
    }
    else {
      run_iss(icc0, fcc0);
    }
    const bool trapped = (s->last_tt != 0xffffffffu);
    const uint32_t tt = s->last_tt;

    tb->s = su;
    tb->et = et;
    tb->ef = ef;
    tb->cwp = cwp;
    tb->wim = wim;
    tb->insn = insn;
    tb->eval();

    std::string why;
    auto fail = [&](const std::string &w) {
      if(why.empty()) {
	why = w;
      }
    };

    /* 1: decode-time traps */
    const bool iss_dec_trap = trapped and decode_tt(tt);
    /* WRPSR's CWP-range check is the ISS's illegal_instruction too, but it
     * depends on the operand: an execution-time trap */
    const bool wrpsr_cwp = trapped and (tt == TT_ILLEGAL) and tb->is_wrpsr;
    if(iss_dec_trap and not wrpsr_cwp) {
      ++n_traps;
      tt_seen[tt & 255]++;
      if(not tb->is_ii) {
	fail("ISS trapped at decode, decoder did not");
      }
      else if((tb->imm32 & 0xff) != tt) {
	fail("trap type differs");
      }
    }
    else if(tb->is_ii) {
      fail("decoder trapped, ISS did not (at decode)");
    }
    n_ii += tb->is_ii;

    /* 2: destinations, against what the ISS wrote */
    if(not trapped and not tb->is_ii) {
      std::set<uint32_t> ch, fch;
      for(uint32_t k = 0; k < N_ARCH_REGS; k++) {
	if(s->r[k] != r0[k]) {
	  ch.insert(k);
	}
      }
      for(uint32_t k = 0; k < 32; k++) {
	if(s->f[k] != f0[k]) {
	  fch.insert(k);
	}
      }
      for(uint32_t k : ch) {
	const bool ok = (tb->dst_valid and (k == tb->dst)) or (tb->dst2_valid and (k == tb->dst2));
	if(not ok) {
	  fail("ISS wrote r[" + std::to_string(k) + "], not the decoder's dst");
	}
      }
      for(uint32_t k : fch) {
	const bool ok = tb->fp_dst_valid and ((k == tb->dst) or (k == (tb->dst | 1u)));
	if(not ok) {
	  fail("ISS wrote f" + std::to_string(k) + ", not the decoder's fp dst");
	}
      }
      if(tb->dst_valid and tb->fp_dst_valid) {
	fail("int and fp dst both valid");
      }
      n_dst += not ch.empty();
      /* the renamed side registers: Y on HILO, icc in the dst register (flags
       * RAT), fcc on the FCR rename */
      const uint32_t icc1 = (s->icc_n << 16) | (s->icc_z << 17) | (s->icc_v << 18) | (s->icc_c << 19);
      if(s->y != y0 and not tb->hilo_dst_valid) {
	fail("ISS wrote Y, decoder has no Y dst");
      }
      if(icc1 != icc0 and not tb->flags_dst_valid) {
	fail("ISS wrote icc, decoder has no flags dst");
      }
      if(((s->fsr >> FSR_FCC_SHIFT) & 3) != fcc0 and not tb->fcr_dst_valid) {
	fail("ISS wrote fcc, decoder has no fcc dst");
      }
      if(reads_icc and not tb->flags_src_valid) {
	fail("result depends on icc, decoder has no flags src");
      }
      if(reads_fcc and not tb->fcr_src_valid) {
	fail("result depends on fcc, decoder has no fcc src");
      }
      if(tb->is_nop and (not ch.empty() or not fch.empty() or s->y != y0 or icc1 != icc0 or
			 ((s->fsr >> FSR_FCC_SHIFT) & 3) != fcc0)) {
	fail("decoder NOP, but the ISS changed state");
      }
      if(tb->is_nop and (tb->dst_valid or tb->fp_dst_valid or tb->hilo_dst_valid or tb->fcr_dst_valid or
			 tb->srcA_valid or tb->srcB_valid or tb->srcC_valid or tb->is_mem or
			 tb->fcr_src_valid or tb->hilo_src_valid or tb->flags_src_valid or
			 tb->flags_dst_valid)) {
	fail("NOP with operands");
      }
      if(tb->next_cwp != s->cwp and op == 2 and (op3 == 0x3c or op3 == 0x3d)) {
	fail("next_cwp differs from the ISS's CWP");
      }
    }
    /* icc rides in an integer dst register; its source is srcC, which outside
     * the stores (data) carries nothing else */
    /* std alone has a second data source: rd+1, its flat index srcB + 1 */
    if(tb->srcD_valid != (tb->is_std and not tb->is_ii) or
       (tb->srcD_valid and (not tb->srcB_valid or tb->srcD != tb->srcB + 1))) {
      fail("std second data register");
    }
    /* ldd alone has a second destination: rd+1, its flat index dst + 1 */
    if(tb->dst2_valid != (tb->is_ldd and not tb->is_ii) or
       (tb->dst2_valid and (not tb->dst_valid or tb->dst2 != tb->dst + 1))) {
      fail("ldd second destination");
    }
    if(tb->flags_dst_valid and not tb->dst_valid) {
      fail("flags dst without an int dst register");
    }
    if(tb->flags_src_valid != (tb->srcC_valid and not tb->is_mem)) {
      fail("flags src is not exactly the non-memory srcC");
    }
    if(tb->is_ii and (tb->flags_src_valid or tb->flags_dst_valid)) {
      fail("trap with flags operands");
    }
    if(not tb->is_ii and not (op == 2 and (op3 == 0x3c or op3 == 0x3d)) and tb->next_cwp != cwp) {
      fail("next_cwp moved for a non-window op");
    }

    /* 3: sources and immediates, by format */
    if(not tb->is_ii and not tb->is_nop) {
      const uint32_t w_rs1 = widx(cwp, rs1), w_rs2 = widx(cwp, rs2), w_rd = widx(cwp, rd);
      const bool op2_reg = not imm and (rs2 != 0);
      const uint32_t op2_imm = imm ? sext13(insn) : 0;
      if(op == 0) {
	const uint32_t op2 = (insn >> 22) & 7;
	if(op2 == 4) {
	  if(tb->srcA_valid or tb->srcB_valid or tb->srcC_valid or tb->imm32 != (insn << 10)) {
	    fail("sethi fields");
	  }
	}
	else {
	  const uint32_t cond = (insn >> 25) & 15;
	  const bool annul = (insn >> 29) & 1;
	  const uint32_t disp = static_cast<uint32_t>(static_cast<int32_t>(insn << 10) >> 10) << 2;
	  const bool bn_a = (cond == 0) and annul;
	  if(tb->srcA_valid or tb->srcB_valid or tb->cond != (bn_a ? 8 : cond) or
	     tb->imm32 != (bn_a ? 8 : disp)) {
	    fail("branch fields");
	  }
	  const bool slot = bn_a ? false : (cond == 8) ? not annul : true;
	  if(tb->has_delay_slot != slot or tb->has_nullifying_delay_slot != (annul and (cond & 7) != 0)) {
	    fail("branch delay slot / annul");
	  }
	  const bool reads = not bn_a and (cond & 7) != 0;
	  if(tb->flags_src_valid != (reads and op2 == 2) or tb->fcr_src_valid != (reads and op2 == 6)) {
	    fail("branch cc read");
	  }
	}
      }
      else if(op == 1) {
	if(tb->srcA_valid or tb->srcB_valid or not tb->dst_valid or tb->dst != widx(cwp, 15) or
	   tb->imm32 != (insn << 2) or not tb->has_delay_slot) {
	  fail("call fields");
	}
      }
      else if(op == 2 and (op3 == 0x34 or op3 == 0x35)) {
	const uint32_t opf = (insn >> 5) & 0x1ff;
	if(tb->srcA_valid or tb->srcB_valid or tb->srcC_valid or tb->dst_valid) {
	  fail("FPop with int operands");
	}
	/* the FPop shapes: {opf, unary, src double, dst double} */
	struct shape_t { uint32_t opf; bool unary, sd, dd; };
	static const shape_t shapes[] = {
	  {0x001, true, false, false}, {0x005, true, false, false}, {0x009, true, false, false},
	  {0x029, true, false, false}, {0x02a, true, true, true},
	  {0x041, false, false, false}, {0x042, false, true, true}, {0x045, false, false, false},
	  {0x046, false, true, true}, {0x049, false, false, false}, {0x04a, false, true, true},
	  {0x04d, false, false, false}, {0x04e, false, true, true}, {0x069, false, false, true},
	  {0x0c4, true, false, false}, {0x0c8, true, false, true}, {0x0c9, true, false, true},
	  {0x0c6, true, true, false}, {0x0d1, true, false, false}, {0x0d2, true, true, false},
	};
	if(op3 == 0x34) {
	  for(const shape_t &sh : shapes) {
	    if(sh.opf != opf) {
	      continue;
	    }
	    const uint32_t a = sh.unary ? fidx(rs2, sh.sd) : fidx(rs1, sh.sd);
	    if(not tb->fp_srcA_valid or tb->srcA != a or tb->fp_srcB_valid == sh.unary or
	       (not sh.unary and tb->srcB != fidx(rs2, sh.sd)) or
	       not tb->fp_dst_valid or tb->dst != fidx(rd, sh.dd)) {
	      fail("FPop1 operands");
	    }
	  }
	}
	else if(opf == 0x051 or opf == 0x052 or opf == 0x055 or opf == 0x056) {
	  const bool d = (opf & 3) == 2;
	  if(tb->srcA != fidx(rs1, d) or tb->srcB != fidx(rs2, d) or not tb->fp_srcA_valid or
	     not tb->fp_srcB_valid or not tb->fcr_dst_valid or (tb->imm32 & 1) != ((opf >> 2) & 1)) {
	    fail("fcmp operands");
	  }
	}
      }
      else if(op == 2 and op3 >= 0x28 and op3 <= 0x2b) {
	if(tb->srcA_valid or tb->srcB_valid) {
	  fail("rd state reg with sources");
	}
      }
      else {
	/* op=2 ALU/control and op=3 memory: rs1 + operand 2, which a memory op
	 * carries in srcC (the LSU's index slot; srcB is its store data) */
	const bool op2_valid = (op == 3) ? tb->srcC_valid : tb->srcB_valid;
	const uint32_t op2_ptr = (op == 3) ? tb->srcC : tb->srcB;
	if(not tb->srcA_valid or tb->srcA != w_rs1 or op2_valid != op2_reg or
	   (op2_reg and op2_ptr != w_rs2) or (not op2_reg and tb->imm32 != op2_imm)) {
	  fail("rs1 / operand 2");
	}
	if(op == 2 and op3 == 0x3a) {
	  const uint32_t cond = (insn >> 25) & 15;
	  if(tb->cond != cond or tb->flags_src_valid != ((cond & 7) != 0)) {
	    fail("ticc cond / cc read");
	  }
	}
	if(op == 3) {
	  const bool fp = (op3 & 0x20) != 0;
	  const uint32_t base = fp ? op3 : (op3 & 0xf);
	  const bool alt = not fp and (op3 & 0x10);
	  const bool int_data = not fp and (base == 0x4 or base == 0x5 or base == 0x6 or base == 0x7 or base == 0xf);
	  const bool fp_data = fp and (op3 == 0x24 or op3 == 0x27);
	  if(tb->srcB_valid != int_data or (int_data and tb->srcB != w_rd)) {
	    fail("store data register");
	  }
	  if(tb->fp_srcB_valid != fp_data or (fp_data and tb->srcB != fidx(rd, op3 == 0x27))) {
	    fail("fp store data register");
	  }
	  if(tb->fp_srcC_valid) {
	    fail("memory op with an fp srcC");
	  }
	  if(tb->asi != (alt ? ((insn >> 5) & 0xff) : (su ? 0xb : 0xa))) {
	    fail("asi");
	  }
	  if(not tb->is_mem) {
	    fail("memory op without is_mem");
	  }
	}
      }
    }

    if(not why.empty()) {
      ++n_fail;
      printf("FAIL %s: insn %08x (%s) s=%d et=%d ef=%d cwp=%u wim=%02x\n"
	     "     ISS %s tt=%02x; decoder op=%u ii=%d imm32=%08x A=%u/%d B=%u/%d C=%u/%d D=%u/%d fpD=%d next_cwp=%u\n",
	     why.c_str(), insn, getAsmString(insn, PC).c_str(), su, et, ef, cwp, wim,
	     trapped ? "trapped" : "ran", trapped ? tt : 0, tb->op, tb->is_ii, tb->imm32,
	     tb->srcA, tb->srcA_valid, tb->srcB, tb->srcB_valid, tb->srcC, tb->srcC_valid,
	     tb->dst, tb->dst_valid, tb->fp_dst_valid, tb->next_cwp);
    }
  }

  printf("%s: %lu cases, %lu decode traps (", n_fail ? "FAIL" : "PASS",
	 static_cast<unsigned long>(n_cases), static_cast<unsigned long>(n_traps));
  for(uint32_t t = 0; t < 256; t++) {
    if(tt_seen[t]) {
      printf(" %02x:%u", t, tt_seen[t]);
    }
  }
  printf(" ), %lu wrote a register, %lu decoder II\n", static_cast<unsigned long>(n_dst),
	 static_cast<unsigned long>(n_ii));
  tb->final();
  delete tb;
  stopCapstone();
  return n_fail ? 1 : 0;
}
