#!/bin/bash
# Boot the real SS-10/20 OBP on sparc_iss and on qemu's matching SS-20, and
# report the first instruction where the executed-PC streams differ.
#   usage: obp_diff.sh <obp rom image> [seconds of qemu = trace length, default 12]
# Reference machine = TI SuperSPARC (Viking) in MBus mode, the CPU sparc_iss models:
#   qemu-system-sparc -M SS-20 -cpu TI-SuperSparc-40 -m 256 -vga none -nographic
# (-nographic matters: it disables qemu's keyboard ESCC the way sun4m.cc does)
# Trapped insns appear twice in qemu's exec log, so both streams are uniq'd.
set -e
ROM=$(realpath "$1"); SECS=${2:-12}
cd "$(dirname "$0")"
B=build/obp; mkdir -p $B; rm -f $B/qfifo; mkfifo $B/qfifo
(grep -o "Trace [^]]*\]" < $B/qfifo | awk -F'[[/]' '{print substr($3,9)}' | uniq > $B/qemu.pcs) &
timeout $SECS qemu-system-sparc -M SS-20 -cpu TI-SuperSparc-40 -m 256 -bios "$ROM" -vga none \
  -nographic -serial null -monitor none -accel tcg,one-insn-per-tb=on -d exec,nochain -D $B/qfifo \
  > /dev/null 2>&1 || true
wait; rm -f $B/qfifo
N=$(wc -l < $B/qemu.pcs)
../sparc_iss --rom "$ROM" --nvram ss20_nvram.bin --ram 256 -m $((N + N / 4)) --pctrace $B/iss.raw \
  > $B/iss.console 2> $B/iss.err || true
uniq $B/iss.raw > $B/iss.pcs
echo "qemu: $N pcs; iss console: $(tr -d '\r' < $B/iss.console | strings | head -1)"
if cmp -s <(head -n $N $B/iss.pcs) $B/qemu.pcs; then
  echo "MATCH for all $N pcs"
else
  L=$(cmp <(head -n $N $B/iss.pcs) $B/qemu.pcs | awk '{print $NF}')
  echo "first divergence at pc #$L (iss / qemu):"
  paste $B/iss.pcs $B/qemu.pcs | sed -n "$((L > 3 ? L - 3 : 1)),$((L + 2))p"
fi
