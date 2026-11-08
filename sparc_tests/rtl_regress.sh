#!/bin/bash
# rtl_regress.sh: run the directed tests (sparc_tests/build/*.elf, built as
# each test's header says) on ooo_core with the checker, in parallel, and
# report PASS/FAIL per test.  A test fails on any checker mismatch, a DESYNC,
# a FAIL: line, or no clean end.  Logs: build/<test>.rtl.log.
#   ./rtl_regress.sh [jobs]
cd "$(dirname "$0")"
J=${1:-8}
MMU="--mmu-ctrl 0x901 --mmu-ctpr 0x80000 --mmu-ctx 0"
TESTS="wiggle winfill muldiv dcti probe:MMU atomic_0 atomic_1 fp_mem fp_cmp fp_bare fp_trap sv sv_gas mmu
       mmu_on:MMU mmu_iside_1:MMU mmu_iside_2:MMU atomic_mmu_0:MMU atomic_mmu_1:MMU atomic_mmu_2:MMU"
# (fib/div/fp/cc are Linux user programs: ISS only, run.sh)

run_one() {
  local spec=$1 t=${1%%:*} kind=${1#*:} args=""
  [ "$kind" = MMU ] && args=$MMU
  timeout 900 ../ooo_core -f build/$t.elf $args > build/$t.rtl.log 2>&1
  local rc=$?
  local bad
  bad=$(grep -a -m1 -E 'does not match|COSIM DESYNC|^FAIL:|STORE DIVERGENCE|%Error' build/$t.rtl.log)
  if [ -n "$bad" ]; then
    echo "FAIL $t: $bad"
  elif grep -a -q -E '^PASS:' build/$t.rtl.log; then
    echo "pass $t"
  else
    echo "FAIL $t: no clean end (rc=$rc): $(tail -1 build/$t.rtl.log)"
  fi
}
export -f run_one
export MMU
echo $TESTS | tr ' ' '\n' | grep -v '^$' | xargs -P $J -I{} bash -c 'run_one {}' | sort -k2
