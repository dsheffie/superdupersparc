#ifndef __INTERPRET_HH__
#define __INTERPRET_HH__

#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <ostream>
#include <cassert>

#include "sparse_mem.hh"

class sun4m_t;

/* SPARC V8 golden ISS.
 *
 * Register windows use the SAME flat 8-bit architectural index the RTL rename
 * uses (SPARC_V8_PLAN.md section 2), so an ISS register dump lines up 1:1 with
 * the RTL retire RAT:
 *   r0..r7  (globals)   -> 0..7
 *   r8..r31 (windowed)  -> 8 + ((r - 8) + 16*CWP) mod (16*NWINDOWS)
 * ins(w) alias outs(w+1); SAVE decrements CWP, so the callee's ins are the
 * caller's outs. */
#ifndef NWINDOWS
#define NWINDOWS 8
#endif
#define N_ARCH_REGS (8 + 16*NWINDOWS)

static inline uint32_t widx(uint32_t cwp, uint32_t r) {
  if(r < 8) {
    return r;
  }
  return 8 + (((r - 8) + 16*cwp) % (16*NWINDOWS));
}

/* trap types (tt), V8 manual table 7-1 */
enum trap_type : uint32_t {
  TT_RESET          = 0x00,
  TT_IACCESS        = 0x01,
  TT_ILLEGAL        = 0x02,
  TT_PRIVILEGED     = 0x03,
  TT_FP_DISABLED    = 0x04,
  TT_WIN_OVERFLOW   = 0x05,
  TT_WIN_UNDERFLOW  = 0x06,
  TT_UNALIGNED      = 0x07,
  TT_FP_EXCEPTION   = 0x08,
  TT_DACCESS        = 0x09,
  TT_TAG_OVERFLOW   = 0x0a,
  TT_IACCESS_ERROR  = 0x21,
  TT_CP_DISABLED    = 0x24,
  TT_DACCESS_ERROR  = 0x29,
  TT_DIV_ZERO       = 0x2a,
  TT_INTERRUPT_BASE = 0x10,
  TT_TRAP_INSN_BASE = 0x80
};

/* FSR fields */
#define FSR_CEXC_SHIFT 0
#define FSR_AEXC_SHIFT 5
#define FSR_FCC_SHIFT  10
#define FSR_QNE        (1u<<13)
#define FSR_FTT_SHIFT  14
#define FSR_VER_SHIFT  17
#define FSR_NS         (1u<<22)
#define FSR_TEM_SHIFT  23
#define FSR_RD_SHIFT   30
/* writable by LDFSR: RD, TEM, NS, fcc, aexc, cexc (ver, ftt, qne are read-only) */
#define FSR_LDFSR_MASK 0xcfc00fffu
/* IEEE exception bits (cexc/aexc/TEM order) */
#define FEXC_NX 0x01
#define FEXC_DZ 0x02
#define FEXC_UF 0x04
#define FEXC_OF 0x08
#define FEXC_NV 0x10
/* ftt */
#define FTT_IEEE   1
#define FTT_UNIMP  3

/* superdupersparc presents as a TI SuperSPARC (Viking) sun4m module.  Linux
 * srmmu.c picks its MMU/cache code from PSR impl/ver plus the SRMMU control
 * register impl/ver: impl 4 / ver 1 with MCR impl/ver 0/0 => init_viking().
 * MMODE (MCR bit 11) set = MBus mode, i.e. no SuperCache/MXCC to model. */
#define PSR_IMPL_VER 0x41u
#define MCR_E      (1u<<0)    /* MMU enable */
#define MCR_NF     (1u<<1)    /* no-fault */
#define MCR_MMODE  (1u<<11)   /* Viking: MBus mode (no MXCC) */
#define MCR_BMODE  (1u<<13)   /* Viking: boot mode -- MMU-off insn fetches go to the PROM */
#define MCR_RESET  MCR_MMODE  /* impl/ver [31:24] = 0 */
/* SRMMU fault status register fields */
#define MFSR_OW        (1u<<0)
#define MFSR_FAV       (1u<<1)
#define MFSR_FT_SHIFT  2
#define MFSR_AT_SHIFT  5
#define MFSR_L_SHIFT   8
enum mmu_ft : uint32_t {
  FT_NONE = 0, FT_INVALID = 1, FT_PROTECTION = 2, FT_PRIVILEGE = 3, FT_TRANSLATION = 4,
  FT_BUS_ERROR = 5
};

class state_t {
public:
  uint32_t pc = 0;
  uint32_t npc = 4;
  uint32_t r[N_ARCH_REGS] = {0};
  /* PSR, held unpacked; get_psr()/set_psr() pack it */
  bool icc_n = false, icc_z = false, icc_v = false, icc_c = false;
  bool ef = false, s = true, ps = false, et = false;
  uint32_t pil = 0;
  uint32_t cwp = 0;
  uint32_t wim = 0;
  uint32_t tbr = 0;
  uint32_t y = 0;
  uint32_t asr[32] = {0};
  uint32_t f[32] = {0};
  uint32_t fsr = 0;
  /* one-deep FP queue (FPop traps are taken precisely here; FQ holds the trapping FPop) */
  uint32_t fq_addr = 0, fq_insn = 0;

  /* SRMMU (ASI 0x4 registers) */
  uint32_t mmu_ctrl = MCR_RESET;
  uint32_t mmu_ctpr = 0;     /* context table pointer: PA[35:6] in bits [31:2] */
  uint32_t mmu_ctx = 0;
  uint32_t mmu_fsr = 0;
  uint32_t mmu_far = 0;

  /* PA below ram_size is sparse_mem RAM; everything else is sun4m device space
   * (with no sun4m attached -- the user-mode tests -- all 4GB is RAM) */
  uint64_t ram_size = 1ULL << 32;
  sun4m_t *sun4m = nullptr;
  bool bus_error = false;    /* set by a physical access to an unassigned address */

  uint32_t irl = 0;          /* external interrupt request level, 0 = none */
  bool brk = false;          /* halted (exit syscall or error mode) */
  bool error_mode = false;
  int exit_code = 0;
  uint64_t icnt = 0;

  /* --user: start in user mode and emulate the Linux sparc32 syscall ABI (ta 0x10)
   * plus the kernel's window spill/fill, so the same static ELF runs under
   * qemu-sparc for comparison */
  bool user_emu = false;

  sparse_mem &mem;
  state_t(sparse_mem &m) : mem(m) {}
  ~state_t();

  uint32_t &gpr(uint32_t rr) {
    return r[widx(cwp, rr)];
  }
  uint32_t get_psr() const;
  void set_psr(uint32_t v);
};

std::ostream &operator<<(std::ostream &out, const state_t &s);

void initState(state_t *s);
void execSparc(state_t *s);

#endif
