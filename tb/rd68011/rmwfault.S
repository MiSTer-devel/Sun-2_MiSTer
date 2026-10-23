| A read-modify-write in loop mode, faulted on the second word of a longword
| that straddles the faulting address, and resumed after a handler that does
| (or does not) run other code first.
|
| This is libpixrect's mem_rop fill, `and.l %d6,(%a4)+ ; dbf %d4,`, faulted
| the way SunOS 4 faults it on a Sun-2: a page boundary in the middle of the
| longword, and a page that has to come from disk, so the process sleeps and
| other code runs before the RTE.
|
| The harness (p08_rmwfault_tb) faults FAULT_W while armed; a word write to
| DISARM turns that off and one to ARM turns it back on, so the handler can
| "map the page" and let the processor rerun the cycle.

    .include "rd68011.inc"

    .equ    BUF,     0x3002         | longwords at 0x3002, 0x3006, ...
    .equ    FAULT_W, 0x3100         | the second word of the long at 0x30FE
    .equ    NLONG,   100
    .equ    ARM,     0x0500
    .equ    DISARM,  0x0502
    .equ    OTHER,   0x4002
    .equ    PAT,     0x5A3C96E1

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    PROGRAM_BEGIN

    .irp    mode, 0, 1, 2, 3, 4
    CHECK   (10 + \mode)
    move.w  #\mode,hmode
    bsr     fill
    clr.w   fault_count
    move.w  #1,ARM
    movea.l #BUF,%a4
    move.l  #PAT,%d6
    moveq   #-1,%d5
    move.w  #NLONG-1,%d4
1:  and.l   %d6,(%a4)+
    dbf     %d4,1b
    move.w  #1,DISARM
    cmpa.l  #BUF+4*NLONG,%a4
    bne     fail
    cmpi.w  #-1,%d4
    bne     fail
    EXPECT_EQ_L %d6, PAT
    EXPECT_EQ_L %d5, -1
    move.w  fault_count,%d0
    EXPECT_EQ_W %d0, 1
    move.w  trace_count,%d0
    .if \mode == 4
    EXPECT_EQ_W %d0, 1
    .else
    EXPECT_EQ_W %d0, 0
    .endif
    clr.w   trace_count
    bsr     verify
    .endr
    bra     pass

| Memory under the loop all ones, so each long must come back as PAT.
fill:
    movea.l #BUF-4,%a0
    move.w  #NLONG+1,%d0
2:  move.l  #-1,(%a0)+
    dbf     %d0,2b
    rts

verify:
    movea.l #BUF,%a0
    move.w  #NLONG-1,%d0
3:  cmpi.l  #PAT,(%a0)+
    bne     fail
    dbf     %d0,3b
    cmpi.l  #-1,(%a0)               | the long past the end untouched
    bne     fail
    cmpi.l  #-1,BUF-4               | and the one before it
    bne     fail
    rts

| ---------------------------------------------------------------------------
| The handler: "page in", optionally run other code, then let the processor
| rerun the faulted cycle (RR clear).
    .globl  v_bus
v_bus:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    addq.w  #1,fault_count
    move.w  hmode,%d0
    beq     9f
    | mode 1: another loop-mode RMW loop, on other memory
    movea.l #OTHER,%a0
    move.l  #0x0F0F0F0F,%d1
    moveq   #31,%d2
4:  and.l   %d1,(%a0)+
    dbf     %d2,4b
    cmpi.w  #1,%d0
    beq     9f
    | mode 2: a copy loop and a few ALU operations with other values
    movea.l #OTHER,%a0
    movea.l #OTHER+0x200,%a1
    moveq   #31,%d2
5:  move.l  (%a0)+,(%a1)+
    dbf     %d2,5b
    move.l  #0x12345678,%d3
    move.l  #0x9ABCDEF0,%d4
    add.l   %d3,%d4
    eor.l   %d4,%d3
    cmpi.w  #2,%d0
    beq     9f
    | mode 3: an RMW longword loop with postincrement and predecrement both
    movea.l #OTHER+0x400,%a0
    moveq   #15,%d2
6:  or.l    %d3,(%a0)+
    and.l   %d4,-(%a0)
    addq.l  #4,%a0
    dbf     %d2,6b
9:  move.w  #1,DISARM               | the page is in
    cmpi.w  #4,%d0
    bne     8f
    | mode 4: what SunOS does when the fault slept and a reschedule is
    | pending -- it cannot take the AST over a long frame, so it sets the
    | trace bit and takes it after the faulted instruction completes.
    ori.w   #0x8000,15*4(%sp)       | T in the frame's status register
8:  movem.l (%sp)+,%d0-%d7/%a0-%a6
    rte

| The trace that SunOS's AST rides on: count it, clear T, carry on.
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

    .globl  v_addr
v_addr = v_unexpected
    UNEXPECTED_HANDLER
    .globl  v_illegal, v_divzero, v_chk, v_trapv, v_priv
    .globl  v_linea, v_linef, v_format, v_trap, v_irq
v_illegal = v_unexpected
v_divzero = v_unexpected
v_chk     = v_unexpected
v_trapv   = v_unexpected
v_priv    = v_unexpected
v_linea   = v_unexpected
v_linef   = v_unexpected
v_format  = v_unexpected
v_trap    = v_unexpected
v_irq     = v_unexpected

    PROGRAM_END

    .bss
    .align  2
fault_count: .space 2
hmode:       .space 2
trace_count: .space 2
