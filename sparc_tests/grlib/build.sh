#!/bin/bash
# Gaisler GRLIB's LEON3 system tests (register file, mul, div, FPU) bare
# metal on sparc_iss / ooo_core.  GRLIB is GPL and is NOT in this tree: point
# GRLIB at an extracted grlib-gpl release (its software/ directory is used), e.g.
#   curl -LO https://www.download.gaisler.com/products/GRLIB/bin/grlib-gpl-2026.3-b4301.tar.gz
#   tar xzf grlib-gpl-2026.3-b4301.tar.gz --wildcards '*/software/systest/*' '*/software/leon3/*'
#   GRLIB=$PWD/grlib-gpl-2026.3-b4301 ./build.sh
# -> build/grlib.elf; %g6 = 0x600d when every test passed (grlib_rt.c).
# The LEON-only tests (CASA, UMAC/SMAC, cache/MMU ASIs, REX, AWP) are left out.
set -e
cd "$(dirname "$0")"
: "${GRLIB:?set GRLIB to an extracted grlib-gpl release}"
X=$GRLIB/software
B=build
mkdir -p $B
# the tests are K&R C
O="--target=sparc-unknown-elf -mcpu=v8 -O2 -std=gnu89 -ffreestanding -fno-builtin -nostdlib -fno-pic -w -I$X/systest/include -DLEON3"
asm() {   # asm <src.S> <obj>; -Aleon only to assemble mulasm.S's umac/smac (never run: no MAC)
  clang -E -P -x assembler-with-cpp -I$X/systest/include -DLEON3 "$1" -o $B/$(basename $2 .o).s
  sparc64-linux-gnu-as -32 -Aleon $B/$(basename $2 .o).s -o $2
}
asm ../sv_asm.S $B/sv_asm.o
asm $X/systest/regtest.S $B/regtest.o
asm $X/systest/mulasm.S $B/mulasm.o
asm $X/leon3/grfpu_ops.S $B/grfpu_ops.o
# mulasm.S's get_asr17 reads %asr17; grlib_rt.c's reports this core's features
sparc64-linux-gnu-objcopy --weaken-symbol=get_asr17 $B/mulasm.o
for f in systest/multest.c systest/divtest.c systest/fpu.c; do
  clang $O -c $X/$f -o $B/$(basename $f .c).o
done
clang $O -c grlib_rt.c -o $B/grlib_rt.o
sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 -o $B/grlib.elf \
  $B/sv_asm.o $B/grlib_rt.o $B/regtest.o $B/mulasm.o $B/grfpu_ops.o \
  $B/multest.o $B/divtest.o $B/fpu.o
echo "built $B/grlib.elf"
