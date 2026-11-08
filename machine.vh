`ifndef __machine_hdr__
`define __machine_hdr__

/* Retire-ring depth, log2 of TOTAL records (split across two banks).  MUST be
 * outside `ifdef VERILATOR -- core.sv uses it in the synthesized ring, so a
 * sim-only definition builds under Verilator and then fails sv2v with
 * "Undefined macro: LG_RTRACE_ENTRIES".
 * 8=256 (original), 14=16K (~57 BRAM36), 15=32K (~114 BRAM36, 93% of the part). */
`ifndef LG_RTRACE_ENTRIES
 /* 2048 entries.  Measured on three real captures: the whole evidence window (the
  * jalr that set ra, the epilogue reload, the faulting jr) spans ~20 retires, i.e.
  * 0.09% of the old 32K ring -- which cost ~125 BRAM tiles and forced 98.6% BRAM
  * occupancy.  Shallow-and-wide beats deep-and-narrow here. */
 `define LG_RTRACE_ENTRIES 11
`endif

// Debug trace infrastructure (ROB cycle stamps + HW trace buffer): sim-only.
// Synth/FPGA builds omit it -- the 256x384-bit trace RAM dominates build time.
`ifdef VERILATOR
 `define ENABLE_CYCLE_ACCOUNTING 1
`define ENABLE_TRACE_BUFFER 1
`endif

// On-silicon HW breakpoint/value-watchpoint in core.sv (freeze the pipe at an offending
// instruction; read GPRs/DRAM coherently over AXI).  OFF by default -- uncomment to
// re-enable the on-silicon watchpoint (see docs/methodology.md "Chasing a bug on silicon").
//`define ENABLE_DEBUG_WATCHPOINT 1  // OFF for verilator TLB-dump run
// Tiny 8-line L2 (congestion experiment; no real LUT win -- the FPU dominates).  OFF by default.
//`define TINY_DEBUG_L2 1

`define FPGA 1

//`define RESPECT_MAPPED 1

/* L1D request skid buffer: bypass the r_mem_q FIFO when it is empty and the L1D
 * can accept, driving the freshly-AGU'd request straight to the L1D the same
 * cycle (saves 1 cycle of load-to-use); falls back to enqueue ("skid") when the
 * L1D is busy.  Validated: load-to-use 3->2 cyc / +44% IPC on the dependent-load
 * microbench (tests/memlat), randgen 400/400 + FP co-sim 15/15 clean, henry synth
 * WNS +0.204 (worst path unchanged = ITLB CAM, not the bypass).  Comment out to
 * fall back to the plain enqueue-then-dequeue path. */

`define ENABLE_L1D_SKID 1

/* Pipeline performance knobs (PERF_TOPDOWN.md has the measurements).  All off by
 * default; area/timing cost not yet characterized.
 *   ENABLE_SCHED_BYPASS: when no ALU scheduler entry is ready, a ready uop-queue
 *     head issues directly instead of spending a cycle in the scheduler.
 *   ENABLE_UQ_DUAL_POP: move up to two uops/cycle from the uop queue into the
 *     ALU scheduler (allocation pushes two, the queue used to pop one). */
//`define ENABLE_SCHED_BYPASS 1

/* ENABLE_R10000: model an R10000 (IP28 / Indigo2) instead of the R4400 (Indy / IP22).
 * Implies the CPU's ISA and TLB: ENABLE_MIPS4 and a 64-entry JTLB (N_TLB_ENTRIES).
 * Address space: 44-bit virtual addresses (SEGBITS), so the 44-bit XContext layout
 * and a 31-bit TLB match; and TLB_PA_WIDTH 31, for IP28's 1 GB at
 * 0x20000000..0x5fffffff.  The IP28 IRIX kernel's K2 heap sets VA[43:40]
 * (0xc0000fc0...).  An R4400 must take an Address Error there, so this is a
 * CPU-model switch, not a free widening.  The C++ checker follows it (Makefile ->
 * -DENABLE_R10000). */
//`define ENABLE_R10000 1
/* keep the L1I coherent with core stores by making a line live in the L1I XOR the L1D
 * (the L2 drops it from the L1I before an L1D fill or uncached store, and probes it out
 * of the L1D before an L1I fill).  The SuperSPARC's I-cache is coherent with stores in
 * hardware and software relies on it: Linux's viking_flush_sig_insns is a no-op, and OBP
 * patches code with cached stores and runs it with no FLUSH.  Instructions already
 * fetched are not covered (FLUSH still refetches), nor is DMA. */
