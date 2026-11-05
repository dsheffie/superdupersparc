# superdupersparc: r9999 -> SPARC V8

Goal: turn the r9999 OoO MIPS core into a SPARC V8 core, reusing mechanisms that
already work in r9999 wherever the ISA semantics line up. Golden model = a new
SPARC V8 ISS in interpret.cc, co-simulated against the RTL just as the MIPS ISS
is today.

## 1. What maps cleanly onto existing r9999 machinery

| SPARC V8 feature | r9999 mechanism to reuse |
|---|---|
| Big-endian, 32-bit | `BIG_ENDIAN`, `LG_M_WIDTH` knob (5 instead of 6) |
| Delay slots | MIPS delay slots (`has_delay_slot`, `in_delay_slot`) |
| Annul bit, conditional branch (`b<cc>,a`: annul if not taken) | MIPS branch-likely (`has_nullifying_delay_slot`) |
| `ba,a` / `bn,a` (always annul) | front end skips the slot: a jump/fallthrough with no delay slot |
| icc (N,Z,V,C), renamed | FCR (FP cond-code) rename: small separate PRF, `fcr_dst/fcr_src` |
| Y register, renamed | HILO rename (`hilo_dst/hilo_src`) |
| WRPSR / WRWIM / WRTBR / RETT (change CWP/S/ET) | `serializing_op` (as MTC0 does) |
| Window overflow/underflow, illegal insn, priv insn | decode-time fault: `op -> II` |
| Interrupts (PIL, 15 levels) | `IRQ` uop injection |
| FP doubles = even/odd single pairs | FR=0 (o32) FP register model, already in decode |
| fcc + `fbfcc` | FCC rename + BC1T/F, but fcc is 2 bits (=,<,>,U) not 1 |

## 2. Register windows: the naive scheme (start here)

The flat architectural index is 8 bits:

```
r0..r7   (globals)  -> arch  0..7
r8..r31  (windowed) -> arch  8 + ((r - 8) + 16*CWP) mod (16*NWINDOWS)
```

The `ins` of window CWP-1 alias the `outs` of window CWP, so SAVE/RESTORE just
move CWP and copy nothing. With NWINDOWS=8 there are 8 + 128 = **136
architectural regs**, all living in the unified PRF.

* **RAT:** grows from 32 to 136 entries (alloc and retire copies), indexed by the
  8-bit specifier. The flush-time copy `r_alloc_rat <= r_retire_rat` is unchanged.
* **PRF:** must hold at least 136 + the in-flight destinations, so
  `LG_PRF_ENTRIES` 7 -> 8 (256). **That is 256x32 = the same bit count as
  today's 128x64**, so the 64->32 shrink pays for the windows in the PRF. The
  cost moves into the 136:1 RAT read muxes and a 256-entry free list.
* **CWP at decode:** keep a speculative `r_dec_cwp` that SAVE (-1) and RESTORE
  (+1) update at decode. Recovery copies the retire CWP, alongside the RAT
  copy. Decode computes the arch index using the CWP *before* the op for the
  sources and the CWP *after* the op for SAVE/RESTORE's rd.
* **WIM check at decode:** WRWIM serializes, so WIM is stable at decode. A SAVE
  or RESTORE that hits a WIM bit becomes `II` (window_overflow/underflow trap).
* **Fewer windows** (NWINDOWS is implementation-defined, 2..32) shrink the RAT
  linearly. An NWINDOWS sweep is a cheap knob once this works.

## 3. Genuinely new problems (no r9999 precedent)

1. **Trap entry writes GPRs.** The trap writes `%l1=PC` and `%l2=nPC` in the
   *new* window, then CWP-1, S=1, ET=0, and jumps to `TBR|tt<<4`. MIPS only
   wrote CP0. Proposal: the trap path drains anyway, so write the two values
   straight into the PRF at `retire_rat[idx(l1/l2, CWP-1)]` using an idle
   writeback port while the core is quiescent.
2. **Two destinations.** `ldd` writes rd and rd+1; `umul`/`smul` write rd and Y;
   `addcc` and friends write rd and icc. icc and Y ride their own small rename
   files (§1), so only `ldd` needs two *integer* destinations. **Done, no
   cracking:** `ldd` allocates two pregs (one ldd per alloc cycle) and parks rd+1
   for one cycle on the single L1D writeback path; `std` reads rd then rd+1 over
   two cycles on the store-data port. A multiply writes rd on the ALU writeback
   (the slot `r_wb_bitvec` already reserves) and Y on the HILO port in the same
   cycle; the ROB has its own `hilo_pdst`/`old_hilo_pdst`, so one op holds both.
