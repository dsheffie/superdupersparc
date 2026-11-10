#!/bin/bash
# Dhrystone 2.1 bare metal on sparc_iss / ooo_core: ./build.sh [runs]
# -> build/dhry_<runs>.elf; %g6 = 0x600d when every final value checks out.
# Hardware umul/sdiv (as a SuperSPARC), -O2.
cd "$(dirname "$0")"
RUNS=${1:-2000}
B=build
mkdir -p $B
O="--target=sparc-unknown-elf -mcpu=v8 -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -w -Iinc -DDHRY_RUNS=$RUNS"
clang -E -P -x assembler-with-cpp ../sv_asm.S -o $B/sv_asm.s
sparc64-linux-gnu-as -32 -Av8 $B/sv_asm.s -o $B/sv_asm.o
clang $O -c dhry21a.c -o $B/dhry21a_$RUNS.o
clang $O -c dhry21b.c -o $B/dhry21b.o
clang $O -c dhry_rt.c -o $B/dhry_rt.o
sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 -o $B/dhry_$RUNS.elf \
  $B/sv_asm.o $B/dhry_rt.o $B/dhry21a_$RUNS.o $B/dhry21b.o
