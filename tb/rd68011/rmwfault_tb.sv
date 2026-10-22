// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// rmwfault_tb: RD68011's sim/tb/core_program_tb.sv, with three additions for
// the loop-mode read-modify-write fault (rmwfault.S, rmwfault_user.S):
//
//   * the program arms the injected bus error with a word write to 0x0500 and
//     disarms it with one to 0x0502, so a handler can "map the page" and let
//     the processor rerun the cycle;
//   * +berr_wr faults only the write half of a cycle, which is what SunOS 4
//     does to an RMW whose page came back from disk read-only;
//   * +dma=1 and +irqdelay=K add an alternate bus master and a level 5
//     interrupt, the other two things a woken process meets on a Sun-2.
//
// What follows is upstream's own description.
//
// Real code, compiled and run.
//
// Everything else that tests this processor tests it one instruction at a
// time. The reference vectors are a single instruction each from a fabricated
// register state; the directed testbenches are a handful of hand-written ones.
// Nothing until here has run a *program*: a return address that survives three
// nested calls, a frame pointer that is still a frame pointer after the callee
// saved and restored eight registers, a handler that does real work and
// returns into the middle of the instruction that faulted.
//
// So this loads a flat image built by sim/programs/ -- the vector table at
// zero and everything after it, exactly what an MC68010 sees after reset --
// releases the processor, and waits for the program to say what happened.
// The contract is two words, at the addresses sim/programs/link.ld fixes:
//
//   0x0400  result    0 while running, $600D600D on success, otherwise the
//                     number of the check that failed, or $8xxx for an
//                     exception the program did not expect (xxx is its vector
//                     offset)
//   0x0404  progress  the check now running, so a program that hangs still
//                     says where it stopped
//   0x0408  done      one word, written last, because a long store is two bus
//                     cycles and this testbench polls memory while the
//                     processor runs
//
// Run one image with +prog=<file>; the Makefile's `programs` target runs them
// all. Some programs also want faults injected from outside, which +berr=
// arranges: the harness answers one address with a bus error, and the program
// is written knowing that it will.

