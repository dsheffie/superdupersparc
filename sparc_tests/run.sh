#!/bin/bash
# Build + check the SPARC V8 ISS tests.  clang compiles (-mcpu=v8), binutils
# links (ld.lld 18 cannot link 32-bit SPARC): apt binutils-sparc64-linux-gnu.
#   cc, fp:          sparc_iss --user vs qemu-sparc
#   fib, div:        vs the same C on the host (qemu-sparc 8.2.2 gets SDIV with a
#                    negative divisor wrong, and both of these do that)
#   sv:              bare-metal supervisor traps/windows, checked against known values
set -e
cd "$(dirname "$0")"
ISS=../sparc_iss
B=build
mkdir -p $B
F="-mcpu=v8 -O2 -ffreestanding -fno-pic -fno-builtin -nostdlib"
UF="--target=sparc-unknown-linux-gnu $F"
fail=0
LD=sparc64-linux-gnu-ld
link() { out=$1; shift; $LD -m elf32_sparc -static -e _start -Ttext=0x400000 -o $out "$@"; }

for t in fib fp div; do
  clang $UF -c $t.c -o $B/$t.o
  link $B/$t.elf $B/$t.o
done
clang $UF -c cc.c -o $B/cc_c.o
clang $UF -c cc_asm.S -o $B/cc_asm.o
link $B/cc.elf $B/cc_c.o $B/cc_asm.o
for t in fp cc; do
  qemu-sparc $B/$t.elf > $B/$t.qemu
  $ISS -u -f $B/$t.elf > $B/$t.iss 2> /dev/null
  if cmp -s $B/$t.qemu $B/$t.iss; then echo "PASS $t ($(wc -l < $B/$t.iss) values)"; else echo "FAIL $t"; fail=1; fi
done

for t in fib div; do
  sed -e 's/#include "crt.h"/#include <stdio.h>\n#define puthex(v) printf("0x%08x\\n",(unsigned)(v))\n#define puts_(s) printf("%s",s)/' $t.c > $B/${t}_host.c
  cc -O0 -o $B/${t}_host $B/${t}_host.c
  $B/${t}_host > $B/$t.host
  $ISS -u -f $B/$t.elf > $B/$t.iss 2> /dev/null
  if cmp -s $B/$t.host $B/$t.iss; then echo "PASS $t (vs host)"; else echo "FAIL $t"; fail=1; fi
done

SF="--target=sparc-unknown-elf $F"
# bare-metal: run to error mode; prints "g5 g6 g7"
bare() { $ISS -d -f $1 2>&1 | grep '^g0' | awk '{print $12, $14, $16}'; }
clang $SF -c sv_asm.S -o $B/sv_asm.o
clang $SF -c mmu.c -o $B/mmu_c.o
link $B/mmu.elf $B/sv_asm.o $B/mmu_c.o
read g5 g6 g7 <<< "$(bare $B/mmu.elf)"
if [ "${g7:5:3}" == "ff0" ] && [ "$g6" == "00000000" ]; then
  echo "PASS mmu (SRMMU walk, R/M, faults, probe, bypass)"
else
  echo "FAIL mmu: failed-check mask g6=$g6 g7=$g7"; fail=1
fi

clang $SF -c sv_asm.S -o $B/sv_asm.o
clang $SF -c intc.c -o $B/intc_c.o
link $B/intc.elf $B/sv_asm.o $B/intc_c.o
regs=$($ISS --sun4m -d -f $B/intc.elf 2>&1 | grep '^g0')
g6=$(echo "$regs" | awk '{print $14}'); g7=$(echo "$regs" | awk '{print $16}')
if [ "${g7:5:3}" == "ff0" ] && [ "$g6" == "00000000" ]; then
  echo "PASS intc (soft ints, PIL masking, level 15)"
else
  echo "FAIL intc: failed-check mask g6=$g6 g7=$g7"; fail=1
fi
clang $SF -c sv.c -o $B/sv_c.o
link $B/sv.elf $B/sv_asm.o $B/sv_c.o
regs=$($ISS -d -f $B/sv.elf 2>&1 | grep '^g0')
g5=$(echo "$regs" | awk '{print $12}'); g6=$(echo "$regs" | awk '{print $14}'); g7=$(echo "$regs" | awk '{print $16}')
# g7 = %tbr at the final trap: tt (bits 11:4) 0xff is the clean exit
if [ "${g7:5:3}" == "ff0" ] && [ "$g6" == "00004593" ] && [ "$g5" == "000003db" ]; then
  echo "PASS sv (traps, window spill/fill, jmpl;rett)"
else
  echo "FAIL sv: g5=$g5 g6=$g6 g7=$g7"; fail=1
fi
exit $fail
