-- sdsparc_nb.m -- superdupersparc with a NON-BLOCKING L1D on top of r9999_nb.m's non-blocking
-- inclusive L2: several L1D misses in flight (rv64core nu_l1d style), DRAM that completes
-- requests in any order, posted L2 writebacks, and (knob) a separate L1D eviction buffer.
-- dsheffie 2026-11-10: "enough complexities that very much worthwhile using murphi to prove
-- protocol first".
--
-- Inherited from r9999_nb.m (unchanged, see its header): P1 one L2 transaction per L2 set,
-- P2 credit-limited probes, P3 one ordered L2->L1 path per L1 (fills and probes), P4 acks on a
-- sideband, P5 probe acks carry the newest data (retracting a queued writeback), P6 DMA
-- completion after probes are acked and dirty data is in DRAM.  L1D colours (VA index) with
-- the L2 pushing an alias probe to the old colour.
--
-- NEW agents / structure:
--  L1D miss queue (MRQ, NS slots, program order, head = 0).  A CPU op that hits and has no
--    older MRQ op to the same PA completes at once (hit-under-miss); otherwise it enters the
--    MRQ.  ANY MRQ op may send its miss early (several fills in flight); ops complete
--    (replay) only at the MRQ head, in program order.
--  DRAM: NDR request slots, completed in ANY order (tagged).  A read returns DRAM as of its
--    completion.  L2 victim writebacks and L1D writebacks that miss the L2 are POSTED
--    (the L2 transaction does not wait for the write to land).
--  EB_SEPARATE=1: L1D dirty victims go to an eviction buffer that drains to the L2
--    independently of the request queue (rv64core); 0: victims share the FIFO request queue.
--
-- New rules under test:
--  N1 L1D line interlock: at most one fill in flight per PA (any colour).
--  N2 L1D set interlock: at most one fill in flight per L1D set (colour) -- the victim is
--     chosen and evicted when the miss is sent, so a second fill to the set would overwrite
--     a line that became dirty in between.
--  N3 (EB_SEPARATE) a miss is not sent while its line sits in the eviction buffer
--     (rv64core bfbd8af / FIX_EB_P2).
--  N4 DRAM same-address order: a DRAM read or write is not issued while a write to the
--     same line is still in flight.
--  N5 DMA completion waits for posted writes of its line to land.
--  N6 a CPU op completes out of the MRQ only after every older op to the same PA.
--  N7 a probe needs a free slot on the ordered L2->L1 path, like a fill (see can_probe).
--  N8 memory-ordering nuke (Intel's MOnuke).  NUKE_MARK=1 (default): when a DMA-in post-drop
--     completes, every load of that line that has executed but not retired is MARKED, and
--     the marking is done before the DMA's completion is visible; a marked load is flushed
--     and re-executed when it reaches retirement, so an older non-restartable op (the
--     uncached status load S, already sent to the device) is never squashed.
--     NUKE_MARK=0: the drop squashes every executed-unretired load at once.  Without it a younger
--     cached load that hit a stale copy before the drop retires after an older status load
--     that saw "done": new flag, old data -- a TSO load->load violation (POLL agent).
--  DMA_QUIESCE=1: the L2 takes a DMA snoop only with no transaction in flight and both L2->L1
--     paths empty, and takes no L1 request while the snoop transaction runs.  dsheffie
--     2026-11-10: DMA snoop latency doesn't matter, so correct-but-slow is fine.
--
-- Checked: loads see the program-order value; DMA-out reads the latest value; one L1D copy
-- per PA; presence; inclusion.  Deadlock: CHECK_RULES=0 L1I=0 (CMurphi's deadlock = no
-- rule changes the state; L1I miss/invalidate cycles would mask a D-side deadlock).
--
-- Results (Rumur v2023.11.27, run_sdnb_rumur.sh, 2026-11-10):
--   L1I=0 DMA=0                        no error,  88.4M states
--   L1I=0 (DMA on)                     no error, 763.5M states
--   CHECK_RULES=0 L1I=0 (deadlock)     no error, 763.5M states
--   DMA=0 (L1I on)                     no error, 797.2M states
--   L1I and DMA together exceed 40 GB (> 776M states): not completed.
--   N1 is not load-bearing: with it off, two fills for one line (at two colours) are
--   reachable and the model still passes -- N2 plus the L2's alias probe cover it.
--   N7 (BUG_PROBE_NO_SLOT) fails only with DMA_QUIESCE=0 (DMA snoop probe behind two fills).
--
-- Negative controls (each MUST fail):
--   BUG_NO_LINE_INTERLOCK   N1 off
--   BUG_NO_SET_INTERLOCK    N2 off
--   BUG_NO_EB_CHECK         N3 off (needs EB_SEPARATE=1)
--   BUG_DRAM_NO_ORDER       N4 off
--   BUG_DMA_POSTED          N5 off
--   BUG_HIT_PASSES          N6 off: a hit completes past an older MRQ op to the same PA
--   BUG_PROBE_NO_SLOT       N7 off
--   BUG_NO_NUKE             N8 off
--   BUG_NUKE_BEFORE_DROP    N8 at the START of the drop transaction (a load can re-hit the
--                           stale copy before the probe removes it)
--   BUG_MARK_LATE           the DMA's completion is visible before the marking is applied
--   BUG_SQUASH_EXECUTED_S   (NUKE_MARK=0) the nuke also squashes an S already sent to the device
--   plus r9999_nb's: BUG_NO_SET_SERIAL BUG_NO_RETRACT BUG_NO_CREDIT BUG_ACK_VIA_QUEUE
--   BUG_PROBE_UNORDERED BUG_DMA_EARLY_DONE

const
  NADDR: 3;
  L2SETS: 2;
  MAXV: 1;
  NCOL: 2;
  NM: 2;                    -- L2 MSHRs
  QD: 2;                    -- L1D request queue depth
  RD: 2;                    -- L2->L1 ordered path depth
  NS: 2;                    -- L1D MRQ slots
  EBD: 1;                   -- L1D eviction buffer depth (EB_SEPARATE=1)
  NDR: 2;                   -- DRAM request slots

  L1I: 1;
  DMA: 1;
  SPEC_FILL: 1;
  CHECK_RULES: 1;
  EARLY: 1;                 -- 0: only the MRQ head sends its miss (one fill in flight)
  EB_SEPARATE: 1;
  DMA_ONE_ADDR: 1;          -- DMA targets only line 0 (shares L2 set 0 with line 1): state-space bound
  L1I_ONE_ADDR: 1;          -- the L1I fetches only line 0 (shares L2 set 0 with line 1): state-space bound
  POLL: 1;                  -- a driver polls DMA-in completion (status load S, then data load L)
  NUKE_MARK: 1;             -- 1: the drop MARKS executed-unretired loads of its line; a marked
                            --    load re-executes when it reaches retirement (Intel MOnuke)
                            -- 0: the drop squashes every executed-unretired load at once
  DMA_QUIESCE: 1;           -- DMA snoops drain and serialize the L2 (dsheffie: snoop latency doesn't matter)

  BUG_NO_NUKE: 0;
  BUG_NUKE_BEFORE_DROP: 0;
  BUG_MARK_LATE: 0;
  BUG_SQUASH_EXECUTED_S: 0;
  BUG_NO_LINE_INTERLOCK: 0;
  BUG_NO_SET_INTERLOCK: 0;
  BUG_NO_EB_CHECK: 0;
  BUG_DRAM_NO_ORDER: 0;
  BUG_DMA_POSTED: 0;
  BUG_PROBE_NO_SLOT: 0;
  BUG_HIT_PASSES: 0;
  BUG_NO_SET_SERIAL: 0;
  BUG_NO_RETRACT: 0;
  BUG_NO_CREDIT: 0;
  BUG_ACK_VIA_QUEUE: 0;
  BUG_PROBE_UNORDERED: 0;
  BUG_DMA_EARLY_DONE: 0;

type
  Addr: 0..NADDR-1;
  Ver: 0..MAXV;
  Col: 0..NCOL-1;
  L2Set: 0..L2SETS-1;
  MIdx: 0..NM-1;
  QIdx: 0..QD-1;
  RIdx: 0..RD-1;
  SIdx: 0..NS-1;
  EIdx: 0..EBD-1;
  DIdx: 0..NDR-1;
  Src: enum {S_D, S_I};
  LState: enum {L_I, L_V, L_VD};
  L1Line: record st: LState; tag: Addr; d: Ver; end;
  L2Line: record valid: boolean; dirty: boolean; tag: Addr; d: Ver;
                 pd: boolean; pidx: Col; pi: boolean; end;

  -- L1D -> L2 request queue entries (SW only with EB_SEPARATE=0; ACK only with BUG_ACK_VIA_QUEUE)
  QOp: enum {Q_LW, Q_SW, Q_ACK};
  QEnt: record op: QOp; a: Addr; c: Col; d: Ver; dirty: boolean; end;
  EEnt: record a: Addr; d: Ver; end;

  -- L2 -> L1 ordered path entries
  ROp: enum {R_FILL, R_PROBE};
  REnt: record op: ROp; a: Addr; c: Col; d: Ver; end;

  -- MSHR
  TKind: enum {T_FILL, T_WBINV, T_DROP};
  TStage: enum {T_LOOK, T_PROBING, T_READ, T_DWAIT, T_RESP, T_DMAWAIT};
  Mshr: record busy: boolean; kind: TKind; src: Src; a: Addr; c: Col;
               pa: Addr;
               waitd: boolean; waiti: boolean;
               stage: TStage; end;

  Ack: record full: boolean; a: Addr; dirty: boolean; d: Ver; end;
  Prb: record full: boolean; a: Addr; c: Col; end;

  -- L1D MRQ op.  v = the store's version, or the value a load must see.
  MSt: enum {M_NEW, M_REQ};
  MOp: record a: Addr; c: Col; isst: boolean; spec: boolean; v: Ver; st: MSt; end;

  -- DRAM request
  DReq: record full: boolean; wr: boolean; a: Addr; d: Ver; owner: MIdx; end;

  DmaSt: enum {DM_IDLE, DM_IN_PRE, DM_IN_ARMED, DM_IN_DONE, DM_IN_DROP,
               DM_OUT_PRE, DM_OUT_ARMED};

var
  arch: array[Addr] of Ver;                       -- program-order (architectural) value
  mem: array[Addr] of Ver;
  l2: array[L2Set] of L2Line;
  m: array[MIdx] of Mshr;
  dram: array[DIdx] of DReq;

  l1d: array[Col] of L1Line;
  mrq: array[SIdx] of MOp; mn: 0..NS;             -- L1D miss queue (program order, head = 0)
  dq: array[QIdx] of QEnt; dqn: 0..QD;            -- L1D request queue (FIFO, head = 0)
  eb: array[EIdx] of EEnt; ebn: 0..EBD;           -- L1D eviction buffer (FIFO, head = 0)

  l1i: L1Line; ifill: boolean; ia: Addr;
  iq: QEnt; iqf: boolean;

  rq: array[Src] of array[RIdx] of REnt;
  rqn: array[Src] of 0..RD;
  pbuf: array[Src] of Prb;
  ack: array[Src] of Ack;

  dma: DmaSt; daddr: Addr; dsnp: boolean;

  -- POLL agent: S = uncached status load (older, executes in order), L = cached load of line 0
  -- (younger, may execute early); both retire in program order
  pol: boolean; ps_done: boolean; ps_val: boolean; ps_ret: boolean; ps_n: 0..2;
  pl_done: boolean; pl_val: Ver; pl_mark: boolean;
  markpend: boolean;                              -- BUG_MARK_LATE: drop done, mark not yet applied

------------------------------------------------------------------ helpers
function l2set(a: Addr): L2Set;
begin
  if L2SETS = 2 & a = NADDR-1 then return 1; endif;
  return 0;
end;
function l2hit(a: Addr): boolean;
begin return l2[l2set(a)].valid & l2[l2set(a)].tag = a; end;
function dhit(a: Addr; c: Col): boolean;
begin return l1d[c].st != L_I & l1d[c].tag = a; end;
function ihit(a: Addr): boolean;
begin return l1i.st != L_I & l1i.tag = a; end;
function in_window(a: Addr): boolean;
begin return (dma = DM_IN_PRE | dma = DM_IN_ARMED | dma = DM_IN_DONE | dma = DM_IN_DROP) & daddr = a; end;
function dout_window(a: Addr): boolean;
begin return (dma = DM_OUT_PRE | dma = DM_OUT_ARMED) & daddr = a; end;

function set_busy(s: L2Set): boolean;
begin
  for i: MIdx do
    if m[i].busy & l2set(m[i].a) = s then return true; endif;
  endfor;
  return false;
end;

function any_busy(): boolean;
begin
  for i: MIdx do if m[i].busy then return true; endif; endfor;
  return false;
end;
function dma_busy(): boolean;
begin
  for i: MIdx do if m[i].busy & m[i].kind != T_FILL then return true; endif; endfor;
  return false;
end;
-- an L1 request may enter the L2 (DMA_QUIESCE: not while a snoop transaction runs)
function l1_admit(): boolean;
begin return DMA_QUIESCE = 0 | !dma_busy(); end;

function free_mshr(): boolean;
begin
  for i: MIdx do if !m[i].busy then return true; endif; endfor;
  return false;
end;

-- DRAM
function dram_free(): boolean;
begin
  for j: DIdx do if !dram[j].full then return true; endif; endfor;
  return false;
end;
function dram_wr_pending(a: Addr): boolean;
begin
  for j: DIdx do if dram[j].full & dram[j].wr & dram[j].a = a then return true; endif; endfor;
  return false;
end;
-- N4: a new DRAM request to line a may issue
function dram_ok(a: Addr): boolean;
begin
  return dram_free() & (BUG_DRAM_NO_ORDER = 1 | !dram_wr_pending(a));
end;
procedure dram_push(wr: boolean; a: Addr; d: Ver; owner: MIdx);
var done: boolean;
begin
  done := false;
  for j: DIdx do
    if !done & !dram[j].full then
      dram[j].full := true; dram[j].wr := wr; dram[j].a := a; dram[j].d := d; dram[j].owner := owner;
      done := true;
    endif;
  endfor;
  assert done "DRAM request overflow";
end;

procedure alloc(k: TKind; s: Src; a: Addr; c: Col);
var done: boolean;
begin
  done := false;
  for i: MIdx do
    if !done & !m[i].busy then
      m[i].busy := true; m[i].kind := k; m[i].src := s; m[i].a := a; m[i].c := c;
      m[i].pa := a; m[i].waitd := false; m[i].waiti := false; m[i].stage := T_LOOK;
      done := true;
    endif;
  endfor;
  assert done "no free MSHR";
end;

procedure rq_push(s: Src; o: ROp; a: Addr; c: Col; d: Ver);
begin
  assert rqn[s] < RD "L2->L1 path overflow";
  rq[s][rqn[s]].op := o; rq[s][rqn[s]].a := a; rq[s][rqn[s]].c := c; rq[s][rqn[s]].d := d;
  rqn[s] := rqn[s] + 1;
end;

procedure rq_pop(s: Src);
begin
  for j: RIdx do
    if j < RD-1 then rq[s][j] := rq[s][j+1]; endif;
  endfor;
  rq[s][RD-1].op := R_FILL; rq[s][RD-1].a := 0; rq[s][RD-1].c := 0; rq[s][RD-1].d := 0;
  rqn[s] := rqn[s] - 1;
end;

procedure dq_push(o: QOp; a: Addr; c: Col; d: Ver; dirty: boolean);
begin
  assert dqn < QD "L1D request queue overflow";
  dq[dqn].op := o; dq[dqn].a := a; dq[dqn].c := c; dq[dqn].d := d; dq[dqn].dirty := dirty;
  dqn := dqn + 1;
end;

procedure dq_remove(k: QIdx);
begin
  for j: QIdx do
    if j >= k & j < QD-1 then dq[j] := dq[j+1]; endif;
  endfor;
  dq[QD-1].op := Q_LW; dq[QD-1].a := 0; dq[QD-1].c := 0; dq[QD-1].d := 0; dq[QD-1].dirty := false;
  dqn := dqn - 1;
end;

procedure eb_remove(k: EIdx);
begin
  for j: EIdx do
    if j >= k & j < EBD-1 then eb[j] := eb[j+1]; endif;
  endfor;
  eb[EBD-1].a := 0; eb[EBD-1].d := 0;
  ebn := ebn - 1;
end;

procedure mrq_remove(k: SIdx);
begin
  for j: SIdx do
    if j >= k & j < NS-1 then mrq[j] := mrq[j+1]; endif;
  endfor;
  mrq[NS-1].a := 0; mrq[NS-1].c := 0; mrq[NS-1].isst := false; mrq[NS-1].spec := false;
  mrq[NS-1].v := 0; mrq[NS-1].st := M_NEW;
  mn := mn - 1;
end;

function in_eb(a: Addr): boolean;
begin
  for k: EIdx do if k < ebn & eb[k].a = a then return true; endif; endfor;
  return false;
end;

-- any MRQ op to line a (older than slot lim; lim = NS means "any")
function mrq_has(a: Addr; lim: 0..NS): boolean;
begin
  for k: SIdx do if k < mn & k < lim & mrq[k].a = a then return true; endif; endfor;
  return false;
end;

-- a fill for line a (N1), or for L1D set c (N2), is in flight
function fill_line_busy(a: Addr): boolean;
begin
  for k: SIdx do if k < mn & mrq[k].st = M_REQ & mrq[k].a = a then return true; endif; endfor;
  return false;
end;
function fill_set_busy(c: Col): boolean;
begin
  for k: SIdx do if k < mn & mrq[k].st = M_REQ & mrq[k].c = c then return true; endif; endfor;
  return false;
end;

-- P2 + N7: a probe needs the L1's probe-buffer credit AND a slot on the ordered L2->L1 path.
-- With one L1D fill outstanding (r9999_nb.m) the path could never be full when a probe was
-- sent; with several fills queued plus a probe (e.g. a DMA snoop) it overflows -- found by this
-- model, 2026-11-10.  In RTL terms: the L1D's reply queue must count probes, not just fills.
function can_probe(a: Addr): boolean;
begin
  if BUG_NO_CREDIT = 1 then return true; endif;
  return (!l2[l2set(a)].pd | (!pbuf[S_D].full & (BUG_PROBE_NO_SLOT = 1 | rqn[S_D] < RD)))
       & (!l2[l2set(a)].pi | (!pbuf[S_I].full & (BUG_PROBE_NO_SLOT = 1 | rqn[S_I] < RD)));
end;

procedure deliver_probe(s: Src; a: Addr; c: Col);
begin
  if BUG_PROBE_UNORDERED = 1 then
    assert !pbuf[s].full "probe buffer overrun";
    pbuf[s].full := true; pbuf[s].a := a; pbuf[s].c := c;
  else
    rq_push(s, R_PROBE, a, c, 0);
  endif;
end;

-- an L1D writeback the L2 accepts: into the L2 line, or (L2 miss) a posted DRAM write
procedure l2_take_wb(a: Addr; d: Ver);
var s: L2Set;
begin
  s := l2set(a);
  if l2hit(a) then
    l2[s].d := d; l2[s].dirty := true; l2[s].pd := false;
  else
    dram_push(true, a, d, 0);
  endif;
end;

-- what a load of line a reads if it misses now (no CPU stores to a DMA line in its window)
function coh(a: Addr): Ver;
begin
  for c: Col do if dhit(a, c) then return l1d[c].d; endif; endfor;
  if l2hit(a) then return l2[l2set(a)].d; endif;
  return mem[a];
end;

-- N8: the drop of line a reaches the core
procedure nuke(a: Addr);
begin
  if POLL = 1 & BUG_NO_NUKE = 0 & pol then
    if NUKE_MARK = 1 then
      if pl_done & a = 0 then pl_mark := true; endif;
    else
      -- immediate squash; S once executed is non-restartable (sent to the device)
      pl_done := false;
      if BUG_SQUASH_EXECUTED_S = 1 then ps_done := false; endif;
    endif;
  endif;
end;

------------------------------------------------------------------ L2: accept
rule "L2 accept L1D"
  dqn > 0 & dq[0].op != Q_ACK & l1_admit()
  & (BUG_NO_SET_SERIAL = 1 | !set_busy(l2set(dq[0].a)))
  & ((dq[0].op = Q_SW & (l2hit(dq[0].a) | dram_ok(dq[0].a))) | (dq[0].op = Q_LW & free_mshr()))
==>
var e: QEnt;
begin
  e := dq[0]; dq_remove(0);
  if e.op = Q_SW then
    l2_take_wb(e.a, e.d);
  else
    alloc(T_FILL, S_D, e.a, e.c);
  endif;
end;

-- the eviction buffer drains on its own path (EB_SEPARATE=1)
rule "L2 accept L1D eviction"
  ebn > 0 & l1_admit() & (BUG_NO_SET_SERIAL = 1 | !set_busy(l2set(eb[0].a)))
  & (l2hit(eb[0].a) | dram_ok(eb[0].a))
==>
var e: EEnt;
begin
  e := eb[0]; eb_remove(0);
  l2_take_wb(e.a, e.d);
end;

rule "L2 accept L1I"
  iqf & l1_admit() & (BUG_NO_SET_SERIAL = 1 | !set_busy(l2set(iq.a))) & free_mshr()
==>
begin
  iqf := false;
  alloc(T_FILL, S_I, iq.a, 0);
end;

rule "L2 accept DMA snoop"
  dsnp & (BUG_NO_SET_SERIAL = 1 | !set_busy(l2set(daddr))) & free_mshr()
  & (DMA_QUIESCE = 0 | (!any_busy() & rqn[S_D] = 0 & rqn[S_I] = 0))
==>
begin
  dsnp := false;
  if dma = DM_IN_DROP | (dma = DM_IDLE & BUG_DMA_EARLY_DONE = 1) then
    if BUG_NUKE_BEFORE_DROP = 1 then nuke(daddr); endif;
    alloc(T_DROP, S_D, daddr, 0);
  else
    alloc(T_WBINV, S_D, daddr, 0);
  endif;
end;

------------------------------------------------------------------ L2: per-MSHR steps
ruleset i: MIdx do
  rule "MSHR look"
    m[i].busy & m[i].stage = T_LOOK
  ==>
  var s: L2Set; a: Addr;
  begin
    a := m[i].a; s := l2set(a);
    if m[i].kind = T_FILL then
      if l2hit(a) then
        if m[i].src = S_D & l2[s].pd & l2[s].pidx != m[i].c then
          if can_probe(a) then
            m[i].pa := a; m[i].waitd := true; m[i].waiti := false;
            deliver_probe(S_D, a, l2[s].pidx);
            m[i].stage := T_PROBING;
          endif;
        else
          m[i].stage := T_RESP;
        endif;
      elsif l2[s].valid & (l2[s].pd | l2[s].pi) then
        if can_probe(l2[s].tag) then
          m[i].pa := l2[s].tag; m[i].waitd := l2[s].pd; m[i].waiti := l2[s].pi & L1I = 1;
          if l2[s].pd then deliver_probe(S_D, l2[s].tag, l2[s].pidx); endif;
          if l2[s].pi & L1I = 1 then deliver_probe(S_I, l2[s].tag, 0); endif;
          m[i].stage := T_PROBING;
        endif;
      else
        -- evict the victim: a dirty one is a POSTED DRAM write
        if !(l2[s].valid & l2[s].dirty) | dram_ok(l2[s].tag) then
          if l2[s].valid & l2[s].dirty then dram_push(true, l2[s].tag, l2[s].d, i); endif;
          l2[s].valid := false; l2[s].dirty := false; l2[s].pd := false; l2[s].pi := false;
          m[i].stage := T_READ;
        endif;
      endif;
    else
      -- DMA snoop (WBINV before the transfer, DROP after a DMA-in)
      if l2hit(a) & (l2[s].pd | l2[s].pi) then
        if can_probe(a) then
          m[i].pa := a; m[i].waitd := l2[s].pd; m[i].waiti := l2[s].pi & L1I = 1;
          if l2[s].pd then deliver_probe(S_D, a, l2[s].pidx); endif;
          if l2[s].pi & L1I = 1 then deliver_probe(S_I, a, 0); endif;
          m[i].stage := T_PROBING;
        endif;
      elsif l2hit(a) & m[i].kind = T_WBINV & l2[s].dirty then
        if dram_ok(a) then
          dram_push(true, a, l2[s].d, i);
          l2[s].valid := false; l2[s].dirty := false; l2[s].pd := false; l2[s].pi := false;
          m[i].stage := T_DMAWAIT;
        endif;
      else
        if l2hit(a) then
          if m[i].kind = T_DROP then
            assert !l2[s].dirty "DMA post-drop found dirty data";
          endif;
          l2[s].valid := false; l2[s].dirty := false; l2[s].pd := false; l2[s].pi := false;
        endif;
        m[i].stage := T_DMAWAIT;
      endif;
    endif;
  end;

  -- P6 + N5: DMA completion once every posted write of the line has landed
  rule "MSHR DMA completion"
    m[i].busy & m[i].stage = T_DMAWAIT & (BUG_DMA_POSTED = 1 | !dram_wr_pending(m[i].a))
  ==>
  begin
    if m[i].kind = T_WBINV then
      if dma = DM_IN_PRE then dma := DM_IN_ARMED; endif;
      if dma = DM_OUT_PRE then dma := DM_OUT_ARMED; endif;
    else
      -- N8: the nuke completes before the DMA-in's completion is visible (dma := DM_IDLE)
      if BUG_NUKE_BEFORE_DROP = 0 then
        if BUG_MARK_LATE = 1 then markpend := true; else nuke(m[i].a); endif;
      endif;
      if dma = DM_IN_DROP then dma := DM_IDLE; endif;
    endif;
    m[i].busy := false;
  end;

  ruleset s: Src do
    rule "MSHR takes ack"
      m[i].busy & m[i].stage = T_PROBING & ack[s].full & ack[s].a = m[i].pa
      & ((s = S_D & m[i].waitd) | (s = S_I & m[i].waiti))
    ==>
    begin
      assert l2hit(m[i].pa) "probed line left the L2 during the probe";
      if ack[s].dirty then
        l2[l2set(m[i].pa)].d := ack[s].d; l2[l2set(m[i].pa)].dirty := true;
      endif;
      if s = S_D then l2[l2set(m[i].pa)].pd := false; m[i].waitd := false;
      else l2[l2set(m[i].pa)].pi := false; m[i].waiti := false; endif;
      ack[s].full := false; ack[s].dirty := false; ack[s].d := 0;
      if !m[i].waitd & !m[i].waiti then m[i].stage := T_LOOK; endif;
    end;
  end;

  rule "MSHR issues DRAM read"
    m[i].busy & m[i].stage = T_READ & dram_ok(m[i].a)
  ==>
  begin
    dram_push(false, m[i].a, 0, i);
    m[i].stage := T_DWAIT;
  end;

  rule "MSHR respond"
    m[i].busy & m[i].stage = T_RESP & rqn[m[i].src] < RD
  ==>
  var s: L2Set;
  begin
    s := l2set(m[i].a);
    if m[i].src = S_D then
      l2[s].pd := true; l2[s].pidx := m[i].c;
    else
      l2[s].pi := true;
    endif;
    rq_push(m[i].src, R_FILL, m[i].a, m[i].c, l2[s].d);
    m[i].busy := false;
  end;
end;

------------------------------------------------------------------ DRAM (any order)
ruleset j: DIdx do
  rule "DRAM completes"
    dram[j].full
  ==>
  var s: L2Set; o: MIdx;
  begin
    if dram[j].wr then
      mem[dram[j].a] := dram[j].d;
    else
      o := dram[j].owner;
      assert m[o].busy & m[o].stage = T_DWAIT & m[o].a = dram[j].a "DRAM read with no owner";
      s := l2set(dram[j].a);
      l2[s].valid := true; l2[s].dirty := false; l2[s].tag := dram[j].a; l2[s].d := mem[dram[j].a];
      l2[s].pd := false; l2[s].pi := false;
      m[o].stage := T_LOOK;
    endif;
    dram[j].full := false; dram[j].wr := false; dram[j].a := 0; dram[j].d := 0; dram[j].owner := 0;
  end;
end;

rule "L2 takes queued ack"
  BUG_ACK_VIA_QUEUE = 1 & dqn > 0 & dq[0].op = Q_ACK
==>
var e: QEnt;
begin
  e := dq[0];
  for i: MIdx do
    if m[i].busy & m[i].stage = T_PROBING & m[i].waitd & m[i].pa = e.a then
      if e.dirty then l2[l2set(e.a)].d := e.d; l2[l2set(e.a)].dirty := true; endif;
      l2[l2set(e.a)].pd := false; m[i].waitd := false;
      if !m[i].waiti then m[i].stage := T_LOOK; endif;
    endif;
  endfor;
  dq_remove(0);
end;

------------------------------------------------------------------ L1D
-- the CPU issues a load or store (program order)
ruleset a: Addr; c: Col; st: boolean do
  rule "CPU op"
    ((st & !in_window(a) & !dout_window(a) & arch[a] < MAXV) | (!st & (!in_window(a) | SPEC_FILL = 1)))
    & ((dhit(a, c) & (BUG_HIT_PASSES = 1 | !mrq_has(a, NS))) | mn < NS)
    & (CHECK_RULES = 1 | st | !(dhit(a, c) & (BUG_HIT_PASSES = 1 | !mrq_has(a, NS))))
  ==>
  var sp: boolean;
  begin
    sp := !st & in_window(a);
    if dhit(a, c) & (BUG_HIT_PASSES = 1 | !mrq_has(a, NS)) then
      -- hit (under any outstanding misses)
      if st then
        arch[a] := arch[a] + 1;
        l1d[c].d := arch[a]; l1d[c].st := L_VD;
      elsif !sp then
        assert l1d[c].d = arch[a] "load hit returned a stale value";
      endif;
    else
      mrq[mn].a := a; mrq[mn].c := c; mrq[mn].isst := st; mrq[mn].spec := sp; mrq[mn].st := M_NEW;
      if st then arch[a] := arch[a] + 1; endif;
      mrq[mn].v := arch[a];
      mn := mn + 1;
    endif;
  end;
end;

-- send the miss for MRQ op k (the head; or any op with EARLY=1)
ruleset k: SIdx do
  rule "L1D sends miss"
    k < mn & mrq[k].st = M_NEW & (EARLY = 1 | k = 0)
    & !dhit(mrq[k].a, mrq[k].c)
    & (BUG_NO_LINE_INTERLOCK = 1 | !fill_line_busy(mrq[k].a))
    & (BUG_NO_SET_INTERLOCK = 1 | !fill_set_busy(mrq[k].c))
    & (EB_SEPARATE = 0 | BUG_NO_EB_CHECK = 1 | !in_eb(mrq[k].a))
    & ((l1d[mrq[k].c].st != L_VD & dqn < QD)
       | (l1d[mrq[k].c].st = L_VD & EB_SEPARATE = 1 & ebn < EBD & dqn < QD)
       | (l1d[mrq[k].c].st = L_VD & EB_SEPARATE = 0 & dqn + 2 <= QD))
  ==>
  var c: Col;
  begin
    c := mrq[k].c;
    if l1d[c].st = L_VD then
      if EB_SEPARATE = 1 then
        eb[ebn].a := l1d[c].tag; eb[ebn].d := l1d[c].d; ebn := ebn + 1;
      else
        dq_push(Q_SW, l1d[c].tag, c, l1d[c].d, true);
      endif;
    endif;
    l1d[c].st := L_I;
    dq_push(Q_LW, mrq[k].a, c, 0, false);
    mrq[k].st := M_REQ;
  end;
end;

-- the MRQ head completes (replays) once its line is present
rule "L1D replays head"
  mn > 0 & mrq[0].st = M_NEW & dhit(mrq[0].a, mrq[0].c)
==>
var a: Addr; c: Col;
begin
  a := mrq[0].a; c := mrq[0].c;
  if mrq[0].isst then
    l1d[c].d := mrq[0].v; l1d[c].st := L_VD;
  elsif !mrq[0].spec then
    assert l1d[c].d = mrq[0].v "load miss returned a stale value";
  endif;
  mrq_remove(0);
end;

-- the ordered L2->L1D path: fills install, probes move to the probe buffer (P3)
rule "L1D takes from L2 path"
  rqn[S_D] > 0 & (rq[S_D][0].op = R_FILL | !pbuf[S_D].full)
==>
var e: REnt; found: boolean;
begin
  e := rq[S_D][0]; rq_pop(S_D);
  if e.op = R_PROBE then
    pbuf[S_D].full := true; pbuf[S_D].a := e.a; pbuf[S_D].c := e.c;
  else
    found := false;
    for k: SIdx do
      if !found & k < mn & mrq[k].st = M_REQ & mrq[k].a = e.a & mrq[k].c = e.c then
        mrq[k].st := M_NEW; found := true;
      endif;
    endfor;
    assert found "unexpected L1D fill";
    l1d[e.c].st := L_V; l1d[e.c].tag := e.a; l1d[e.c].d := e.d;
  endif;
end;

-- probe handling (R2: whatever the L1D is doing); P5: newest data wherever it is
rule "L1D handles probe"
  pbuf[S_D].full & (BUG_ACK_VIA_QUEUE = 1 ? dqn < QD : !ack[S_D].full)
==>
var a: Addr; c: Col; dirty: boolean; d: Ver; found: boolean;
begin
  a := pbuf[S_D].a; c := pbuf[S_D].c;
  dirty := false; d := 0;
  if dhit(a, c) then
    if l1d[c].st = L_VD then dirty := true; d := l1d[c].d; endif;
    l1d[c].st := L_I;
  endif;
  if BUG_NO_RETRACT = 0 then
    found := false;
    for k: QIdx do
      if !found & k < dqn & dq[k].op = Q_SW & dq[k].a = a then
        dirty := true; d := dq[k].d;
        dq_remove(k);
        found := true;
      endif;
    endfor;
    for k: EIdx do
      if !found & k < ebn & eb[k].a = a then
        dirty := true; d := eb[k].d;
        eb_remove(k);
        found := true;
      endif;
    endfor;
  endif;
  if BUG_ACK_VIA_QUEUE = 1 then
    dq_push(Q_ACK, a, 0, d, dirty);
  else
    ack[S_D].full := true; ack[S_D].a := a; ack[S_D].dirty := dirty; ack[S_D].d := d;
  endif;
  pbuf[S_D].full := false;
end;

------------------------------------------------------------------ L1I (tag-only)
ruleset a: Addr do
  rule "L1I miss"
    L1I = 1 & !ifill & !ihit(a) & !iqf & (!in_window(a) | SPEC_FILL = 1) & (L1I_ONE_ADDR = 0 | a = 0)
  ==>
  begin
    l1i.st := L_I; ifill := true; ia := a;
    iqf := true; iq.op := Q_LW; iq.a := a; iq.c := 0; iq.d := 0; iq.dirty := false;
  end;
end;

rule "L1I: invalidate (I-sync)"
  L1I = 1 & !ifill & l1i.st != L_I
==>
begin
  l1i.st := L_I;
end;

rule "L1I takes from L2 path"
  rqn[S_I] > 0 & (rq[S_I][0].op = R_FILL | !pbuf[S_I].full)
==>
var e: REnt;
begin
  e := rq[S_I][0]; rq_pop(S_I);
  if e.op = R_PROBE then
    pbuf[S_I].full := true; pbuf[S_I].a := e.a; pbuf[S_I].c := e.c;
  else
    assert ifill & ia = e.a "unexpected L1I fill";
    l1i.st := L_V; l1i.tag := e.a; l1i.d := 0;
    ifill := false;
  endif;
end;

rule "L1I handles probe"
  pbuf[S_I].full & !ack[S_I].full
==>
begin
  if ihit(pbuf[S_I].a) then l1i.st := L_I; endif;
  ack[S_I].full := true; ack[S_I].a := pbuf[S_I].a; ack[S_I].dirty := false; ack[S_I].d := 0;
  pbuf[S_I].full := false;
end;

------------------------------------------------------------------ DMA (third agent)
-- the driver starts the I/O after its stores drain (no CPU memory op outstanding)
ruleset a: Addr do
  rule "DMA-in: request pre-snoop"
    DMA = 1 & dma = DM_IDLE & !dsnp & mn = 0 & !pol & (DMA_ONE_ADDR = 0 | a = 0)
  ==>
  begin
    daddr := a; dsnp := true; dma := DM_IN_PRE;
  end;

  rule "DMA-out: request pre-snoop"
    DMA = 1 & dma = DM_IDLE & !dsnp & mn = 0 & !pol & (DMA_ONE_ADDR = 0 | a = 0)
  ==>
  begin
    daddr := a; dsnp := true; dma := DM_OUT_PRE;
  end;
end;

rule "DMA-in: device writes DRAM"
  dma = DM_IN_ARMED & arch[daddr] < MAXV
==>
begin
  arch[daddr] := arch[daddr] + 1;
  mem[daddr] := arch[daddr];
  dma := DM_IN_DONE;
end;

rule "DMA-in: request post-drop"
  dma = DM_IN_DONE & !dsnp
==>
begin
  dsnp := true;
  if BUG_DMA_EARLY_DONE = 1 then dma := DM_IDLE; else dma := DM_IN_DROP; endif;
end;

rule "DMA-out: device reads DRAM"
  dma = DM_OUT_ARMED
==>
begin
  assert mem[daddr] = arch[daddr] "device read stale data (DMA-out)";
  dma := DM_IDLE;
end;

------------------------------------------------------------------ POLL agent (driver)
-- while a DMA-in is in progress the driver issues: S (status, uncached), then L (line 0)
rule "POLL: issue S, L"
  POLL = 1 & DMA = 1 & !pol & (dma = DM_IN_PRE | dma = DM_IN_ARMED | dma = DM_IN_DONE | dma = DM_IN_DROP)
==>
begin
  pol := true; ps_done := false; ps_val := false; ps_ret := false; ps_n := 0;
  pl_done := false; pl_val := 0; pl_mark := false;
end;

rule "BUG_MARK_LATE: the mark lands after the completion is visible"
  markpend
==>
begin
  markpend := false; nuke(0);
end;

-- L executes early: an L1D hit, or a miss returning what a miss would read now
rule "POLL: L executes"
  pol & !pl_done
==>
begin
  pl_val := coh(0); pl_done := true;
end;

-- S is uncached: it executes only at the ROB head (nothing older pending), in order; a
-- device read has side effects, so executing it twice is itself an error
rule "POLL: S executes"
  pol & !ps_done
==>
begin
  assert ps_n = 0 "uncached status load re-sent to the device after a squash";
  ps_val := (dma = DM_IDLE); ps_done := true; ps_n := 1;
end;

rule "POLL: S retires"
  pol & ps_done & !ps_ret
==>
begin
  ps_ret := true;
end;

-- L at retirement: a marked L is flushed and re-executes (the MOnuke), otherwise it retires
rule "POLL: L reaches retirement"
  pol & ps_ret & pl_done
==>
begin
  if pl_mark then
    pl_done := false; pl_mark := false;
  else
    if ps_val then
      assert pl_val = arch[0] "MO violation: status says done, data load returned stale value";
    endif;
    pol := false; ps_done := false; ps_val := false; ps_ret := false; ps_n := 0;
    pl_done := false; pl_val := 0;
  endif;
end;

------------------------------------------------------------------ invariants
invariant "at most one L1D copy per physical line"
  forall c1: Col do forall c2: Col do
    c1 = c2 | l1d[c1].st = L_I | l1d[c2].st = L_I | l1d[c1].tag != l1d[c2].tag
  endforall endforall;

invariant "presence: an L1D-held line has pd set at its colour"
  forall c: Col do
    l1d[c].st = L_I | (l2hit(l1d[c].tag) & l2[l2set(l1d[c].tag)].pd
                       & l2[l2set(l1d[c].tag)].pidx = c)
  endforall;

invariant "inclusion: L1I subset of L2"
  L1I = 0 | l1i.st = L_I | (l2hit(l1i.tag) & l2[l2set(l1i.tag)].pi);

------------------------------------------------------------------ start
startstate
begin
  for a: Addr do arch[a] := 0; mem[a] := 0; endfor;
  for s: L2Set do
    l2[s].valid := false; l2[s].dirty := false; l2[s].tag := 0; l2[s].d := 0;
    l2[s].pd := false; l2[s].pidx := 0; l2[s].pi := false;
  endfor;
  for i: MIdx do
    m[i].busy := false; m[i].kind := T_FILL; m[i].src := S_D; m[i].a := 0; m[i].c := 0;
    m[i].pa := 0; m[i].waitd := false; m[i].waiti := false; m[i].stage := T_LOOK;
  endfor;
  for j: DIdx do
    dram[j].full := false; dram[j].wr := false; dram[j].a := 0; dram[j].d := 0; dram[j].owner := 0;
  endfor;
  for c: Col do l1d[c].st := L_I; l1d[c].tag := 0; l1d[c].d := 0; endfor;
  for k: SIdx do
    mrq[k].a := 0; mrq[k].c := 0; mrq[k].isst := false; mrq[k].spec := false;
    mrq[k].v := 0; mrq[k].st := M_NEW;
  endfor;
  mn := 0;
  for k: QIdx do dq[k].op := Q_LW; dq[k].a := 0; dq[k].c := 0; dq[k].d := 0; dq[k].dirty := false; endfor;
  dqn := 0;
  for k: EIdx do eb[k].a := 0; eb[k].d := 0; endfor;
  ebn := 0;
  l1i.st := L_I; l1i.tag := 0; l1i.d := 0; ifill := false; ia := 0;
  iq.op := Q_LW; iq.a := 0; iq.c := 0; iq.d := 0; iq.dirty := false; iqf := false;
  for s: Src do
    for j: RIdx do rq[s][j].op := R_FILL; rq[s][j].a := 0; rq[s][j].c := 0; rq[s][j].d := 0; endfor;
    rqn[s] := 0;
    pbuf[s].full := false; pbuf[s].a := 0; pbuf[s].c := 0;
    ack[s].full := false; ack[s].a := 0; ack[s].dirty := false; ack[s].d := 0;
  endfor;
  dma := DM_IDLE; daddr := 0; dsnp := false;
  pol := false; ps_done := false; ps_val := false; ps_ret := false; ps_n := 0;
  pl_done := false; pl_val := 0; pl_mark := false; markpend := false;
end;
