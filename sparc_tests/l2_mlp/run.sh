#!/bin/bash
# ./run.sh <ooo_core binary> [jobs] [footprint] [K...]: cycles per step (one load per list) at each K,
# from the cycle difference of STEPS=N and 2N runs
cd "$(dirname "$0")"
SIM=$(readlink -f $1); J=${2:-4}; F=${3:-262144}; shift 3
KS=${@:-"1 2 4 8"}
N=20000
TAG=$(basename $SIM)
mkdir -p build/$TAG
one() {
  local K=$1 T=$2
  [ -f build/mlp_${K}_${F}_${T}.elf ] || ./build.sh $K $F $T
  timeout 3600 $SIM -f build/mlp_${K}_${F}_${T}.elf > build/$TAG/${K}_${F}_${T}.log 2>&1
}
export -f one; export SIM TAG F
for K in $KS; do echo "$K $N"; echo "$K $((2*N))"; done | xargs -P $J -L 1 bash -c 'one $0 $1'
printf "%-3s %12s %14s\n" K cyc/step cyc/load
for K in $KS; do
  c1=$(grep -a -o "^\[XLAT\] cycles [0-9]*" build/$TAG/${K}_${F}_${N}.log | awk '{print $3}')
  c2=$(grep -a -o "^\[XLAT\] cycles [0-9]*" build/$TAG/${K}_${F}_$((2*N)).log | awk '{print $3}')
  ok=$(grep -a -c "^PASS:" build/$TAG/${K}_${F}_${N}.log build/$TAG/${K}_${F}_$((2*N)).log | awk -F: '{s+=$2} END{print s}')
  awk -v k=$K -v a=$c1 -v b=$c2 -v n=$N -v ok=$ok 'BEGIN{d=(b-a)/n; printf "%-3d %12.2f %14.2f%s\n", k, d, d/k, (ok==2)?"":"  (CHECK FAILED)"}'
done
