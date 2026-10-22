/*
 * SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
 * SPDX-License-Identifier: CERN-OHL-S-2.0
 * Source location: https://github.com/MelkhiorVintageComputing/RD68011
 */
/* Flat image for the RD68011 testbench memory.
 *
 * The memory model in sim/models/rd68011_slave.sv is 32K of word-wide RAM at
 * address zero, so a program here is exactly what an MC68010 sees after
 * reset: the vector table at 0, and everything else after it.
 *
 * The two words the testbench looks at are placed at fixed addresses rather
 * than left to the linker, so the harness does not need a symbol table:
 *
 *   0x0400  result    0 while running, $600D600D on success, otherwise the
 *                     number of the check that failed
 *   0x0404  progress  the number of the check now running, so a program that
 *                     hangs still says where
 */

OUTPUT_FORMAT("elf32-m68k")
OUTPUT_ARCH(m68k)
ENTRY(_start)

SECTIONS
{
    .vectors 0x00000000 : { KEEP(*(.vectors)) }
    .result  0x00000400 : { KEEP(*(.result)) }
    .text    0x00000800 : { *(.text) *(.text.*) *(.rodata) *(.rodata.*) }
    .data               : { *(.data) *(.data.*) }
    __bss_start = .;
    .bss                : { *(.bss) *(.bss.*) *(COMMON) }
    __bss_end = .;
    __end = .;

    /* The supervisor stack grows down from the top of the 32K the model has. */
    __stack_top = 0x00007FF8;

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) }
}
