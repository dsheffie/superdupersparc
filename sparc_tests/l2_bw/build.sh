#!/bin/bash
# ./build.sh <footprint bytes> <tries> -> build/l2bw_<foot>_<tries>.elf
cd "$(dirname "$0")"
F=$1; T=$2
B=build
mkdir -p $B
O="--target=sparc-unknown-elf -mcpu=v8 -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -w -DFOOT=${F}u -DTRIES=${T}u"
[ -f $B/sv_asm.o ] || { clang -E -P -x assembler-with-cpp ../sv_asm.S -o $B/sv_asm.s && sparc64-linux-gnu-as -32 -Av8 $B/sv_asm.s -o $B/sv_asm.o; }
clang $O -c read_bw.c -o $B/l2bw_${F}_${T}.o
sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 -o $B/l2bw_${F}_${T}.elf $B/sv_asm.o $B/l2bw_${F}_${T}.o
