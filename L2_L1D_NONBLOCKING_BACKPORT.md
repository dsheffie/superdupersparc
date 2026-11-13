# Handoff: non-blocking L2 and L1D work, for a backport to r9999

Source: superdupersparc branch `l2-multimiss` (remote `superdupersparc`,
github.com/dsheffie/superdupersparc). r9999 is the same lineage: superdupersparc forked from
it, and `l2.sv`, `l1d.sv` and `core_l1d_l1i.sv` still share most of their structure.
Read each commit's diff alongside this note. The design reasoning is in the commit
messages and in the RTL comments at each change.

| commit | what | backport? |
|---|---|---|
| `eb5a64d` | Murphi model `formal/murphi/sdsparc_nb.m` (+ `run_sdnb_rumur.sh`, `neg_sdnb.sh`) | yes: copy it, the rules apply to r9999 as they are |
| `d4a08fd` | per-requester arbiter + response routing, L2 hit-under-miss (`L2_HIT_UNDER_MISS`), one L1D second-miss engine (`L1D_MULTI_MISS`) | yes |
| `2aff1e5` | SPARC page walker as a cached L2 requester; `sparc_tests/l2_bw` | walker: **no** (MIPS refills in software). `l2_bw`: port the idea |
| `10dfdd6` | `ooo_core --warmup N` (stats after N retired instructions) | yes, it's a `top.cc` change; checkpoint studies need it |
| `b7e77b8` | pipelined L2 hit path (`L2_PIPE`), combinational arbiter, N engines (`L1D_PF_ENGINES`), early engine requests | yes |

## The design in one page

**The protocol: Murphi first.** `sdsparc_nb.m` extends `r9999_nb.m` (P1–P6: one L2
transaction per set, credit-limited probes, one ordered L2→L1 path per L1, sideband acks,
probe acks carry the newest data, DMA completion after probes) with:
- a non-blocking L1D: several fills in flight, program-order completion from the miss-queue head;
- DRAM that completes in any order;
- posted writebacks;
- an optional eviction buffer.

