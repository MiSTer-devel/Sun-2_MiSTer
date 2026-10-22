/*
 * SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 * Source location: https://github.com/MelkhiorVintageComputing/RD68011
 */
| Shared preamble for the RD68011 test programs.
|
| A vector table, the two words the testbench reads, and the handful of macros
| that make a self-checking program readable. Everything a program does is a
| numbered check: it announces the number, does the work, and branches to
| `fail` if the answer is wrong. A program that hangs leaves its number behind,
| which is most of what you want when something goes wrong at three in the
| morning.

    .equ    RESULT_ADDR,   0x0400
    .equ    PROGRESS_ADDR, 0x0404
    .equ    DONE_ADDR,     0x0408
    .equ    PASS_MARK,     0x600D600D

| ---------------------------------------------------------------------------
| The vector table. Every entry the programs here can provoke has a name; the
| rest go to one handler that fails the run, so an exception nobody expected
| is a failure and not a mystery.
| ---------------------------------------------------------------------------
    .macro  VECTORS
    .section .vectors,"a"
    .long   __stack_top             | 0  initial supervisor stack pointer
    .long   _start                  | 1  initial program counter
    .long   v_bus                   | 2  bus error
    .long   v_addr                  | 3  address error
    .long   v_illegal               | 4  illegal instruction
    .long   v_divzero               | 5  divide by zero
    .long   v_chk                   | 6  CHK
    .long   v_trapv                 | 7  TRAPV
    .long   v_priv                  | 8  privilege violation
    .long   v_trace                 | 9  trace
    .long   v_linea                 | 10 line A
    .long   v_linef                 | 11 line F
    .rept   2
    .long   v_unexpected            | 12-13 reserved
    .endr
    .long   v_format                | 14 format error
    .long   v_unexpected            | 15 uninitialised interrupt
    .rept   8
    .long   v_unexpected            | 16-23 reserved
    .endr
    .long   v_unexpected            | 24 spurious interrupt
    .rept   7
    .long   v_irq                   | 25-31 autovectors
    .endr
    .rept   16
    .long   v_trap                  | 32-47 TRAP #0 to #15
    .endr
    .rept   208
    .long   v_unexpected            | 48-255
    .endr
    .endm

| The words the harness reads, at the addresses link.ld fixes. `done` is
| written last and is one word wide, because the harness polls memory while the
| processor runs and a long store is two bus cycles -- reading between them
| gives half an answer.
    .macro  RESULT_BLOCK
    .section .result,"aw"
    .globl  result
result:     .long   0
progress:   .long   0
done:       .word   0
    .endm

| The first thing every program does.
|
| UM 5.5 says what reset leaves behind -- the interrupt mask at seven, the
| supervisor bit set, and on the MC68010 the vector base register cleared --
| and says nothing at all about the condition codes, so they are undefined and
| two implementations may differ. Setting them here means the co-simulation in
| tools/cosim/ has something to compare from the second instruction onward
| rather than waiting for the first one that happens to write a flag.
    .macro  PROGRAM_BEGIN
    move.w  #0x2700,%sr
    .endm

| ---------------------------------------------------------------------------
| Checks
| ---------------------------------------------------------------------------

| Announce which check is running. Uses d7, which no check may hold anything
| in across a CHECK.
    .macro  CHECK n
    moveq   #\n,%d7
    move.l  %d7,PROGRESS_ADDR
    .endm

| The three shapes every check ends in.
    .macro  EXPECT_EQ_L reg, val
    cmpi.l  #\val,\reg
    bne     fail
    .endm

    .macro  EXPECT_EQ_W reg, val
    cmpi.w  #\val,\reg
    bne     fail
    .endm

| Finish. `pass` writes the mark the harness waits for; `fail` writes the
| number of the check that was running, which is never the mark.
    .macro  PROGRAM_END
    .globl  pass, fail
pass:
    move.l  #PASS_MARK,RESULT_ADDR
    move.w  #1,DONE_ADDR            | one word, so the harness cannot see half
    bra     .
fail:
    move.l  PROGRESS_ADDR,%d0
    addq.l  #1,%d0                  | so that check zero failing is not zero
    move.l  %d0,RESULT_ADDR
    move.w  #1,DONE_ADDR
    bra     .
    .endm

| A default handler for every vector a program does not want: record which one
| and fail. The vector offset is in the frame's format word, at 6(sp).
    .macro  UNEXPECTED_HANDLER
    .globl  v_unexpected
v_unexpected:
    move.w  6(%sp),%d0
    andi.l  #0x0FFF,%d0
    ori.l   #0x8000,%d0             | marked, so it cannot look like a check
    move.l  %d0,RESULT_ADDR
    move.w  #1,DONE_ADDR
    bra     .
    .endm
