/*
 * test_io_cached_r4k.S  --  cached accesses to I/O physical space (machine.vh IS_IO_PA,
 * l1d.sv): on IP22 a cached load there reads 0, a cached store is dropped, and nothing
 * is ever filled or allocated -- above all not for a WRONG-PATH load, which on silicon
 * reached the MC's unsquashable GIO time-out (IRIX "GIO Error ... TIME" panic).
 * In the bare ooo_core harness PA 0x1f000000 is plain memory, so the effects show.
 *
 *   4  (runs FIRST) Spectre-v1 style: a trained bounds-check branch mispredicts on an
 *      out-of-bounds idx whose address is cached I/O 0x9f000080; expect NO mem-fill of
 *      it (--watch-va 0xffffffff9f000080).
 *   3  (runs next, so a checker run's --watch-va sees it before case 1 diverges)
 *   1  seed 0x5555 uncached (kseg1 0xbf000000); a cached load (kseg0 0x9f000000) -> 0
 *   2  a cached store of 0x7777 there is dropped: the uncached reload -> 0x5555
 *   3  wrong path: 16 always-taken branches resolved late by an uncached load, each
 *      with a cached load of 0x9f000040 in its (cold) fall-through.  Self-check can't
 *      see a fill; run with --watch-va 0xffffffff9f000040 and expect NO mem-fill.
 *
 * RTL SELF-CHECK (-c 0) for cases 1-2: the checker's ISS has no I/O-space rule, so under
 * -c 1 it diverges at case 1 -- use -c 1 only to watch case 3's fills (--watch-va needs it).  IP22 build
 * (no ENABLE_R10000).
 */

#include "sim.h"

    .set    mips3
    .set    noreorder
    .set    noat

    .macro  HALT
    li      $k0, 0xBFD00000
    li      $k1, 1
    sw      $k1, 0($k0)
1:  b       1b
    nop
    .endm

    .text
    .globl  main
    .type   main, @function
main:
    addiu   $sp, $sp, -8
    sw      $ra, 4($sp)

    la      $a0, msg_start
    jal     puts_sim
    nop

    li      $s0, 0x9f000000        /* kseg0: cached, PA 0x1f000000 (I/O space) */
    li      $s2, 0xbf000000        /* kseg1: the same PA, uncached */

    li      $s1, 4
    /* Spectre-v1 style: train "idx < bound -> load buf+idx" 63 times in bounds, then
     * an idx that puts buf+idx at cached I/O 0x9f000080.  Architecturally the check
     * fails and the load is skipped; the trained predictor runs it speculatively. */
    la      $s6, buf               /* kseg0, in bounds */
    la      $s4, bound
    li      $t0, 0x20000000
    or      $s4, $s4, $t0          /* kseg1 alias of bound (=256): slow, uncached */
    li      $s7, 0x9f000080
    subu    $s7, $s7, $s6          /* the out-of-bounds idx: buf + idx = 0x9f000080 */
    li      $t2, 64
    move    $t3, $zero             /* in-bounds idx, stepping 0,4,..,252 */
3:
    addiu   $t2, $t2, -1
    move    $t4, $t3
    bnez    $t2, 4f
    nop
    move    $t4, $s7               /* last iteration: out of bounds */
4:
    lw      $t1, 0($s4)            /* bound, late */
    sltu    $t5, $t4, $t1
    beqz    $t5, 5f                /* trained not-taken; taken on the last pass */
    nop
    addu    $t6, $s6, $t4
    lw      $t7, 0($t6)            /* the guarded load: I/O on the last pass, speculatively */
5:
    addiu   $t3, $t3, 4
    bnez    $t2, 3b
    nop

    li      $s1, 3
    li      $s3, 0x9f000040        /* cached I/O address, only ever on the wrong path */
    la      $s4, flag
    li      $t0, 0x20000000
    or      $s4, $s4, $t0          /* kseg1 alias of flag (=1): a slow, uncached load */
    .rept   16
    lw      $t1, 0($s4)            /* resolves the branch late */
    bnez    $t1, 2f                /* always taken; cold -> may fall through speculatively */
    nop
    lw      $t5, 0($s3)            /* WRONG PATH ONLY */
    lw      $t6, 8($s3)
2:
    .endr

    li      $s1, 1
    li      $t1, 0x5555
    sw      $t1, 0($s2)            /* seed through the uncached alias */
    lw      $v0, 0($s0)            /* cached: must read 0 */
    bnez    $v0, fail
    nop

    li      $s1, 2
    li      $t1, 0x7777
    sw      $t1, 0($s0)            /* cached store: dropped */
    sync
    lw      $v0, 0($s2)            /* uncached: still the seed */
    li      $t1, 0x5555
    bne     $v0, $t1, fail
    nop
    lw      $v0, 0($s0)            /* and the cached view still reads 0 */
    bnez    $v0, fail
    nop

    la      $a0, msg_pass
    jal     puts_sim
    nop
    HALT

fail:
    addiu   $t9, $s1, 0x30
    SIMCON_PUTCHAR($t9)
    la      $a0, msg_fail
    jal     puts_sim
    nop
    HALT
    .size   main, . - main

    .globl  puts_sim
    .type   puts_sim, @function
puts_sim:
1:  lb      $t9, 0($a0)
    beqz    $t9, 2f
    nop
    SIMCON_PUTCHAR($t9)
    b       1b
    addiu   $a0, $a0, 1
2:  jr      $ra
    nop
    .size   puts_sim, . - puts_sim

    .data
    .align  4
flag:
    .word   1

    .align  4
bound:
    .word   256
    .align  8
buf:
    .space  256

    .section .rodata
msg_start: .asciz "test_io_cached_r4k: cached accesses to I/O space\n"
msg_pass:  .asciz "PASS\n"
msg_fail:  .asciz "FAIL\n"