`define ENABLE_COHERENT_L1I 1

/* ENABLE_MIPS4: the MIPS IV (R5000/R10000) instructions; on by itself for an R4400
 * with MIPS IV bolted on (the cmov silicon builds), and implied by ENABLE_R10000.
 *
 * - Conditional moves: int movn/movz (SPECIAL 0x0b/0x0a), movt/movf (SPECIAL 0x01),
 *   and movt/movf/movz/movn.fmt (COP1 0x11-0x13).  Each is "two data sources + one
 *   condition bit": the old destination is a renamed source (no extra RAT/PRF port).
 *   The GPR-rt conditions read a 1-bit zero flag per int physical register, written
 *   with every int PRF write (a third ALU-scheduler ready bit; the in-order FP queue
 *   checks rt's inflight bit); the FCC conditions reuse the renamed FCC that BC1x reads.
 * - COP1X indexed FP loads/stores lwxc1/ldxc1/swxc1/sdxc1 (index register in srcC,
 *   a 2:1 mux in front of the AGU's offset) and prefx (a NOP).
 * - madd/msub/nmadd/nmsub.fmt: NOT fused -- the R10000 rounds the product, so the
 *   fpu runs multiply, then re-injects for the add (third FP read port for fr).
 * - recip/rsqrt.fmt (COP1 0x15/0x16) on the iterative divider (uni_divider).
 *
 * Already present WITHOUT this knob: pref (a NOP) and the eight FCCs (c.cond.fmt
 * cc / bc1t/f cc).  The C++ checker follows it (Makefile -> -DENABLE_MIPS4). */
//`define ENABLE_MIPS4 1
`ifdef ENABLE_R10000
 `ifndef ENABLE_MIPS4
  `define ENABLE_MIPS4 1
 `endif
`endif
//`define ENABLE_UQ_DUAL_POP 1

/* Register the L1D -> core response instead of driving it combinationally.
 *
 * rv64core does this unconditionally (l1d.sv: BOTH arms of its `ifdef FOUR_CYCLE_L1D
 * use r_core_mem_rsp*), r9999 did not.  Two reasons to follow it:
 *   TIMING: core_mem_rsp is a wide combinational output of the L1D that feeds the
 *   PRF write port and the load-data forward, and closed inside its own noise floor.
 *   CORRECTNESS: those consumers must AGREE.  If the path is marginal they can latch
 *   inconsistent values -- the forward flag set while the data is stale -- which is
 *   the 2026-09-02 silicon symptom (a consumer read a value its producer never
 *   wrote), and the kind of thing Verilator, having no delays, can never reproduce.
 * Costs one cycle of load-use latency.  r_core_mem_rsp/_valid are already maintained
 * in l1d.sv -- this only changes which one drives the output. */
`define REG_L1D_RSP 1

`define LG_M_WIDTH 5

`define BIG_ENDIAN 1

/* TINY_CORE: a deliberately small core (LSU 4, ALU scheduler 4, L1D 4KB, L1I 2x4KB,
 * L2 16KB; ROB stays 16) for fast synth/impl turnaround when core performance does not
 * matter -- SoC/device bring-up (e.g. Newport).  Sizes passed explicitly still win. */

/* ALU int matrix scheduler: 4 entries (LG=2), downsized from 8 (LG=3).  The O(N^2)
 * wakeup/select was on the critical path, so 8->4 is a WNS win (timing margin vs
 * metastability) at a small IPC cost -- kept per functional>IPC.  Bump to 3 for full IPC. */
`ifdef TINY_CORE
 `define LG_INT_SCHED_ENTRIES 2
`else
 `define LG_INT_SCHED_ENTRIES 3
`endif
/* usable ALU scheduler entries, at most 1 << LG_INT_SCHED_ENTRIES (e.g. 12 of 16);
 * the top entries are never allocated and synthesis prunes them, as for the LSU.
 * 4 of 8 (2026-11): OOC ZU3EG -843 LUTs and +0.29 ns WNS vs 6 (with LSU 6), for
 * no Dhrystone loss and -0.4% csmith IPC. */
`ifndef INT_SCHED_ENTRIES
 `define INT_SCHED_ENTRIES 4
`endif

//PHT: the PC-indexed bimodal under the mini-TAGE tagged tables
`ifdef FORMAL
 `define LG_PHT_SZ 2
`else
 `define LG_PHT_SZ 14
`endif

/* Mini-TAGE: the PHT is a PC-indexed bimodal (one entry per 16B fetch line, a 2b
 * counter per slot) plus two tagged tables (T1: 16b history, T2: 48b) of 2^LG_TAGE_SZ
 * per-fetch-line entries {valid, tag, slot, 3b ctr, 2b useful}, each indexed by line
 * pc ^ folded global history; the longest hit overrides the bimodal for the one slot
 * its entry was allocated to.  Single-cycle lookup; update at retire from fetch-time
 * metadata held in the front-end bpu table.  The folds in l1i.sv are written for
 * exactly these widths. */
