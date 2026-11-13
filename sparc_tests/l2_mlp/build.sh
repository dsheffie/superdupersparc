#!/bin/bash
# ./build.sh <K lists> <footprint bytes> <steps> -> build/mlp_<K>_<foot>_<steps>.elf
cd "$(dirname "$0")"
K=$1; F=$2; T=$3
B=build
mkdir -p $B
O="--target=sparc-unknown-elf -mcpu=v8 -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic -w -DK=$K -DFOOT=${F}u -DSTEPS=${T}u"
[ -f $B/sv_asm.o ] || { clang -E -P -x assembler-with-cpp ../sv_asm.S -o $B/sv_asm.s && sparc64-linux-gnu-as -32 -Av8 $B/sv_asm.s -o $B/sv_asm.o; }
clang $O -c mlp.c -o $B/mlp_${K}_${F}_${T}.o
sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 -o $B/mlp_${K}_${F}_${T}.elf $B/sv_asm.o $B/mlp_${K}_${F}_${T}.o
