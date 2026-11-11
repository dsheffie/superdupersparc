#!/bin/bash
# neg_sdnb.sh: every negative control of sdsparc_nb.m must FAIL
cd $(dirname "$0")
run() { n=$1; shift; r=$(THREADS=2 CAP=2147483648 timeout 1800 ./run_sdnb_rumur.sh $n "$@" | tr '\n' ' '); echo "$n [$*]: $r"; }
# n_line PASSES by design: N1 is not load-bearing (see the model header)
run n_line   L1I=0 DMA=0 BUG_NO_LINE_INTERLOCK=1
run n_set    L1I=0 DMA=0 BUG_NO_SET_INTERLOCK=1
run n_eb     L1I=0 DMA=0 BUG_NO_EB_CHECK=1
run n_dram   L1I=0 DMA=0 BUG_DRAM_NO_ORDER=1
run n_hit    L1I=0 DMA=0 BUG_HIT_PASSES=1
run n_dmap   L1I=0 BUG_DMA_POSTED=1
run n_slot   L1I=0 DMA_QUIESCE=0 BUG_PROBE_NO_SLOT=1
run n_nuke   L1I=0 BUG_NO_NUKE=1
run n_nukeb  L1I=0 BUG_NUKE_BEFORE_DROP=1
run n_late   L1I=0 BUG_MARK_LATE=1
run n_sqS    L1I=0 NUKE_MARK=0 BUG_SQUASH_EXECUTED_S=1
echo NEG_END
