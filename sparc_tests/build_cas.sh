#!/bin/bash
# build_cas.sh: build cas.S (casa, -Aleon) as build/cas_<FAULT>.elf, FAULT 0-6
cd "$(dirname "$0")"
for n in 0 1 2 3 4 5 6; do
  clang -E -P -x assembler-with-cpp -DFAULT=$n cas.S -o build/cas_$n.s &&
  sparc64-linux-gnu-as -32 -Aleon build/cas_$n.s -o build/cas_$n.o &&
  sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 \
    --section-start=.ptab=0x800000 --section-start=.pages=0x900000 \
    -o build/cas_$n.elf build/cas_$n.o || exit 1
done