New rules (header has the full text and the negative control for each):
- **N2:** one L1D fill per L1D set.
- **N3:** an eviction-buffer check, needed only with a separate eviction buffer.
- **N4:** DRAM same-line ordering.
- **N5:** DMA waits for posted writes.
- **N6:** an op completes after older same-line ops.
- **N7:** a probe needs a reply-path slot.
- **N8:** a DMA drop MARKS executed-unretired loads of the line, before its completion is visible. A marked load re-executes at retirement (Intel's MOnuke).

N1, a per-line interlock, is NOT needed.

dsheffie's scope:
- One DRAM transaction (`NDR=1`). Misses FROM the L2 aren't worth it; rv64core showed that.
- No separate eviction buffer (`EB_SEPARATE=0`).
- DMA snoops may serialize the L2 (`DMA_QUIESCE`). Snoop latency doesn't matter.

The pipelined L2 needs no model change. Its four RTL obligations, R1–R4, are in the header:
- **R1:** set interlock covering S1, S2, the parked fill and the deferred request.
- **R2:** a fill's response reaches the L1 before any later probe of the line, because the RTL's probes use separate wires.
- **R3:** a writeback hit writes in S2.
- **R4:** snoops wait for an empty pipe.

**Arbiter (`core_l1d_l1i.sv`).**
- Each requester has a source id: 0 L1D, 1 L1I, 2 MMU (SPARC only), 3.. the L1D's engines. The L2 carries the id with the request and returns it with the response (`l1_mem_req_src`/`l1_mem_rsp_src`, 3 bits), and the arbiter routes responses by it.
- One transaction outstanding per source (`r_out_*`).
- After `b7e77b8` the arbiter has no grant states. The offered request is picked combinationally from the pending ones, and `l1_mem_req_ack` is the L2's combinational `n_req_ack`, so a new request can go every cycle.
- Pitfall: with the old registered ack, an L2 that takes a request every cycle would take the same one twice.

**L2 hit-under-miss (`L2_HIT_UNDER_MISS`, `l2.sv`).**
- A clean refill parks its DRAM read in `r_fp_*`, which drive the DRAM port until the response.
- The L2 goes back to IDLE and keeps serving other sources' LW/SW to other sets.
- A second miss is deferred, once, in `r_def_*` and replayed after the fill.
- The fill installs from IDLE and re-enters CHECK through `WAIT_CLEAN_RELOAD`, as `CLEAN_RELOAD` would.
- Bugs we hit:
  - A stale `r_fp_done` dropped `mem_req` for a cycle on every park. The fix is `n_mem_req = !(r_fp && (r_fp_done || mem_rsp_valid))`.
  - `n_src` must be set only in the accept arms. A NACK retry keeps its own.
  - The "protocol busted" IDLE assertion must exempt `r_fp`.

**Pipelined L2 (`L2_PIPE`, `l2.sv` + `reg_ram1r1w.sv`).**
- The RAMs become `reg_ram1r1w`: `reg_ram1rw` timing (registered address, write lands a cycle later), but with separate read and write addresses.
- S0 is an IDLE arm that accepts a cacheable LW/SW without leaving IDLE. The read issues at `t_idx`, which in IDLE is already the offered request's set.
- S1 waits for the RAM. S2 compares, using the same conditions CHECK uses:
  - A load hit with no probe needed (`w_s2_probe`: any L1D presence at another colour, or any presence for an MMU or L1I request) and no L1I drop (`w_s2_idrop`) finishes there.
  - So does an L1D writeback hit.
  - A clean miss (victim invalid, or clean with no L1 copies) parks its fill directly from S2 (`t_p_park`).
  - Anything else goes to the existing state machine: straight from S2 (`t_ho_direct`) or through a 2-entry queue (`r_ho*`). The state machine runs it from `WAIT_FOR_RAM` as if just accepted.
- A writeback is answered in S2 whichever way it goes.
- The state machine leaves IDLE, or writes the RAMs in IDLE (the fill install), only when that can't collide with an S2 write. Timing argument and assertions are in the code.
- Flushes, snoops, retries, block ops, uncached and CACHE ops wait for the pipe to empty (the "drain" arm).

**L1D engines (`L1D_MULTI_MISS`, `L1D_PF_ENGINES`, `l1d.sv`).**
- Each engine is a PF_IDLE → (PF_CHECK) → PF_WAIT → PF_DATA FSM that fetches one line and installs it when the array write port is free. The queue head then just hits.
- An engine drops its line on any write to its set or a probe of its line (P3: a probe must not overtake it).
- N2 is kept by `pf_owns(idx)`. The queue head, the direct fill and new candidates all skip a set an engine owns.
- **Early request (`t_pf_early`, from rv64core `nu_l1d`'s `w_gen_early_req`).** When a cacheable simple load misses on port 2 and is pushed into the queue, an idle engine takes its line in the same cycle, in any state, using port 2's read of the set as the check. The guards are the ones `t_direct_fill_ok` uses.
- The older path still runs for loads that missed while every engine was busy: while the main miss waits (`INJECT_RELOAD`), the engine scans the queue and checks a candidate via port 1.
- Engine count is limited to 5 by the 3-bit source id. Going further is the `nu_l1d` way: one source plus a miss-queue-slot tag carried through the L2.

## Results (superdupersparc, for calibration; r9999 will differ)

`sparc_tests/l2_bw`: one 32-bit load per 16-byte line, cycles per line; the L2-resident band is 128–512KB.

| build | L2-resident | DRAM |
|---|---|---|
| start | 6.01 | 18.0 |
| + hit-under-miss + 1 engine | 5.51 | 18.0 |
| + `L2_PIPE` | 5.01 | 19.0 |
| + 3 engines | 3.01 | 17.5 |
| + early requests | 2.73 | 16.4 |
| + 5 engines | 2.04 | 16.0 |

CINT95, 80 checkpoints of 10M instructions at memlat 37:
- **The SPARC walker was the big win:** vortex +31%, li +26%, compress +10%, all from cached page walks.
- **The L2 and L1D work was within ±1% on CINT95** at 32-entry TLBs, because SPARC loads were throttled by DTLB misses before they reached the L1D. The DTLB took 20 misses per 1K instructions on go and compress, and the walker is serial.
- **A 64-entry DTLB gave go +3.7%, compress +2.5% and vortex +1.1%.**
- Warm-up (2M instructions) and 512-entry-TLB sweeps were still running at handoff. If you need them, they're under `/mnt/usb/dsheffie/c95ck/runs_wu/`.

r9999 has a 48-entry JTLB with software refill, so its TLB picture is different. Measure before concluding anything.

## Differences to handle in r9999

- **No source ids, no MMU requester.** Add `l1_mem_req_src`/`l1_mem_rsp_src` and the per-source `r_out_*`. Source 2 can simply stay unused.
- **No L1I presence bits (`ipres`/`w_ipres`) and no `ENABLE_COHERENT_L1I`** (off on r9999 silicon).
  - superdupersparc's S2 fast path and `w_idrop_need` use `w_ipres`. In r9999, mirror the `w_idrop_need` that r9999 actually has.
  - r9999's L1I coherence is the R10000 block-op path, which is slow-path only. That's correct as long as block ops wait for the pipe to drain, which they do in the drain arm.
  - The `` `ifndef ENABLE_COHERENT_L1I`` exemption in S2 (an L1D fill keeps the L1I copy) is the r9999 case.
- **Arbiter:** r9999 still has `GNT_*` states and `t_l2_passthru`. Port the combinational select; `b7e77b8` removes both.
- **Caches:** the default L1D is 16KB (one colour bit fewer) and the L2 128KB. `N_PIDX`/colour logic is parameterized, so check `L1D_N_COLOUR` = 1 cases compile.
- **MIPS-only ops** (CACHE ops, `MEM_INVL`/`MEM_WB`/`MEM_PGDROP`, R10000 block ops, `l2_nocache`) are all slow path. `w_s0_fast` admits only cacheable opcode 4/7.
- **`henry` on the FPGA, and AXI:** hit-under-miss keeps `mem_req_*` driven from `r_fp_*` while a fill is parked. Confirm Henry's AXI master tolerates that. It isn't verified on superdupersparc silicon yet; a Kodiak build was in progress at handoff.

## Suggested order, each step validated before the next

1. Copy `sdsparc_nb.m` and its scripts into `formal/murphi`, then run the minimal config and the negative controls (`neg_sdnb.sh`). Rumur needs a memory cap: one run once hit 917M states and got other jobs killed. Use `ulimit -v`.
2. Source ids, arbiter, response routing. This should be cycle-identical apart from the ack timing. Run the r9999 directed regression plus randgen co-sim.
3. `L2_HIT_UNDER_MISS`. Watch the "parked/taken/deferred" counters.
4. `L2_PIPE` + `reg_ram1r1w`.
5. Engines, early request, then N engines.

Validate each with co-sim (the checker), a perf A/B with `--warmup`, and a pipe trace (`--pipelog` + `gen_html`) to see where cycles go. The trace found every real limit here; aggregate counters misled twice.

## Things that bit us (tooling)

- `make` doesn't track `VFLAGS_EXTRA`. Run `rm -rf obj_dir`, then `make obj_dir/Vcore_l1d_l1i__ALL.a VFLAGS_EXTRA=...`, then `make ooo_core`.
- Verilator rejects indexing a small array with a wider index (`[2:0]` index into `[0:0]`). Size engine indexes as `LG_NPF = (NPF > 1) ? $clog2(NPF) : 1`.
- Two sweeps sharing one scratch disk-image directory deleted each other's images. Give each its own copies.
- The root disk filled with checkpoint disk copies. Clean them up per benchmark.
