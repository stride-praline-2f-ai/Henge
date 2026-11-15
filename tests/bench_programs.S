// Benchmarks: typical guest code shapes, timed natively and through the JIT
// by test_bench.c (not part of `make test`; run build/test_bench by hand).
#include "harness.h"

    .text
    .p2align 14
    .globl _bench_programs_begin
    .globl _bench_programs_finish
_bench_programs_begin:

// Calls with frames: fib(24) recursively, the way compiled code does it.
PROGRAM bench_calls
    mov x0, #24
    bl fib_b
    b 9f
fib_b:
    cmp x0, #2
    b.lo 2f
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    sub x0, x0, #1
    bl fib_b
    mov x20, x0
    sub x0, x19, #2
    bl fib_b
    add x0, x0, x20
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
2:  ret
9:
END bench_calls

// Loads and stores: read-modify-write a 8 KB buffer below SP, 256 times.
PROGRAM bench_mem
    mov x9, #256
3:  sub x1, sp, #8192
    mov x2, #1024
    mov x3, #0
4:  ldr x4, [x1]
    add x3, x3, x4
    eor x5, x3, x2
    str x5, [x1], #8
    subs x2, x2, #1
    b.ne 4b
    subs x9, x9, #1
    b.ne 3b
END bench_mem

// Consecutive ordinary loads separated by address increments. This isolates
// the new planner extension; it does not stand in for macOS/game performance.
PROGRAM bench_iter_load
    sub x23, sp, #8192
    mov x4, #7
    stp x4, x4, [x23]
    stp x4, x4, [x23, #16]
    mov x0, #0
    movz x2, #0x4, lsl #16
1:  sub x23, sp, #8192
    ldr x4, [x23]
    add x23, x23, #8
    ldr x6, [x23]
    add x23, x23, #8
    ldp x7, x8, [x23]
    add x0, x0, x4
    add x0, x0, x6
    add x0, x0, x7
    add x0, x0, x8
    subs x2, x2, #1
    b.ne 1b
    mov x5, #0
END bench_iter_load

// Fixed-base loads with ordinary ALU between them, like object/stack access.
PROGRAM bench_stream
    sub x23, sp, #8192
    mov x4, #7
    stp x4, x4, [x23]
    stp x4, x4, [x23, #16]
    mov x0, #0
    movz x2, #0x100, lsl #16
1:  ldr x4, [x23]
    add x0, x0, x4
    ldr x5, [x23, #8]
    add x0, x0, x5
    ldr x19, [x23, #16]
    add x0, x0, x19
    ldr x20, [x23, #24]
    add x0, x0, x20
    subs x2, x2, #1
    b.ne 1b
    mov x5, #0
END bench_stream

// Three-field object access: selected reuse must help without a fourth load.
PROGRAM bench_stream3
    sub x23, sp, #8192
    mov x4, #7
    stp x4, x4, [x23]
    str x4, [x23, #16]
    mov x0, #0
    movz x2, #0x100, lsl #16
1:  ldr x4, [x23]
    add x0, x0, x4
    ldr x5, [x23, #8]
    add x0, x0, x5
    ldr x19, [x23, #16]
    add x0, x0, x19
    subs x2, x2, #1
    b.ne 1b
    mov x5, #0
END bench_stream3

// An interpreter loop: a jump table and BR, 300000 times.
PROGRAM bench_dispatch
    adr x10, 7f
    movz x2, #0x4, lsl #16
    movk x2, #0x93e0
    mov x5, #0
5:  and x3, x2, #3
    ldrsw x4, [x10, x3, lsl #2]
    add x4, x10, x4
    br x4
10: add x5, x5, #1
    b 6f
11: eor x5, x5, x2
    b 6f
12: lsl x6, x5, #1
    add x5, x6, x5
    b 6f
13: sub x5, x5, #7
6:  subs x2, x2, #1
    b.ne 5b
    b 8f
    .p2align 2
7:  .word 10b - 7b, 11b - 7b, 12b - 7b, 13b - 7b
8:
END bench_dispatch

// Block transitions: a two-instruction loop, one chained exit per iteration.
PROGRAM bench_loop
    movz x2, #0x10, lsl #16
1:  subs x2, x2, #1
    b.ne 1b
END bench_loop

    .p2align 14 /* whole pages, or the TLB will not map the last one */
PROGRAM bench_stream2
    sub x23, sp, #8192
    mov x4, #7
    stp x4, x4, [x23]
    mov x0, #0
    movz x2, #0x100, lsl #16
1:  ldr x4, [x23]
    add x0, x0, x4
    ldr x5, [x23, #8]
    add x0, x0, x5
    subs x2, x2, #1
    b.ne 1b
    mov x5, #0
END bench_stream2

    .p2align 14
_bench_programs_finish:
