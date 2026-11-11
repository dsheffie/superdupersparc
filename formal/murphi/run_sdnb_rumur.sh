#!/bin/bash
# run_sdnb_rumur.sh NAME KNOB=VAL ... -- check a variant of sdsparc_nb.m with Rumur
#   THREADS=N (default 6)  CAP=bytes initial state set (default 4G; the set grows as needed)
HERE=$(cd "$(dirname "$0")" && pwd)
BUILD=${MURPHI_BUILD:-$HERE/build}
set -e
N=$1; shift
D=$BUILD/$N; mkdir -p $D
cp $HERE/sdsparc_nb.m $D/$N.m
for kv in "$@"; do k=${kv%=*}; v=${kv#*=}; sed -i "s/^  $k: [0-9]*;/  $k: $v;/" $D/$N.m; grep -q "^  $k: $v;" $D/$N.m || { echo "knob $k not found"; exit 1; }; done
cd $D
rumur --threads ${THREADS:-6} --deadlock-detection stuttering --pack-state on \
  --set-capacity ${CAP:-4294967296} --counterexample-trace diff --max-errors 1 \
  --output $N.c $N.m > rumur.log 2>&1
cc -std=c11 -O3 -march=native -pthread -mcx16 -o $N $N.c >> rumur.log 2>&1
./$N > run.log 2>&1 || true
grep -E "^Status|No error|failed|Deadlock|deadlock|error:|states|rules fired" run.log | tail -4
