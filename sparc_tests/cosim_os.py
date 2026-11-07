#!/usr/bin/env python3
"""cosim_os.py: co-simulate ooo_core against the checker ISS from random points
in an OS run.

ss10sim runs the OS (from power-on, or from --base-ckpt) and
writes a checkpoint at each of --points random icounts in [--from, --to); each
checkpoint gets a snapshot of the writable disks as they were at that instant.
As each one appears, ooo_core resumes it with the checker for --rtl-icnt
retired instructions (--jobs at a time) on its own copy of the disks.  Results
go to <workdir>/results.tsv; per-point logs stay in <workdir>/pNN/.

--exec samples executed instructions instead of icount: --from/--to count
only the instructions ss10sim actually runs from the start (icount also
advances while the CPU idles halted, so icount samples mostly land in the
idle loop).

--iss-args is the ss10sim machine/boot setup (--rom ...); every segment needs
it, since a restore replaces the state that setup creates.  Relative paths in
it resolve from the ss10sim directory.

Disks: --disk ID:image (copied, written by the run) and --cdrom ID:image (read
only, shared).  --dev passes device flags both simulators need to restore the
checkpoints (e.g. --cg14).  --first-args are extra ss10sim arguments for the
first segment only (e.g. --kbd-input to get past a prompt).

  ./cosim_os.py --workdir /tmp/lnx --points 8 --from 9.5e8 --to 3e9 \\
      --iss-args "--rom /usr/share/qemu/openbios-sparc32 --nvram ss20_nvram.bin --ram 256 \\
                  --kernel ../linux-sparc32/vmlinux --append 'console=ttyS0 root=/dev/sda rw'" \\
      --disk 0:../../ss10sim/guest/root.img
"""
import argparse
import concurrent.futures as cf
import os
import random
import re
import shlex
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FAIL_RE = re.compile(r'does not match|COSIM DESYNC|^FAIL:|STORE DIVERGENCE')


def copy_sparse(src, dst):
    subprocess.check_call(['cp', '--sparse=always', src, dst])


def disk_args(flag, specs, paths):
    out = []
    for (dev_id, _), p in zip(specs, paths):
        out += [flag, '%s:%s' % (dev_id, p)]
    return out


def parse_specs(specs):
    out = []
    for s in specs:
        dev_id, path = s.split(':', 1)
        out.append((dev_id, os.path.abspath(path)))
    return out