`define GBL_HIST_LEN 48
`define LG_TAGE_SZ 10
`define TAGE_TAG_W 9

/* branch-predictor update state stays in the front end: each fetch group's PHT index
 * is written to a 2^LG_BPU_TBL_SZ-entry table in l1i, and only that table index rides
 * through decode/ROB to retire (rv64core 291b0cb).  64 entries >> the ~30 insns that
 * can be in flight (FQ 8 + DQ 4 + ROB 16 + stage regs), so a live entry never wraps. */
`define LG_BPU_TBL_SZ 6

//page size
`define LG_PG_SZ 12

/* 512: the RF is banked (core.sv: ALU results allocate only from the low half,
 * loads only from the high half), and any one bank must be able to hold all
 * 136 SPARC windowed arch registers (8 globals + 16*NWINDOWS) plus in-flight
 * destinations.  At 256 (128 per bank) ALU writes migrated the arch registers
 * into the ALU bank until it was full: no ALU op could allocate, with half the
 * MEM bank free (the OpenBIOS console loop hung after a few hundred window
 * traps).  512x32 is twice r9999's 128x64 bit count. */
`define LG_PRF_ENTRIES 8

/* FP physical registers: their own size, not the integer PRF's.  SPARC
 * renames the 16 64-bit FP pairs (only the even arch indices, decode_sparc.sv
 * fidx), and allocation is banked by producer (fpu arith -> low half, memory ->
 * high half), so each half must hold all 16 arch pairs plus every in-flight FP
 * destination (at most one per ROB entry): (1 << LG_FP_PRF_ENTRIES) / 2 >=
 * 16 + ROB_ENTRIES.  Sizing it at the integer PRF's 512 cost ~20K LUTs (the
 * register file and its two 512-wide free-list searches). */
`define LG_FP_PRF_ENTRIES 6

/* Register windows resident in the integer PRF.  A window group is 16 flat arch
 * registers (window g's outs and locals = window g-1's ins); window w reads
 * groups w and w+1, a save three.  At most WIN_RESIDENT_GROUPS groups (plus the
 * globals) hold physical registers; the rest live in exec.sv's 1R/1W backing
 * RF.  An instruction that names an absent group becomes a WMISS (core.sv dq
 * push), taken at the ROB head like a fault: spill the farthest resident group,
 * fill the missing ones, restart at it.  8 = every group may be resident
 * (misses only on first use).  Each PRF half must hold 16 * groups + 16 arch
 * registers plus the in-flight destinations. */
`define WIN_RESIDENT_GROUPS 5

