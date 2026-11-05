#!/bin/bash
# csmith on ooo_core.  The reference checksum is qemu-sparc running the same
# program built for Linux user mode (rt.c -DRT_USER, same compiler, soft
# mul/div) -- not the host: csmith's unions make some programs byte-order
# dependent, so a big-endian SPARC checksum can legitimately differ from x86's.
# The bare-metal build (soft mul/div, the ../sv_asm.S trap table and window
# handlers, rt.c) must leave that value in %g6 on sparc_iss, and ooo_core must
# match sparc_iss retirement by retirement (the cosim) to the same error-mode
# halt.
#   ./run.sh [first_seed] [count]
# HW_MULDIV=1: compile for the hardware umul/smul/udiv/sdiv (into build_hw/)
# instead of clang's soft-mul-div helpers
set -u
cd "$(dirname "$0")"
TOP=$(cd ../.. && pwd)
ISS=$TOP/sparc_iss
CORE=$TOP/ooo_core
if [ "${HW_MULDIV:-0}" = 1 ]; then
  B=build_hw
  SOFT=""
else
  B=build
  SOFT="-Xclang -target-feature -Xclang +soft-mul-div"
fi
mkdir -p $B
first=${1:-1}
count=${2:-10}
CS=/usr/include/csmith
O="-mcpu=v8 $SOFT -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -w -Iinclude -I$CS"
F="--target=sparc-unknown-elf $O"
UF="--target=sparc-unknown-linux-gnu $O"
LD=sparc64-linux-gnu-ld

# clang's integrated assembler mis-resolves these HI22/LO10 relocations: cpp it,
# then GNU as
clang -E -P -x assembler-with-cpp ../sv_asm.S -o $B/sv_asm.s
sparc64-linux-gnu-as -32 -Av8 $B/sv_asm.s -o $B/sv_asm.o
clang $F -c rt.c -o $B/rt.o
clang $UF -DRT_USER -c rt.c -o $B/rt_user.o

pass=0; fail=0; skip=0
for ((s = first; s < first + count; s++)); do
  csmith --seed $s -o $B/s$s.c > /dev/null
  clang $UF -Dmain=csmith_main -c $B/s$s.c -o $B/s${s}_u.o 2> /dev/null &&
    $LD -m elf32_sparc -static -e _start -Ttext=0x400000 -o $B/s${s}_u.elf $B/rt_user.o $B/s${s}_u.o || {
      echo "SKIP seed $s (no user-mode build)"; skip=$((skip+1)); continue; }
  host=$(timeout 60 qemu-sparc $B/s${s}_u.elf | sed -n 's/^checksum = //p')
  if [ -z "$host" ]; then
    echo "SKIP seed $s (qemu run timed out)"; skip=$((skip+1)); continue
  fi
  clang $F -Dmain=csmith_main -c $B/s$s.c -o $B/s$s.o || { echo "FAIL seed $s: compile"; fail=$((fail+1)); continue; }
  $LD -m elf32_sparc -static -e _start -Ttext=0x400000 -o $B/s$s.elf $B/sv_asm.o $B/rt.o $B/s$s.o || {
    echo "FAIL seed $s: link"; fail=$((fail+1)); continue; }
  g6=$(timeout 120 $ISS -d -f $B/s$s.elf 2>&1 | grep '^g0' | awk '{print $14}')
  if [ "$((16#${g6:-0}))" != "$((16#$host))" ]; then
    echo "FAIL seed $s: sparc_iss %g6 $g6, qemu checksum $host"; fail=$((fail+1)); continue
  fi
  log=$B/s$s.core.log
  timeout 1800 $CORE -f $B/s$s.elf > $log 2>&1
  if grep -q "^PASS: RTL and ISS halt" $log; then
    echo "PASS seed $s (checksum $host, $(sed -n 's/^total_retire = //p' $log) retired)"; pass=$((pass+1))
  else
    echo "FAIL seed $s: ooo_core (see $log)"; grep -m3 -E "does not match|DESYNC|no retire|FAIL" $log
    fail=$((fail+1))
  fi
done
echo "csmith: $pass pass, $fail fail, $skip skip"
[ $fail -eq 0 ]