`timescale 1ns/1ps

module rmwfault_tb;

`include "rd68011_core_harness.svh"

  localparam logic [22:0] RESULT_W   = 23'h000200;   // 0x0400 >> 1
  localparam logic [22:0] PROGRESS_W = 23'h000202;   // 0x0404 >> 1
  localparam logic [22:0] DONE_W     = 23'h000204;   // 0x0408 >> 1
  localparam logic [31:0] PASS_MARK  = 32'h600D_600D;

  string       progfile;
  string       tracefile;
  int          tf;
  logic        tracing;
  logic        boundary;
  int          limit;
  int          berr_word;
  int          prog_waits;
  logic [31:0] res, prog;
  int          n;

  function automatic logic [31:0] peek_l(input logic [22:0] wa);
    peek_l = {mem.peek(wa), mem.peek(wa + 23'd1)};
  endfunction

  // -- The co-simulation trace -----------------------------------------------
  //
  // One line per instruction, printed at the instruction boundary that starts
  // it: the address, the opcode about to run, the status register, and all
  // sixteen registers.
  // tools/cosim/musashi_trace.c prints the same line from an instruction-set
  // simulator running the same image, and tools/cosim/compare.py finds the
  // first place the two stop agreeing.
  //
  // The boundary is detected on the falling edge, where `retire` has settled --
  // the bus unit's acknowledge only arrives in the second half of the clock --
  // and the state is read after the rising edge that acts on it, which is when
  // the registers hold what the next instruction starts with.
  int tr_i;

  // Not every boundary starts the instruction at ir_pc: a trace exception or
  // an interrupt is taken at exactly this point, and the instruction the pipe
  // had ready is pre-empted rather than executed. Musashi's hook fires only
  // for instructions that actually run, so this has to as well.
  always @(negedge clk) begin
    #1;
    boundary = rst_n && dut.u_seq.retire &&
               (dut.u_seq.f_seq == rd68011_ucode_pkg::U_SEQ_DECODE) &&
               !dut.u_seq.take_trace && !dut.u_seq.take_irq;
  end

  always @(posedge clk) begin
    #2;
    if (tracing && boundary) begin
      $fwrite(tf, "%06h %04h %04h", dut.u_seq.ir_pc[23:0], dut.u_seq.ir,
              dut.u_seq.sr);
      for (tr_i = 0; tr_i < 15; tr_i = tr_i + 1)
        $fwrite(tf, " %08h", dut.u_seq.regs[tr_i]);
      $fwrite(tf, " %08h\n", dut.u_seq.sr[rd68011_pkg::SR_S] ? dut.u_seq.ssp
                                                              : dut.u_seq.usp);
    end
  end

  initial begin
    errors = 0;

    if (!$value$plusargs("prog=%s", progfile)) begin
      $display("FAIL: core_program_tb needs +prog=<hex image>");
      $finish;
    end
    if (!$value$plusargs("limit=%d", limit))   limit = 3000000;
    if (!$value$plusargs("berr=%d", berr_word)) berr_word = -1;
    // Memory latency. Everything here ran at zero wait states until a report
    // from a real machine pointed out that its memory can be saturated to the
    // order of a dozen. Nothing about the processor should depend on it, which
    // is exactly why it is worth being able to turn up.
    if ($value$plusargs("waits=%d", prog_waits)) mem_waits = prog_waits[7:0];
    tracing = 1'b0;
    if ($value$plusargs("trace=%s", tracefile)) begin
      tf      = $fopen(tracefile, "w");
      tracing = (tf != 0);
    end

    core_reset();
    mem.clear();
    $readmemh(progfile, mem.mem);

    if ($test$plusargs("berr_wr")) berr_wonly = 1'b1;   // fault only the write half
    if (berr_word >= 0) begin
      berr_addr = 23'(berr_word);
      berr_en   = 1'b0;      // armed by the program, see below
    end

    core_start();

    // The program writes its result and then stops in a tight loop, so the
    // wait is on memory rather than on the processor. The flag is one word and
    // is written last: a long store is two bus cycles, and polling between
    // them would read half of it.
    n = 0;
    while ((mem.peek(DONE_W) == 16'd0) && (n < limit)) begin
      @(posedge clk);
      n = n + 1;
    end

    res  = peek_l(RESULT_W);
    prog = peek_l(PROGRESS_W);

    if (mem.peek(DONE_W) == 16'd0) begin
      $display("FAIL: %s did not finish; it was in check %0d after %0d clocks",
               progfile, prog, n);
      $display("      pc %08h  ir %04h  sr %04h",
               dut.u_seq.ir_pc, dut.u_seq.ir, dut.u_seq.sr);
      errors = errors + 1;
    end else if (res == PASS_MARK) begin
      $display("  %s: %0d checks in %0d clocks", progfile, prog, n);
    end else if (res[31:16] == 16'h0000 && res[15] == 1'b1) begin
      $display("FAIL: %s took vector offset $%03h, which it did not expect,"
               , progfile, res[11:0]);
      $display("      during check %0d", prog);
      errors = errors + 1;
    end else begin
      // `fail` writes the check number plus one, so that check zero failing
      // does not look like a program that never started.
      $display("FAIL: %s failed check %0d", progfile, res - 32'd1);
      errors = errors + 1;
    end

    if (tracing) $fclose(tf);
    if (errors == 0) $display("PASS: %s", progfile);
    else             $display("FAIL: core_program_tb");
    $finish;
  end


  // The program arms the fault with a word write to 0x0500 and disarms it with
  // one to 0x0502 -- a page that is mapped in by the handler.
  always @(negedge as_n_o) begin
    #1;
    if (!rw_o && a_o == 23'h000280) berr_en = 1'b1;
    if (!rw_o && a_o == 23'h000281) berr_en = 1'b0;
  end


  // +dma=1: an alternate master that requests the bus at random, the way the
  // Sun-2's SCSI board keeps reading ahead while the faulted process resumes.
  logic master_drive = 1'b0;
  assign dbus = master_drive ? 16'hA5A5 : 16'bz;
  int dma_on, jm, seed;
  initial begin
    if (!$value$plusargs("dma=%d", dma_on)) dma_on = 0;
    if ($value$plusargs("seed=%d", seed)) jm = $urandom(seed);
    #1;
    br_n_i = 1'b1; bgack_n_i = 1'b1;
    if (dma_on) begin
      repeat (50) @(posedge clk);
      forever begin
        repeat ($urandom_range(2, 40)) @(posedge clk);
        br_n_i = 1'b0;
        jm = 0;
        while ((bg_n_o !== 1'b0) && (jm < 400)) begin @(posedge clk); jm = jm + 1; end
        jm = 0;
        while ((a_oe !== 1'b0) && (jm < 400)) begin @(posedge clk); jm = jm + 1; end
        if ($urandom_range(0, 1)) @(negedge clk);
        bgack_n_i = 1'b0;
        br_n_i    = 1'b1;
        jm = 0;
        while (((a_oe === 1'b1) || (as_oe === 1'b1) || (ds_oe === 1'b1) ||
                (fc_oe === 1'b1) || (d_oe === 1'b1)) && (jm < 40)) begin @(clk); jm = jm + 1; end
        master_drive = 1'b1;
        repeat ($urandom_range(2, 26)) @(posedge clk);
        if ($urandom_range(0, 1)) @(negedge clk);
        master_drive = 1'b0;
        bgack_n_i    = 1'b1;
      end
    end
  end


  // +irqdelay=K: K clocks after the handler disarms the fault, raise level 5
  // and hold it until it is acknowledged. Once only.
  int irqdelay, irq_done;
  initial begin
    irq_done = 0;
    if (!$value$plusargs("irqdelay=%d", irqdelay)) irqdelay = -1;
  end
  always @(negedge as_n_o) begin
    #1;
    if (irqdelay >= 0 && !irq_done && !rw_o && a_o == 23'h000281) begin
      irq_done = 1;
      fork begin
        repeat (irqdelay) @(posedge clk);
        ipl_n_i = 3'b010;
        wait (is_iack === 1'b1);
        @(posedge clk);
        ipl_n_i = 3'b111;
      end join_none
    end
  end


  // The pipe as RESUME leaves it, and the instruction boundary after it.
  int show_n = 0;
  always @(posedge clk) begin
    if (dut.u_seq.retire && dut.u_seq.f_seq == rd68011_ucode_pkg::U_SEQ_RESUME && show_n < 4) begin
      show_n++;
      $display("RESUME: ir %04h ir_pc %06h irc %04h irc_pc %06h pc %06h loop_pending %b loop_saved %b",
               dut.u_seq.ir, dut.u_seq.ir_pc, dut.u_seq.irc, dut.u_seq.irc_pc, dut.u_seq.pc,
               dut.u_seq.loop_pending, dut.u_seq.loop_saved);
    end
  end

endmodule
