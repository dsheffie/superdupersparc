#!/bin/bash
# Dhrystone 2.1 exactly as Kodiak ran it under Solaris (509 cycles/run on silicon):
# a_<runs>.o + dhry21b.o = SC4.2 cc -xO4 -xcg92 -dalign on Solaris 2.5.1 (dhry21a.c with
# Number_Of_Runs = DHRY_RUNS), lc/ = Solaris libc.a strcpy/strcmp/memcpy (Sun binaries:
# do NOT commit), sc_rt.c = stdio stubs + a main that checks the final values (%g6 = 0x600d).
#   ./build.sh  -> dhry_sc_2000.elf dhry_sc_4000.elf  (per-run cost = the difference)
#   ../../../ooo_core -f dhry_sc_4000.elf --branch br.txt
cd "$(dirname "$0")"
for n in 2000 4000; do
  sparc64-linux-gnu-objcopy --redefine-sym main=dhry_main a_$n.o am_$n.o
  clang --target=sparc-unknown-elf -mcpu=v8 -O2 -ffreestanding -fno-builtin -nostdlib -fno-pic \
    -DDHRY_RUNS=$n -c sc_rt.c -o rt_$n.o
  sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 -o dhry_sc_$n.elf \
    ../build/sv_asm.o rt_$n.o am_$n.o dhry21b.o lc/strcpy.o lc/strcmp.o lc/memcpy.o 2>/dev/null
done
ls -l dhry_sc_*.elf
