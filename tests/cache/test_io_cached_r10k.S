/*
 * test_io_cached_r10k.S  --  cached accesses to I/O physical space on the IP28 build
 * (ENABLE_R10000; machine.vh IS_IO_PA, l1d.sv): a cached load or store there that
 * retires takes a precise Data Bus Error (Cause.ExcCode 7, EPC = the instruction), as
 * the R10000 does for an ERR completion of a block read; one that is only speculative
 * takes nothing and fills nothing.
 *
 *   1  Spectre-v1 style: a bounds check trained in-bounds 63 times mispredicts on an idx
 *      whose address is cached I/O 0x9f000080 -> 0 DBEs (and, with --watch-va
 *      0xffffffff9f000080 under -c 1, no mem-fill)
 *   2  cached load from 0x9f000000 -> exactly 1 DBE, EPC = that load
 *   3  cached store to 0x9f000000  -> exactly 1 DBE, EPC = that store
 *
 * The handler counts DBEs in $s5, records EPC in $s6 and resumes at EPC+4 (no faulting
 * access sits in a delay slot); any other exception prints FAIL.  Self-contained (own
 * vectors).  RTL SELF-CHECK ONLY (-c 0): the checker's ISS has no I/O-space rule.
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

    .section .except_vec, "ax"
    .org    0x180
    .globl  _vec_gen
_vec_gen:
    mfc0    $k0, $13            /* Cause */
    srl     $k0, $k0, 2
    andi    $k0, $k0, 0x1f      /* ExcCode */
    li      $k1, 7              /* Data Bus Error */
    bne     $k0, $k1, _bad
    nop
    addiu   $s5, $s5, 1
    mfc0    $s6, $14            /* EPC */
    addiu   $k0, $s6, 4
    mtc0    $k0, $14
    nop
    nop
    eret
    nop
_bad:
    SIMCON_PUTLIT('X')
    SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT('\n')
    HALT

    .section .text.startup, "ax"
    .globl  _start
    .type   _start, @function
_start:
    li      $t0, 0x00           /* BEV=0, kernel, EXL=0, ERL=0 */
    mtc0    $t0, $12
    nop
    nop
    move    $s5, $zero          /* DBE count */
    move    $s6, $zero          /* EPC of the last DBE */

    /* ---- 1: trained misprediction onto cached I/O: no DBE ---- */
    li      $s1, 1
    la      $s2, buf            /* kseg0, in bounds */
    la      $s4, bound
    li      $t0, 0x20000000
    or      $s4, $s4, $t0       /* kseg1 alias of bound (=256): slow, uncached */
    li      $s7, 0x9f000080
    subu    $s7, $s7, $s2       /* the out-of-bounds idx: buf + idx = 0x9f000080 */
    li      $t2, 64
    move    $t3, $zero          /* in-bounds idx 0,4,..,252 */
3:
    addiu   $t2, $t2, -1
    move    $t4, $t3
    bnez    $t2, 4f
    nop
    move    $t4, $s7            /* last iteration: out of bounds */
4:
    lw      $t1, 0($s4)         /* bound, late */
    sltu    $t5, $t4, $t1
    beqz    $t5, 5f             /* trained not-taken; taken on the last pass */
    nop
    addu    $t6, $s2, $t4
    lw      $t7, 0($t6)         /* the guarded load: I/O on the last pass, speculatively */
5:
    addiu   $t3, $t3, 4
    bnez    $t2, 3b
    nop
    bnez    $s5, fail
    nop

    /* ---- 2: retired cached I/O load: one DBE at the load ---- */
    li      $s1, 2
    li      $s0, 0x9f000000
    la      $s3, ld_io
ld_io:
    lw      $t1, 0($s0)
    li      $t0, 1
    bne     $s5, $t0, fail
    nop
    bne     $s6, $s3, fail
    nop

    /* ---- 3: retired cached I/O store: one DBE at the store ---- */
    li      $s1, 3
    la      $s3, st_io
st_io:
    sw      $t0, 0($s0)
    li      $t0, 2
    bne     $s5, $t0, fail
    nop
    bne     $s6, $s3, fail
    nop

    SIMCON_PUTLIT('P')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('S')
    SIMCON_PUTLIT('\n')
    HALT

fail:
    addiu   $t9, $s1, 0x30
    SIMCON_PUTCHAR($t9)
    SIMCON_PUTLIT('F')
    SIMCON_PUTLIT('A')
    SIMCON_PUTLIT('I')
    SIMCON_PUTLIT('L')
    SIMCON_PUTLIT('\n')
    HALT
    .size   _start, . - _start

    .data
    .align  4
bound:
    .word   256
    .align  8
buf:
    .space  256
