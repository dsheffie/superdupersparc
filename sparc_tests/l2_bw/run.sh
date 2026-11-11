#!/bin/bash
# ./run.sh <ooo_core binary> [jobs] [footprints...]: cycles per load (one per
# 16-byte line) and line bytes/cycle at each footprint, from the cycle difference of TRIES=N and 2N runs
# (N = max(64K, 4 x the footprint's lines), so startup and warm-up cancel)
cd "$(dirname "$0")"
SIM=$(readlink -f $1); J=${2:-4}; shift 2
FOOTS=${@:-"16384 32768 65536 98304 131072 262144 393216 524288 786432 1048576 2097152"}
TAG=$(basename $SIM)
mkdir -p build/$TAG
one() {
  local F=$1 T=$2
  [ -f build/l2bw_${F}_${T}.elf ] || ./build.sh $F $T
  timeout 3600 $SIM -f build/l2bw_${F}_${T}.elf > build/$TAG/${F}_${T}.log 2>&1
}
export -f one; export SIM TAG
for F in $FOOTS; do
  N=$(( F / 4 > 65536 ? F / 4 : 65536 ))
  echo "$F $N"; echo "$F $((2*N))"
done | xargs -P $J -L 1 bash -c 'one $0 $1'
printf "%-9s %10s %8s\n" footprint cyc/load B/cyc
for F in $FOOTS; do
  N=$(( F / 4 > 65536 ? F / 4 : 65536 ))
  c1=$(grep -a -o "^\[XLAT\] cycles [0-9]*" build/$TAG/${F}_${N}.log | awk '{print $3}')
  c2=$(grep -a -o "^\[XLAT\] cycles [0-9]*" build/$TAG/${F}_$((2*N)).log | awk '{print $3}')
  ok=$(grep -a -c "^PASS:" build/$TAG/${F}_${N}.log build/$TAG/${F}_$((2*N)).log | awk -F: '{s+=$2} END{print s}')
  awk -v f=$F -v a=$c1 -v b=$c2 -v n=$N -v ok=$ok 'BEGIN{d=(b-a)/n; printf "%-9d %10.3f %8.3f%s\n", f, d, 16/d, (ok==2)?"":"  (CHECK FAILED)"}'
done