3. **DCTI couples** (a CTI in a delay slot). Compiled code essentially never
   produces them, **except `jmpl %l1; rett %l2`, the trap-return idiom**.
   Proposal: fuse `jmpl; rett` at decode into one serializing RETT uop with two
   targets. Every other couple is implemented in the ISS but traps in the RTL
   (documented non-compliance), unless we decide otherwise.
4. **`mulscc`** reads rs1, rs2, Y and icc, and writes rd, Y and icc. It is legacy
   (V7 multiply step, not emitted for `-mcpu=v8`) but is in the V8 ISA, and the
   32-bit Linux software multiply uses it. **Done** as an ordinary ALU op: rs1 and
   rs2 on the two integer read ports, icc from `r_prf_icc` (a 4-bit read via the
   srcC pointer), Y from HILO; rd+icc on the ALU port, Y on the HILO port.
5. **MMU.** The SPARC Reference MMU (SRMMU) uses a hardware table walk (3-level,
   contexts, ASI-mapped control registers). That is nothing like the MIPS
   software-refilled TLB/ITLB, so the MIPS TLB, ITLB and CP0 all go. Phase 1 runs
   with the MMU off (VA=PA). The SRMMU is its own phase.
6. **ASIs.** `lda`/`sta` and friends carry an 8-bit ASI (MMU regs, cache flush,
   bypass). `ldstub` and `swap` replace LL/SC as the atomics.
7. **Platform.** henry is an SGI IP22 SoC and is MIPS-only. An OS boot needs a
   SPARC platform (decision needed, §6).

## 4. Area: 64b -> 32b

r9999 is mostly parameterized on `M_WIDTH` (exec.sv has 124 uses), but there
are still literal `[63:` slices (exec 31, l1d 52, rob.vh 12, l1i 11, core 8) to
clean up. What shrinks: the int PRF data width, bypass network, ALU, shifter,
the integer multiplier (64x64 -> 32x32, so DSPs drop ~4x) and divider (64 ->
32 iterations, and half the latency), the ROB/ring data fields, and LSU
align/merge. What goes away: the JTLB plus the ITLB, CP0, and the 64-bit-mode
gating. What does **not** shrink: the **FPU** (V8 has doubles), the caches, and
the L2. See the measured breakdown below.

**Measured baseline** (henry impl_11 routed dcp, `report_utilization -hierarchical`):

| block | LUT | FF | DSP | fate under V8 |
|---|---|---|---|---|
| core_l1d_l1i total | 47821 | 26323 | 43 | |
| exec (own logic) | 11500 | 5289 | 0 | int datapath halves; FP part stays |
| intprf (rf4r2w 128x64) | 4397 | 256 | 0 | 256x32 = same bits, roughly flat |
| fpprf | 4430 | 256 | 0 | stays |
| fpu0 | 1205 | 830 | 9 | stays |
| divider | 1531 | 445 | 0 | ~halves |
| int multiplier | n/a | n/a | ~34 | 64x64 -> 32x32: ~4-6 DSP |
| core (rename/ROB/sched) | 6212 | 4813 | 0 | RAT 32 -> 136: +~1.7K LUT, +~1.7K FF |
| dtlb (JTLB) | 2999 | 4752 | 0 | **removed** |
| itlb | 3279 | 4263 | 0 | **removed** |
| l1d / l1i rest | ~8600 | ~4500 | 0 | modest shrink (load align/store merge) |

**Estimate** (unvalidated): −6.3K LUT/−9K FF from the TLBs, minus a few K LUT
back for an SRMMU TLB plus walker; −3..5K LUT from the 32-bit int datapath and
divider; +~2K LUT for the 136-entry RAT. **Net roughly −8..12K LUT (~20% of
the CPU), ~−8K FF, ~−30 DSP.** Measure for real once decode_sparc builds.

## 5. Phases

0. **Tooling.** A SPARC binutils/gcc (ld.lld 18 cannot link 32-bit SPARC; clang
   *can* compile `-mcpu=v8`). Golden reference: `qemu-sparc` (user-mode),
   single-step `-d cpu` traces.
