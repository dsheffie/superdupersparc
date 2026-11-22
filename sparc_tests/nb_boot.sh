#!/bin/bash
# nb_boot.sh [disk.img] [ooo_core args...]: build nb_boot.elf (NetBSD/sparc
# bootxx + /boot under a fake OBP, see nb_boot.c) from a NetBSD sparc disk image
# and run it on ooo_core with the checker.  MMU on, low 16 MB identity mapped and
# uncacheable (nb_ptab.S), as OBP runs the boot block: fails if the L1I keeps
# uncached fills.
set -e
cd "$(dirname "$0")"
DISK=${1:-$HOME/netbsd/nbsd.img}
shift || true
B=build
mkdir -p $B
python3 - "$DISK" << 'EOF'
import struct, sys
d = open(sys.argv[1], 'rb')
d.seek(512)
bb = d.read(15 * 512)                 # the boot block (sectors 1-15)
assert struct.unpack('>I', bb[0:4])[0] & 0xffff == 0x0107, 'no a.out OMAGIC'
open('build/nb_bootxx.bin', 'wb').write(bb[32:])   # text at 0x4000
i = bb.find(b'NetBSD/sparc bootxx')
bs, cnt = struct.unpack('>ii', bb[i + 32:i + 40])
tab = struct.unpack('>%di' % cnt, bb[i + 40:i + 40 + 4 * cnt])
# partition a starts at sector 0 on this disk (Sun label); blocks are DEV_BSIZE
out = b''
for blk in tab:
    d.seek(blk * 512)
    out += d.read(bs)
open('build/nb_boot_blocks.bin', 'wb').write(out)
print('bootxx %d bytes, /boot %d blocks of %d: %s' % (len(bb) - 32, cnt, bs, tab))
EOF
F="--target=sparc-unknown-none-elf -mcpu=v8 -O2 -ffreestanding -fno-pic -fno-builtin -nostdlib"
clang $F -c nb_boot.c -o $B/nb_boot.o
clang $F -c nb_blobs.S -o $B/nb_blobs.o
clang -E -P -x assembler-with-cpp nb_ptab.S -o $B/nb_ptab.s
sparc64-linux-gnu-as -32 $B/nb_ptab.s -o $B/nb_ptab.o
clang -E -P -x assembler-with-cpp sv_asm.S -o $B/nb_sv.s
sparc64-linux-gnu-as -32 $B/nb_sv.s -o $B/nb_sv.o
sparc64-linux-gnu-ld -m elf32_sparc -static -e _start -Ttext=0x400000 --section-start=.ptab=0x800000 \
  -o $B/nb_boot.elf $B/nb_sv.o $B/nb_boot.o $B/nb_blobs.o $B/nb_ptab.o
timeout 1800 ../ooo_core -f $B/nb_boot.elf --mmu-ctrl 0x901 --mmu-ctpr 0x80000 --mmu-ctx 0 "$@" > $B/nb_boot.rtl.log 2>&1 || true
grep -a -m3 -E 'does not match|COSIM DESYNC|BAD FETCH|^PASS|^FAIL|STORE DIVERGENCE' $B/nb_boot.rtl.log || tail -5 $B/nb_boot.rtl.log
grep -a 'instructions retired' $B/nb_boot.rtl.log