/* SPARC register windows (power of two: the flat arch index wraps mod 16*NWINDOWS) */
`define LG_NWINDOWS 3
`define NWINDOWS (1 << `LG_NWINDOWS)
`define N_INT_ARCH_REGS (8 + 16 * `NWINDOWS)


/* SPARC icc has its own rename (core.sv / exec.sv r_icc_prf), like Y on the
 * HILO one: 16 versions of {N, Z, V, C}.  It used to ride in the integer PRF
 * beside each icc writer's value, which made a register ownable by both a GPR
 * mapping and the flags RAT (reference counts on every physical register). */
`define LG_ICC_PRF_ENTRIES 4

/* SPARC Y rides the MIPS HILO rename (its own register file, wakeup and
 * forwarding): every umul/smul writes it, so 16 versions, not MIPS's 4 */
`define LG_HILO_PRF_ENTRIES 4

//queue between decode and alloc
`define LG_DQ_ENTRIES 2

//queue between fetch and decode
`define LG_FQ_ENTRIES 3

//rob size
`ifdef FORMAL
 `define LG_ROB_ENTRIES 2
`else
 `define LG_ROB_ENTRIES 4
`endif

/* ROB_ENTRIES may be any EVEN count in (2^(LG-1), 2^LG] (even: two-wide
 * alloc/retire banks the ROB by ptr[0]); defaults to 2^LG_ROB_ENTRIES */
`ifndef ROB_ENTRIES
 `define ROB_ENTRIES (1<<`LG_ROB_ENTRIES)
`endif

`define LG_RET_STACK_ENTRIES 2

/* non-uop queue */
`define LG_UQ_ENTRIES 3
/* mem uop queue */
`define LG_MEM_UQ_ENTRIES 2
/* LSU (exec.sv): age-ordered pool fed by the in-order mem uop queue.  Simple
 * loads are held until answered, plain stores until retired and written; slots
 * also index the l1d-side store buffer */
`ifdef TINY_CORE
 `define LG_MEM_SCHED_ENTRIES 2
`else
 `define LG_MEM_SCHED_ENTRIES 3
`endif
/* usable LSU slots, at most 1 << LG_MEM_SCHED_ENTRIES.  A smaller count (e.g. 12
 * of 16) never allocates the top slots, so their valid bits are constant 0 and
 * synthesis prunes their state in exec and the l1d store buffer */
/* 6 of 8 (2026-11): with ALU 4, OOC -2.5K LUTs vs 8/8 at -3.3% Dhrystone and -1.0%
 * csmith IPC; 4 LSU slots cost Dhrystone 18.5% (store-buffer bound). */
`ifndef MEM_SCHED_ENTRIES
 `ifdef TINY_CORE
  `define MEM_SCHED_ENTRIES (1 << `LG_MEM_SCHED_ENTRIES)
 `else
  `define MEM_SCHED_ENTRIES 6
 `endif
`endif
/* mem data queue */
`define LG_MEM_DQ_ENTRIES 2
/* mem uop queue */
`define LG_MQ_ENTRIES 2

/* mem retry queue */
`define LG_MRQ_ENTRIES 3

`define MUL_LAT 3

/* FP unit: fixed-latency pipelined add/sub/mul/compare (mirrors mipscore fpu.sv).
 * FP completes on its own ROB port (complete_bundle_2), so no shared wb-bitvec. */
`define FPU_LAT 4
`define FP_MAX_LAT `FPU_LAT
/* renamed FP condition-code (FCR) register file */
`define LG_FCR_PRF_ENTRIES 2
/* FP issue queue (in-order, mirrors the int UQ) */
`define LG_FP_UQ_ENTRIES 3

/* nu_divider worst case = IDLE -> CLZ -> DIVIDE(M_WIDTH) -> PACK -> WAIT: one
 * cycle longer than the old fixed divider (the extra CLZ state), so the writeback
 * reservation is M_WIDTH+2 (== rv64core DIV64_LAT=66 for M_WIDTH=64).  Must be
 * >= the worst-case latency or the deadlock backstop under-reserves. */
`define DIV32_LAT (`M_WIDTH+2)

`define MAX_LAT (`DIV32_LAT)


// cacheline length (in bytes)
/* L1D_STATE_PROFILE: per-state cycle occupancy of the L1D FSM, dumped every
 * L1D_PROFILE_PERIOD cycles.  Off by default -- pure instrumentation. */
//`define L1D_STATE_PROFILE 1   /* uncomment to dump L1D FSM occupancy */
`ifndef L1D_PROFILE_PERIOD
 `define L1D_PROFILE_PERIOD 100000000
`endif

`define LG_L1D_CL_LEN 4

//number of sets in direct mapped cache
/* GEOMETRY OVERRIDE: each size below is wrapped in `ifndef, so ANY of them can be set
 * straight from the build command line and wins over every branch here:
 *     SV2V_DEFINES="... LG_L2_NUM_SETS=8"      ./gen_mipscore.sh     (FPGA)
 *     make VFLAGS_EXTRA=+define+LG_L2_NUM_SETS=8                     (verilator)
 * A size is a NUMBER, so pass the number -- this replaces the per-size boolean knobs
 * (ENABLE_L1_4K, ENABLE_L2_4K, ...) that were accreting one `elsif per experiment,
 * and the chosen value is echoed into the build log so the artifact records what it
 * actually is.  The branches below remain the DEFAULTS when nothing is passed. */
`ifndef LG_L1D_NUM_SETS
`ifdef FORMAL
 `define LG_L1D_NUM_SETS 2
`elsif TINY_CORE
 `define LG_L1D_NUM_SETS 8    // 256 sets x 16B = 4KB (one page: no colours)
`else
 `define LG_L1D_NUM_SETS 10   // 1024 sets x 16B = 16KB
`endif
`endif
/* L1D set colour bits: the index bits above the page offset (2 at 16KB, 4 at 64KB);
 * the inclusive L2 records the colour each line lives at (pidx).  1 when the L1D
 * fits in a page (no colours; the bit is then always 0). */
`define L1D_N_COLOUR (((`LG_L1D_CL_LEN + `LG_L1D_NUM_SETS) > `LG_PG_SZ) ? (`LG_L1D_CL_LEN + `LG_L1D_NUM_SETS - `LG_PG_SZ) : 1)


/* L1I: 2 ways of LG_L1I_NUM_SETS sets (2 x 16KB = 32KB with the default 1024 sets).
 * 16KB per way keeps the index inside the VIPT alias bits the direct-mapped L1I already
 * had.  1-bit/set LRU. */
`ifndef LG_L1I_NUM_SETS
`ifdef FORMAL
 `define LG_L1I_NUM_SETS 2
`elsif TINY_CORE
 `define LG_L1I_NUM_SETS 8    // 2 x 4KB
`else
 `define LG_L1I_NUM_SETS 10   // 1024 sets x 16B = 16KB (4KB direct-mapped thrashed dhry_henny code -> L1I conflict misses)
`endif
`endif


// EXPERIMENT: shrink the L2 to 4 lines (LG_L2_NUM_SETS=2).  Keeps the correct
// write-back path but a 4-set direct-mapped L2 aliases constantly, so a
// speculatively-filled line is evicted almost immediately and can't survive as a
// stale reservoir to a later read (the R10000-class non-coherent-DMA bug).
// Comment out to restore the full 128KB L2.
//`define ENABLE_L2_TINY 1
// EXPERIMENT: fully bypass the L2 as a cache (see l2.sv) -- data ops go straight
// to DRAM, L2 holds nothing.  Comment out to restore the write-back L2.
//`define ENABLE_L2_NOCACHE 1   // off by default on main; enable for the L2-bypass (non-coherent-DMA) workaround

`ifndef LG_L2_NUM_SETS
`ifdef FORMAL
 `define LG_L2_NUM_SETS 2
`elsif TINY_CORE
 `define LG_L2_NUM_SETS 10       /* 1024 lines x 16B = 16KB */
`elsif ENABLE_L2_TINY
 `define LG_L2_NUM_SETS 2        /* 4 lines x 16B = 64B -- effectively no retention */
`else
 `ifdef TINY_DEBUG_L2
  `define LG_L2_NUM_SETS 3
 `elsif BIG_SIM_L2
  `define LG_L2_NUM_SETS 16     /* 65536 lines x 16B = 1MB (sim-only; too big for FPGA BRAM) */
 `else
  `define LG_L2_NUM_SETS 13      /* 8192 lines x 16B = 128KB (restored for debug bit; deep trace lives in DRAM, not BRAM) */
 `endif
`endif
`endif



`define M_WIDTH (1 << `LG_M_WIDTH)

/* SPARC V8: the integer datapath (registers, ALU, PC, virtual addresses) is
 * M_WIDTH = 32.  Two things stay 64 bits wide:
 *   FP_WIDTH   an FP physical register holds a double (the FPU is 64-bit);
 *   MEM_WIDTH  the L1D data path (lddf/stdf move 64 bits in one access) and the
 *              ROB's result field, which carries FP results to retirement. */
`define FP_WIDTH 64

/* the int scheduler's third source (srcC) and the LSU's index operand: SPARC
 * needs both (icc readers take the flags register in srcC; reg+reg addressing).
 * They were the MIPS IV movn/movz and COP1X paths. */
`define ENABLE_INT_SRCC 1
`define MEM_WIDTH 64

/* the ROB's data field.  Retire and the trap logic read only its low M_WIDTH
 * bits: trap types, WMISS info, wrpsr/wrwim/wrtbr values, the fault VA, the
 * flush address.  The upper half (an ldd's high word, Y) and FP results (FP and
 * FCR state are renamed in their own PRFs) feed only the co-sim checker's retire
 * ports, so a synthesis build stores M_WIDTH and drops the FP completion write. */
`ifdef VERILATOR
 `define ROB_DATA_WIDTH `MEM_WIDTH
`else
 `define ROB_DATA_WIDTH `M_WIDTH
`endif

/* Physical address width: cache tags, the memory bus, the L2.  sun4m (SRMMU)
 * physical addresses are 36 bits, wider than a VA (M_WIDTH), so a memory request's
 * address field, which carries the VA and then the PA, is REQ_ADDR_WIDTH. */
`define PA_WIDTH 36
/* the sun4m boot PROM (Viking boot mode, MCR.BM: MMU-off fetches and ASI 8/9
 * loads read it at PROM_PA | va[18:0]; interpret.cc mmu_xlate) */
`define SUN4M_PROM_PA 36'hff0000000
/* sun4m memory space is PA[35:32] == 0; SBus (0xE) and on-board I/O + the boot
 * PROM (0xF) are device space */
`define SUN4M_MEM_PA(pa) ((pa) < `PA_WIDTH'(36'h100000000))
/* instruction fetch: memory space and the boot PROM (0xF_F000_0000 up, reads
 * have no side effects).  l1i.sv turns a fetch anywhere else into an
 * instruction-fetch fault instead of a bus read: the frontend runs down wrong
 * paths, and a wrong-path fetch during a Solaris 2.5.1 boot line-filled six TCX
 * lines (SBus slot 2, pa 0xe20200170..; the page passed the execute check), side
 * effects and all, desyncing the checker's device replay.  sun4m code runs from
 * RAM and the PROM only, so the fault is only ever squashed; if one retired, the
 * checker would flag it. */
`define SUN4M_IFETCH_PA(pa) (`SUN4M_MEM_PA(pa) || ((pa) >= `SUN4M_PROM_PA))
`define REQ_ADDR_WIDTH ((`PA_WIDTH > `M_WIDTH) ? `PA_WIDTH : `M_WIDTH)

/* SRMMU (SPARC V8 reference MMU) */
/* an SRMMU fault (L1D/L1I -> ROB -> the trap): the fault status register fields
 * the trap records (with the VA: a data fault's rides in the ROB entry's data, an
 * instruction fault's is its pc) */
typedef struct packed {
   logic       fault;
   logic [2:0] ft;
   logic [1:0] level;
   logic [2:0] at;   /* access type: {store, fetch, supervisor} */
} mmu_fault_t;

/* context number width: SuperSPARC implements 16 bits (the ISS masks to 0xffff) */
`define SRMMU_CTX_BITS 16
/* TLB entries (fully associative CAMs: the size is the FPGA timing knob) */
`define N_DTLB_ENTRIES 16
`define N_ITLB_ENTRIES 8

/* Per-structure block-RAM synthesis-attribute guards. Defined as the attribute =
 * force that array into block RAM (frees the LUT/FF fabric, which is the bottleneck
 * on Ultra96); define empty to let Vivado choose (FF/LUTRAM). These apply only to
 * plain INDEXED RAMs -- the associative TLB CAMs (l1i/l1d r_tlb) must stay FFs.
 *   RF_RAM_STYLE         -> the rf4r2w register-file banks (int/FP/hilo PRFs) */
/* rw_addr_collision: force Vivado to insert explicit read-during-write BYPASS
 * logic on the register-file banks.  Two reasons:
 *   1. ram_style="block" is NOT being honoured -- 4 read + 2 write ports exceed
 *      what a BRAM can do, so synthesis reports
 *        [Synth 8-6849] Infeasible attribute ram_style = "block" ... using LUTRAM
 *      and the banks are built from ~1678 LUTs of REPLICATED distributed RAM.
 *   2. The 2026-09-02 captures put the fault in a same-cycle read/write window on
 *      exactly these arrays, and today nothing but the operand mux covers that
 *      collision -- there is no RAM-level bypass.  AMD documents a bug class where
 *      synthesized hardware diverges from RTL simulation on RAM address collisions,
 *      with rw_addr_collision as the documented remedy (UG901 RAM_STYLE; see also
 *      beyond-circuits.com 2019/10 "RAM address conflicts and a Vivado synthesis
 *      bug").  That matches the shape of this bug: reproduces on silicon, will not
 *      reproduce in 1.24e9 Verilator cycles.
 * If the fault survives this, the whole RAM-collision class is eliminated rather
 * than merely suspected. */

`define RF_RAM_STYLE         (* ram_style = "block" *)

/* CP0 PRId (processor identification) values. imp field is bits [15:8];
 * the R4000 family shares imp=0x04 and is distinguished by the revision byte. */
`define PRID_R4000  32'h00000400   /* imp 0x04, rev 0x00 */
`define PRID_R4400  32'h00000440   /* imp 0x04, rev 0x40 */
`define PRID_R4600  32'h00002020   /* imp 0x20, rev 0x20 */
`define PRID_R10000 32'h00000900   /* imp 0x09, rev 0x00 */
/* IRIX /unix branches on PRId.IMP in `start`: imp 0x20 (R4600) takes the
 * Indy per-CPU init path; imp 0x04 (R4000/R4400) falls through to a different
 * cache/TLB-refill path that diverges before the KPTEBASE page-table backing
 * (MAME_QUESTIONS.md Q5). The old R4000/R4400 divergence turned out to be a
 * since-fixed TLB bug: R4400 now reaches the SCSI scan, and unlike R4600 (fixed
 * 32-byte L1 line) its Config DB bit lets IRIX manage 16-byte lines matching
 * r9999's LG_L1D_CL_LEN=4. Present R4400. */
/* Which MIPS cache-coherency attributes (xkphys VA[61:59], EntryLo C) cache.  The R4400
 * model caches only CCA 3 (cacheable noncoherent: what IRIX/Linux on an Indy use).  The
 * R10000's coherent CCAs 4 (exclusive) and 5 (exclusive-on-write) are cacheable too and,
 * with one CPU, behave as 3 -- and the IP28 kernel runs at xkphys CCA 5 (0xa8...): as
 * uncached it ran wholly uncached, half-aliased with its CCA 3 K2 mappings. */
`ifdef ENABLE_R10000
`define CCA_CACHED(c) (((c) == 3'd3) || ((c) == 3'd4) || ((c) == 3'd5))
`else
`define CCA_CACHED(c) ((c) == 3'd3)
`endif

/* sun4m RAM: an SS-20 holds up to 512 MB at physical 0.  Only RAM is cached
 * (l1d.sv): everything else -- the VSIMM slots, SBus and on-board devices, the
 * boot PROM -- is accessed uncached whatever the MMU says, so it reaches the bus
 * only from the ROB head.  (The out-of-order core issues cached misses
 * speculatively; a wrong-path line fill from a device would have side effects.) */
`define SUN4M_RAM_PA(pa) ((pa) < `PA_WIDTH'(36'h20000000))

`ifdef ENABLE_R10000
/* IP28: an R10000 rev 2.5 (0x0925, as IRIS and indysim report; the IP28 kernel
 * panics in r1nk_perf_architecture on an R4400 PRId), its FPU (FIR imp 0x09), and
 * the R10000 Config layout: IC = DC = 32 KB [31:29]/[28:26], BE [15], SB = 128-byte
 * secondary lines [13], SS = 0 (512 KB) [18:16], K0 = 2.  SS must be at least the
 * L2's real size: the kernel's index-op sweep (l2.sv MEM_BLK_IDX) covers what
 * Config claims. */
`define PRID_VALUE  32'h00000925
`define FIR_VALUE   32'h00000900
`define CONFIG_VALUE 32'h6c00a002
`else
`define PRID_VALUE  `PRID_R4400
`define FIR_VALUE   32'h00000500   /* imp 0x05 (R4000 FPU), rev 0 */
`define CONFIG_VALUE 32'h0002e483  /* see exec.sv CP0 'd16 */
`endif

`define LG_BTB_SZ 7
/* mini-ITTAGE: one tagged indirect-target table over the PC-indexed BTB (see l1i.sv) */
`define LG_ITT_SZ 8
`define ITT_TAG_W 9

/* Poison for a COLD/INVALID branch-target prediction.  MUST NOT be zero.
 *
 * The tagless BTB returns its "no entry" value straight into n_pc with no
 * validity check at the use site, so every cold indirect call speculatively
 * fetches it.  With that value = 0, a wild jump to 0 is AMBIGUOUS: it looks
 * identical to a genuine NULL function pointer in the program (which is what
 * the 2026-08-24 __split_vma oops looked like).  A distinct poison separates
 * the two in a crash dump: land here => the PREDICTOR produced it; land on 0
 * => it was real data.
 *
 * Kept in USER space and 4-byte aligned ON PURPOSE.  A kernel-space poison
 * would turn the routine cold-indirect speculative fetch from a TLB miss into
 * a privilege AdEL, changing the fault class in exactly the squash window
 * under investigation; an unaligned one may not fault cleanly at all (see the
 * Sail conformance gap on address-errors for out-of-range fetch). */
`define BTB_POISON_PC 32'hdeadcafc

typedef enum logic [5:0] {
   MEM_LB   = 6'd0,
   MEM_LBU  = 6'd1,
   MEM_LH   = 6'd2,
   MEM_LHU  = 6'd3,
   MEM_LW   = 6'd4,
   MEM_SB   = 6'd5,
   MEM_SH   = 6'd6,
   MEM_SW   = 6'd7,
   MEM_LDSTUB = 6'd8,  /* SPARC ldstub: old byte back, 0xff written (one l1d RMW) */
   MEM_SWAP = 6'd9,    /* SPARC swap: old word back, rd written (one l1d RMW) */
   MEM_LD   = 6'd14,
   MEM_SD   = 6'd15,
   MEM_INVL = 6'd24,   /* L2 line invalidate -- CACHE DMA-in drop; a dirty L2 line (or a dirty
                        * other-colour L1D copy found by the alias probe) is written back first */
   MEM_MOV  = 6'd25,   /* GPR<->FPR move: data carried in req.addr, echoed by L1D (no memory access) */
   MEM_WB   = 6'd26,   /* CACHE writeback-through: L2 hit -> flush line to DRAM + invalidate;
                        * L2 miss -> write the carried data straight to DRAM (so a CACHE
                        * D-writeback reaches memory instead of sitting dirty in L2) */
   MEM_CHWB    = 6'd27, /* CACHE D Hit-Writeback: mem-pipe (dtlb-translated) per-line op */
   MEM_CHWBINV = 6'd28, /* CACHE D Hit-Writeback-Invalidate (mem-pipe) */
   MEM_CHINV   = 6'd29, /* CACHE D Hit-Invalidate, no WB (DMA-in drop; mem-pipe) */
   MEM_SNOOP_INVL = 6'd30, /* DMA-coherence snoop: drop the L2 line, DISCARD even if dirty
                           * (a stale prior-owner dirty line must not clobber DMA data), and
                           * emit NO L1 response (the request came from the snoop FIFO, not an L1) */
   MEM_PGDROP = 6'd31, /* injected page drop (XPG_INV, after a DMA deposit): drop the L2 line
                        * WITHOUT writeback and ack the L1D; rsp_data[0] = the line was dirty
                        * (never expected: the pre-transfer XPG_WBINV cleaned the page) */
   /* R10000 secondary-cache ops (CA_BLK_*): one request for the 128-byte block at
    * PA & ~0x7f, sequenced by the L2.  L1 -> L2 only: the L2's memory-side opcode
    * stays 5 bits and never carries these. */
   MEM_BLK_WBINV = 6'd32,  /* Hit WB-Inv S (0x17) */
   MEM_BLK_INV   = 6'd33,  /* Hit Inv S (0x13): drop, no writeback */
   MEM_BLK_IDX   = 6'd34   /* Index WB-Inv S (0x03): the sets the address indexes */
} mem_op_t;

/* What a MIPS CACHE instruction does to this core's caches.  The encodings
 * (insn[20:16]) differ by CPU -- decode_mips.sv maps them with one table per CPU
 * model (r4400_cache_act / r10k_cache_act, chosen by ENABLE_R10000) -- and
 * everything past decode sees only these actions.  CA_I_LINE_INV..CA_D_LINE_INV
 * are the serializing retire-time actions the ROB carries (kept in the low two
 * bits); CA_NOP and the CA_D_HIT_* become a NOP uop and the CHINV/CHWBINV/CHWB
 * mem uops in decode.  CA_BLK_* are the R10000 secondary-cache ops: a 128-byte L2
 * block, inclusive of the L1s. */
typedef enum logic [3:0] {
   CA_NONE            = 4'd0,  /* not a CACHE op */
   CA_I_LINE_INV      = 4'd1,  /* invalidate the L1I set the EA indexes (both ways) */
   CA_D_LINE_WB       = 4'd2,  /* flush_cl: write back the L1D line at the EA */
   CA_D_LINE_INV      = 4'd3,  /* flush_cl: drop the L1D line at the EA, no writeback */
   CA_NOP             = 4'd4,  /* no cache effect (barrier, tag/data diagnostics, CDX) */
   CA_D_HIT_INV       = 4'd5,  /* CHINV mem uop: translated, drop the line */
   CA_D_HIT_WBINV     = 4'd6,  /* CHWBINV mem uop */
   CA_D_HIT_WB        = 4'd7,  /* CHWB mem uop */
   CA_BLK_INDEX_WBINV = 4'd8,  /* R10000 Index WB-Inv S: the 128 B block at the index */
   CA_BLK_HIT_INV     = 4'd9,  /* R10000 Hit Inv S: the 128 B block, translated */
   CA_BLK_HIT_WBINV   = 4'd10  /* R10000 Hit WB-Inv S */
} cache_act_t;

/* MIPS R10000 exception ordering 
* Cold Reset (highest priority)
* Soft Reset
* Nonmaskable Interrupt (NMI)‡
* Cache error –– Instruction cache*
* Cache error –– Data cache*
* Cache error –– Secondary cache*
* Cache error –– System interface*
* Address error –– Instruction fetch
* TLB refill –– Instruction fetch
* TLB invalid –– Instruction fetch
* Bus error –– Instruction fetch
* Integer overflow, 
* Trap, 
* System Call,
* Breakpoint, 
* Reserved Instruction, 
* Coprocessor Unusable
* Floating-Point Exception
* Address error –– Data access
* TLB refill –– Data access
* TLB invalid –– Data access
* TLB modified –– Data write
* Watch
* Bus error –– Data access
* Interrupt (lowest priority)
*/

typedef enum logic [4:0] {
 NO_ERROR = 5'd0,			   
 IC_ERROR = 5'd1,
 DC_ERROR = 5'd2,
 IA_ERROR = 5'd3, /* instruction address error */
 ITLB_REFILL_ERROR = 5'd4,
 ITLB_INVALID_ERROR = 5'd5,
 INSN_BUS_ERROR = 5'd6,
 INT_OVERFLOW = 5'd7,
 RESERVED_INSN = 5'd8,
 COPROC_UNUSABLE = 5'd9,
 FP_EXCEPTION = 5'd10,
 DA_ERROR = 5'd11, /* data address error */
 DTLB_REFILL_ERROR = 5'd12,
 DTLB_INVALID_ERROR = 5'd13,
 DTLB_MODIFIED_ERROR = 5'd14,
 DATA_BUS_ERROR	= 5'd15,
 BR_MISPREDICT = 5'd16			  
} exception_t;


function logic [31:0] bswap32(logic [31:0] in);
`ifdef BIG_ENDIAN
   return {in[7:0], in[15:8], in[23:16], in[31:24]};
`else
   return in;
`endif
endfunction

function logic [15:0] bswap16(logic [15:0] in);
`ifdef BIG_ENDIAN
   return {in[7:0], in[15:8]};
`else
   return in;
`endif
endfunction

function logic sext16(logic [15:0] in);
`ifdef BIG_ENDIAN
   return in[7];
`else
   return in[15];
`endif
endfunction

function logic [`M_WIDTH-1:0] sign_extend32(logic [31:0] in);
   logic [`M_WIDTH-1:0]	x;
   x = {   {(`M_WIDTH-32){in[31]}}, in};
   return x;
endfunction // is_mult

function logic [`M_WIDTH-1:0] zero_extend32(logic [31:0] in);
   logic [`M_WIDTH-1:0]	x;
   x = {   {(`M_WIDTH-32){1'b0}}, in};
   return x;
endfunction // is_mult

`endif
//`define GHOST_DEBUG 1  // TLB side-effect trace (spray bug diagnosis)
//`define CHOP_DEBUG 1  // l1d mem-pipe CACHE-op trace