1. **ISS** (interpret.cc): the full V8 integer ISA, windows, PSR/WIM/TBR/Y, the
   trap model, ASIs with the MMU off, ldstub/swap, then the FPU (FSR, fcc, FP
   traps with a depth-1 FQ). Plus a disassembler and an ELF32 BE loader (adapt
   loadelf). Validate against qemu-sparc with diff-able per-instruction traces.
2. **RTL integer core:** `LG_M_WIDTH=5`, new `decode_sparc.sv`, windowed rename
   (8-bit specifiers), icc/Y rename, annul, traps/PSR replace CP0, MMU off.
   Co-sim against the ISS (randgen ported to SPARC).
   * **decode_sparc.sv: written, not yet instantiated in core.sv.** Full V8 integer
     + FP decode to the `S_*` uops (uop.vh documents the conventions: operand 2 =
     srcB or the 32-bit immediate in `{jmp_imm, imm}`, store data in srcC, cond in
     srcC, `uop.asi` on every memory op). Decode-time traps leave as `II` with the
     trap type in `imm[7:0]`. `cwp`/`wim` in, `next_cwp` out (dec1 chains off dec0).
     `opcode_t` is now 9 bits; `LG_PRF_ENTRIES` is 8.
   * `make decode_test` checks it against the ISS: random instruction words in
     random S/ET/EF/CWP/WIM states; the decode traps, the registers/Y/icc/fcc
     the ISS writes, sources and immediates must agree (all 17 seeded decoder
     mutations caught).
   * Open, for the core wiring: **ldd/std** are one uop naming the even register
     (crack into two); **ba,a / bn,a** are branches with no delay slot (r9999 has
     always had one); **jmpl;rett** fusion; icc and fcc share the FCR rename as one
     `{fcc, icc}` register, so every cc writer merges (fcr_src + fcr_dst); FP
     double pairs are big-endian (even = high word) unlike MIPS FR=0.
3. **FPU:** adapt to SPARC encodings, the 2-bit fcc and FSR.
4. **SRMMU + platform** for an OS boot. Target platform = **sun4m** (SPARCstation
   5/10/20 class: what NeXTSTEP/SPARC ran on, and what Linux sun4m and
   QEMU+OpenBIOS support). End goal NeXTSTEP; Linux first.
   * **CPU module = TI SuperSPARC (Viking), MBus mode (no SuperCache/MXCC).**
     PSR impl/ver 4/1, MCR impl/ver 0/0 with MMODE (bit 11) set, so Linux
     `srmmu.c` runs `init_viking()` with the plain non-MXCC "TI Viking" code.
     Viking cache/tag ASIs (0x10-0x14, 0x18, 0x36-0x3f) read 0 and drop
     writes. qemu's SS-10/SS-20 machines are the matching reference.
   * ISS SRMMU: done (walks every access, no TLB). sparc_tests/mmu.c is the
     directed test.
   * **Firmware = real Sun OBP 2.25 (ss10-20_v2.25r).** Reference machine:
     `qemu-system-sparc -M SS-20 -cpu TI-SuperSparc-40 -m 256 -vga none -nographic`
     (the CPU model exactly matches ours and reaches `ok`). ISS side:
     `sparc_iss --rom <rom> --nvram sparc_tests/ss20_nvram.bin` (NVRAM dumped
     from that qemu). `sparc_tests/obp_diff.sh` diffs the executed-PC streams.
     Devices in sun4m.cc (behavior from qemu hw/, re-implemented): PROM, IOMMU,
     ECC, idreg, M48T08 NVRAM (fixed clock), ESCC, slavio misc, bus errors for
     unassigned PAs. **Next: counters/timers + interrupt controller.** Timers
     follow host time in qemu, so the reference must run with `-icount` and the
     ISS must derive time from its instruction count.
   * RTL walker: start from **rv64core `mmu.sv` + `tlb.sv`** (../rv64core). It is a
     shared L1I/L1D walker with A/D marking. Re-target it from Sv39 to the SRMMU
     3-level walk (context table -> 256-entry L1 -> 64-entry L2 -> 64-entry L3,
     PTD/PTE, R/M bits, 4K/256K/16M/4G mappings).
   * The sun4m ESCC serial is a Z85C30, the same chip as the IP22 SCC, so
     sgi_scc.cc / the henry SCC RTL may carry over. SCSI is an ESP (NCR53C9x),
     not the WD33C93.
