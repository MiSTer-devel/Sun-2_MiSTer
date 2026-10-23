| p08's faulted loop-mode RMW, run in user mode, with an interrupt that the
| harness raises a programmable number of clocks after the handler maps the
| page -- so a sweep over that delay puts the interrupt on every boundary of
| the RTE, the resumed and.l and the DBcc that re-enters loop mode.

    .include "rd68011.inc"

    .equ    BUF,     0x3002
    .equ    NLONG,   100
    .equ    ARM,     0x0500
    .equ    DISARM,  0x0502
    .equ    PAT,     0x5A3C96E1

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    PROGRAM_BEGIN
    CHECK   20
    movea.l #BUF-4,%a0
    move.w  #NLONG+1,%d0
2:  move.l  #-1,(%a0)+
    dbf     %d0,2b
    clr.w   fault_count
    clr.w   irq_count
    lea     user_stack_top,%a0
    move.l  %a0,%usp
    move.l  #user,-(%sp)            | RTE into user mode, interrupts open
    move.w  #0x0000,-(%sp)
    move.w  #1,ARM
    rte
user:
    movea.l #BUF,%a4
    move.l  #PAT,%d6
    move.l  #0x11111111,%d1
    move.l  #0x22222222,%d2
    move.l  #0x33333333,%d3
    moveq   #-1,%d5
    move.w  #NLONG-1,%d4
1:  and.l   %d6,(%a4)+
    dbf     %d4,1b
    trap    #0                      | back to supervisor to check
back:
    move.w  #1,DISARM
    cmpa.l  #BUF+4*NLONG,%a4
    bne     fail
    cmpi.w  #-1,%d4
    bne     fail
    EXPECT_EQ_L %d6, PAT
    EXPECT_EQ_L %d5, -1
    EXPECT_EQ_L %d1, 0x11111111
    EXPECT_EQ_L %d2, 0x22222222
    EXPECT_EQ_L %d3, 0x33333333
    move.w  fault_count,%d0
    EXPECT_EQ_W %d0, 1
    move.w  trace_count,%d0
    EXPECT_EQ_W %d0, 1
    CHECK   21
    movea.l #BUF,%a0
    move.w  #NLONG-1,%d0
3:  cmpi.l  #PAT,(%a0)+
    bne     fail
    dbf     %d0,3b
    cmpi.l  #-1,(%a0)
    bne     fail
    cmpi.l  #-1,BUF-4
    bne     fail
    bra     pass

    .globl  v_trap
v_trap:
    move.w  #0x2700,%sr
    addq.l  #8,%sp                  | drop the trap frame (format 0, 8 bytes)
    bra     back

    .globl  v_bus
v_bus:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    addq.w  #1,fault_count
    move.w  #1,DISARM               | the page is in; the harness counts from here
    ori.w   #0x8000,15*4(%sp)       | SunOS: T set to take the pending AST
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    rte

    .globl  v_trace
v_trace:
    addq.w  #1,trace_count
    andi.w  #0x7FFF,(%sp)
    | SunOS reschedules here: other processes run, loop mode and all
    movem.l %d0-%d2/%a0,-(%sp)
    movea.l #0x4802,%a0
    move.l  #0x0F0F0F0F,%d1
    moveq   #31,%d2
7:  and.l   %d1,(%a0)+
    dbf     %d2,7b
    movem.l (%sp)+,%d0-%d2/%a0
    rte

    .globl  v_irq
v_irq:
    addq.w  #1,irq_count
    rte

    .globl  v_addr
v_addr = v_unexpected
    UNEXPECTED_HANDLER
    .globl  v_illegal, v_divzero, v_chk, v_trapv, v_priv
    .globl  v_linea, v_linef, v_format
v_illegal = v_unexpected
v_divzero = v_unexpected
v_chk     = v_unexpected
v_trapv   = v_unexpected
v_priv    = v_unexpected
v_linea   = v_unexpected
v_linef   = v_unexpected
v_format  = v_unexpected

    PROGRAM_END

    .bss
    .align  2
user_stack:  .space 256
user_stack_top:
fault_count: .space 2
irq_count:   .space 2
trace_count: .space 2