def run_rtl(a, idx, ckpt, icnt, pc, snaps, pdir):
    """ooo_core with the checker from one checkpoint, on its own disk copies"""
    disks = []
    for (dev_id, _), snap in zip(a.disks, snaps):
        d = os.path.join(pdir, 'rtl_disk%s.img' % dev_id)
        copy_sparse(snap, d)
        disks.append(d)
    cmd = [a.ooo_core, '--checkpoint', ckpt, '--maxicnt', str(a.rtl_icnt)] + shlex.split(a.dev)
    cmd += disk_args('--scsi-disk', a.disks, disks) + disk_args('--scsi-cdrom', a.cdroms, [p for _, p in a.cdroms])
    log = os.path.join(pdir, 'rtl.log')
    with open(log, 'w') as f:
        f.write('# ' + ' '.join(shlex.quote(c) for c in cmd) + '\n')
        f.flush()
        rc = subprocess.call(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=os.path.dirname(a.ooo_core))
    first_fail, retired = '', 0
    with open(log, errors='replace') as f:
        for line in f:
            if not first_fail and FAIL_RE.search(line):
                first_fail = line.strip()
            m = re.match(r'total_retire = (\d+)', line)
            if m:
                retired = int(m.group(1))
    for d in disks:
        os.remove(d)
    if first_fail:
        result = 'FAIL'
    elif retired >= a.rtl_icnt:
        result = 'pass'
    else:
        result = 'short(rc=%d)' % rc
    return idx, icnt, pc, result, retired, first_fail


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--workdir', required=True)
    ap.add_argument('--ss10sim', default=os.path.join(HERE, '../../ss10sim/ss10sim'))
    ap.add_argument('--ooo-core', default=os.path.join(HERE, '../ooo_core'))
    ap.add_argument('--iss-args', required=True, help='ss10sim machine/boot arguments (--rom ...)')
    ap.add_argument('--base-ckpt', help='start from this ss10sim checkpoint instead of power-on')
    ap.add_argument('--first-args', default='', help='extra ss10sim arguments for the first segment')
    ap.add_argument('--dev', default='', help='device flags both simulators need (e.g. --cg14)')
    ap.add_argument('--disk', action='append', default=[], help='ID:image, writable (copied)')
    ap.add_argument('--cdrom', action='append', default=[], help='ID:image, read only')
    ap.add_argument('--points', type=int, default=8)
    ap.add_argument('--from', dest='lo', type=float, required=True, help='first icount to sample')
    ap.add_argument('--to', dest='hi', type=float, required=True, help='last icount to sample')
    ap.add_argument('--rtl-icnt', type=int, default=2000000, help='instructions to co-simulate per point')
    ap.add_argument('--jobs', type=int, default=8)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--exec', action='store_true', help='--from/--to are executed instructions, not icount')
    ap.add_argument('--iss-timeout', type=int, default=3600, help='seconds per ss10sim segment')
    a = ap.parse_args()
    a.ss10sim = os.path.abspath(a.ss10sim)
    a.ooo_core = os.path.abspath(a.ooo_core)
    a.disks = parse_specs(a.disk)
    a.cdroms = parse_specs(a.cdrom)
    os.makedirs(a.workdir, exist_ok=True)

    rng = random.Random(a.seed)
    points = sorted(int(rng.uniform(a.lo, a.hi)) for _ in range(a.points))
    # the chain's working disks, advanced in place segment by segment
    work = []
    for dev_id, path in a.disks:
        w = os.path.join(a.workdir, 'work_disk%s.img' % dev_id)
        copy_sparse(path, w)
        work.append(w)

    prev = os.path.abspath(a.base_ckpt) if a.base_ckpt else None
    last = 0
    pool = cf.ThreadPoolExecutor(max_workers=a.jobs)
    futs = []
    for i, target in enumerate(points):
        pdir = os.path.join(a.workdir, 'p%02d' % i)
        os.makedirs(pdir, exist_ok=True)
        ckpt = os.path.join(pdir, 'point.ckpt')
        cmd = [a.ss10sim] + shlex.split(a.iss_args)
        cmd += shlex.split(a.dev)
        cmd += disk_args('--scsi-disk', a.disks, work) + disk_args('--scsi-cdrom', a.cdroms, [p for _, p in a.cdroms])
        if prev is not None:
            cmd += ['--restore', prev]
        if i == 0:
            cmd += shlex.split(a.first_args)
        if a.exec:
            # executed instructions since this segment's start
            cmd += ['--checkpoint-after-exec', str(max(1, target - last)), '--checkpoint-out', ckpt]
        else:
            # the CPU may be idling halted at the target: leave slack for the
            # first boundary a checkpoint can be written at
            cmd += ['--checkpoint-at', str(target), '--checkpoint-out', ckpt, '-m', str(target + 4000000000)]
        last = target
        with open(os.path.join(pdir, 'iss.log'), 'w') as f:
            f.write('# ' + ' '.join(shlex.quote(c) for c in cmd) + '\n')
            f.flush()
            try:
                subprocess.call(cmd, stdout=f, stderr=subprocess.STDOUT, cwd=os.path.dirname(a.ss10sim),
                                timeout=a.iss_timeout)
            except subprocess.TimeoutExpired:
                f.write('# timed out after %d s\n' % a.iss_timeout)
        m = None
        with open(os.path.join(pdir, 'iss.log'), errors='replace') as f:
            for line in f:
                mm = re.search(r'checkpoint: wrote .* at icnt (\d+) pc (0x[0-9a-f]+)', line)
                if mm:
                    m = mm
        if m is None:
            print('p%02d: no checkpoint at %d (see %s/iss.log); stopping the chain' % (i, target, pdir))
            break
        icnt, pc = int(m.group(1)), m.group(2)
        snaps = []
        for (dev_id, _), w in zip(a.disks, work):
            snap = os.path.join(pdir, 'disk%s.img' % dev_id)
            copy_sparse(w, snap)
            snaps.append(snap)
        print('p%02d: checkpoint at icnt %d pc %s; co-simulating %d instructions' % (i, icnt, pc, a.rtl_icnt), flush=True)
        futs.append(pool.submit(run_rtl, a, i, ckpt, icnt, pc, snaps, pdir))
        prev = ckpt

    rows = sorted(f.result() for f in futs)
    with open(os.path.join(a.workdir, 'results.tsv'), 'w') as f:
        f.write('point\ticnt\tpc\tresult\tretired\tfirst_failure\n')
        for r in rows:
            f.write('p%02d\t%d\t%s\t%s\t%d\t%s\n' % r)
    for r in rows:
        print('p%02d icnt %-13d pc %-10s %-12s retired %-9d %s' % r)
    n_fail = sum(1 for r in rows if r[3] != 'pass')
    print('%d points, %d not passing' % (len(rows), n_fail))
    return 1 if n_fail else 0


if __name__ == '__main__':
    sys.exit(main())
