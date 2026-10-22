// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// Shared harness for the RD68011 core testbenches.
//
// Instantiates the whole processor against a memory, loads a program, and
// records every bus cycle so a test can check the sequence of addresses the
// core asked for -- which, for a design whose prefetch behaviour is part of
// the specification, is most of what there is to check.
//
// The recorded transaction list is the same thing the SingleStepTests vectors
// record, so a check written here says the same thing as a check written
// against the reference.

`ifndef RD68011_CORE_HARNESS_SVH
`define RD68011_CORE_HARNESS_SVH

// The loop buffer is off unless a testbench asks for it, which it does by
// defining this before the include. Every existing test therefore instantiates
// exactly the core it always did.
`ifndef RD68011_LOOP_BUF_WORDS
  `define RD68011_LOOP_BUF_WORDS 0
`endif

// Zero -- the default -- exits loop mode on a bus error and lets the DBcc
// re-enter it. One restores it from the format $8 frame. doc/divergences.md
// argues both readings of appendix A.
`ifndef RD68011_RTE_RESTORES_LOOP
  `define RD68011_RTE_RESTORES_LOOP 0
`endif

// The other half of the same crossing: whether the loop buffer's window
// survives an RTE. Zero empties it at RESUME.
`ifndef RD68011_RTE_KEEPS_LOOP_BUF
  `define RD68011_RTE_KEEPS_LOOP_BUF 1
`endif

  localparam realtime CLK_PERIOD = 125.0;   // 8 MHz
  localparam int      MAXTR      = 512;

  logic clk;
  logic rst_n;
  int   errors;

  // Pins.
  logic [23:1] a_o;
  logic        a_oe;
  logic [15:0] d_i, d_o;
  logic        d_oe;
  logic        as_n_o, as_oe, rw_o, rw_oe, uds_n_o, lds_n_o, ds_oe;
  logic        dtack_n_i, br_n_i, bg_n_o, bgack_n_i;
  logic  [2:0] ipl_n_i;
  logic        reset_n_i, reset_n_o, reset_n_oe;
  logic        halt_n_o, halt_n_oe;
  wire         berr_n_i;
  wire         halt_n_i;
  logic        e_o, vpa_n_i, vma_n_o, vma_oe;
  logic  [2:0] fc_o;
  logic        fc_oe;
  logic        loop_inv_n_i;

  rd68011_top #(.LOOP_BUF_WORDS    (`RD68011_LOOP_BUF_WORDS),
                .RTE_RESTORES_LOOP  (`RD68011_RTE_RESTORES_LOOP),
                .RTE_KEEPS_LOOP_BUF (`RD68011_RTE_KEEPS_LOOP_BUF)) dut (
      .clk (clk), .rst_n (rst_n),
      .a_o (a_o), .a_oe (a_oe),
      .d_i (d_i), .d_o (d_o), .d_oe (d_oe),
      .as_n_o (as_n_o), .as_oe (as_oe), .rw_o (rw_o), .rw_oe (rw_oe),
      .uds_n_o (uds_n_o), .lds_n_o (lds_n_o), .ds_oe (ds_oe),
      .dtack_n_i (dtack_n_i),
      .br_n_i (br_n_i), .bg_n_o (bg_n_o), .bgack_n_i (bgack_n_i),
      .ipl_n_i (ipl_n_i), .berr_n_i (berr_n_i),
      .reset_n_i (reset_n_i), .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
      .halt_n_i (halt_n_i), .halt_n_o (halt_n_o), .halt_n_oe (halt_n_oe),
      .loop_inv_n_i (loop_inv_n_i),
      .e_o (e_o), .vpa_n_i (vpa_n_i), .vma_n_o (vma_n_o), .vma_oe (vma_oe),
      .fc_o (fc_o), .fc_oe (fc_oe)
  );

  // -- Memory, on a real three-state data bus --------------------------------
  wire  [15:0] dbus;
  logic [15:0] mem_d_out;
  logic        mem_d_oe;
  logic  [7:0] mem_waits;
  logic        mem_m6800;

  // Interrupt acknowledge. A cycle in CPU space with the function code all
  // ones is answered either with VPA, which asks for the autovector for the
  // level, or with DTACK and a vector number on the data bus (UM 5.1.4).
  //
  // Declared here, above the first assignment that reads them: Questa rejects a
  // variable used before its declaration, where iverilog and Verilator invent
  // an implicit net and carry on.
  logic       iack_auto;      // 1: answer with VPA
  logic [7:0] iack_vector;
  wire        is_iack;
  // With `iack_berr` set, nothing answers the acknowledge cycle and BERR
  // terminates it -- which UM 6.3.4 makes a spurious interrupt, not a bus
  // error.
  logic       iack_berr;

  assign dbus = d_oe     ? d_o       : 16'bz;
  assign dbus = mem_d_oe ? mem_d_out : 16'bz;
  // The interrupting device puts its vector number on D0-D7 (UM 5.1.4, figure
  // 5-11), and the acknowledge is a word read, so something has to be on the
  // upper half. What a real device drives there is not specified; ones are as
  // legitimate as zeros and are the stronger test, because a core that took
  // the wrong byte, or merged the two, then fails instead of passing on a
  // convenient zero.
  assign dbus = (is_iack && !iack_auto && !iack_berr) ? {8'hFF, iack_vector} : 16'bz;
  assign d_i  = dbus;

  wire [23:1] abus;
  assign abus = a_oe ? a_o : 23'bx;

  logic mem_dtack_n, mem_vpa_n;

  assign is_iack = !as_n_o && (fc_o == 3'b111);

  assign dtack_n_i = mem_dtack_n & ~(is_iack && !iack_auto && !iack_berr);
  assign vpa_n_i   = mem_vpa_n   & ~(is_iack &&  iack_auto && !iack_berr);

  rd68011_slave #(.ADDR_BITS (14), .BASE (23'h000000), .MASK (23'h400000)) mem (
      .clk (clk), .rst_n (rst_n),
      .waits (mem_waits), .m6800 (mem_m6800),
      .a (abus), .as_n (as_n_o), .uds_n (uds_n_o), .lds_n (lds_n_o),
      .rw (rw_o), .fc (fc_o),
      .d_in (dbus), .d_out (mem_d_out), .d_oe (mem_d_oe),
      .dtack_n (mem_dtack_n), .vpa_n (mem_vpa_n)
  );

  // -- Fault injection --------------------------------------------------------
  //
  // One address that answers with BERR instead of, or as well as, the memory's
  // DTACK -- which is how a bus error is provoked without a second memory
  // model. With `berr_retry` set it answers BERR and HALT together, which UM
  // 5.4.2 makes a rerun request rather than an error.
  //
  // `berr_count` counts the cycles that hit it, so a test can arrange for the
  // fault to happen once and the handler's own accesses to go through.
  logic        berr_en;
  logic [23:1] berr_addr;
  logic        berr_retry;
  logic        tb_halt_n;
  int          berr_count;
  wire         berr_hit;

  logic berr_wonly = 1'b0;
  assign berr_hit = berr_en && !as_n_o && (a_o == berr_addr) && !(berr_wonly && rw_o);
  assign berr_n_i = !(berr_hit || (iack_berr && is_iack));
  assign halt_n_i = tb_halt_n && !(berr_hit && berr_retry);

  always @(negedge as_n_o) if (berr_hit) berr_count = berr_count + 1;

  // -- Clock and watchdog -----------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2.0) clk = ~clk;
  end

  // A safety net, not a measurement. The programs under sim/programs/ run for
  // rather longer than a directed test, so it is settable from the command
  // line rather than fixed.
  int tb_timeout;
  initial begin
    if (!$value$plusargs("timeout=%d", tb_timeout)) tb_timeout = 20000;
    #(CLK_PERIOD * tb_timeout);
    $display("FAIL: timeout");
    $finish;
  end

  // -- Bus cycle recorder -----------------------------------------------------
  // One entry per cycle, captured as AS asserts: what the core asked for, in
  // what space, and at what clock.
  int          ntr;
  int          clkcount;
  logic [23:1] tr_addr [0:MAXTR-1];
  logic  [2:0] tr_fc   [0:MAXTR-1];
  logic        tr_rw   [0:MAXTR-1];
  int          tr_clk  [0:MAXTR-1];

  always_ff @(posedge clk) begin
    if (!rst_n) clkcount <= 0;
    else        clkcount <= clkcount + 1;
  end

  initial begin
    ntr = 0;
    forever begin
      @(negedge as_n_o);
      if (ntr < MAXTR) begin
        tr_addr[ntr] = a_o;
        tr_fc[ntr]   = fc_o;
        tr_rw[ntr]   = rw_o;
        tr_clk[ntr]  = clkcount;
        ntr          = ntr + 1;
      end
    end
  end

  // -- Instruction boundary recorder ------------------------------------------
  // An instruction ends when the microcode takes its DECODE exit, so that edge
  // is the boundary, and the gap between two of them is an instruction's cycle
  // count. Measuring from the first bus cycle instead would charge the *next*
  // instruction's leading internal cycles to this one -- a branch begins with
  // two microwords that touch nothing.
  //
  // Sampled on the falling edge, not the rising one. `retire` for a bus-cycle
  // microword only settles once the bus unit has acknowledged, and the bus
  // unit's output stage is negedge-clocked; read just after the rising edge it
  // is still the previous half-clock's value, and the boundary that ends an
  // instruction in a bus cycle is missed. The falling edge is the last moment
  // before the rising edge that acts on it, so what is read there is what the
  // sequencer will do.
  int          nins;
  logic [15:0] ins_op  [0:MAXTR-1];
  logic [31:0] ins_pc  [0:MAXTR-1];
  int          ins_clk [0:MAXTR-1];

  initial begin
    nins = 0;
    forever begin
      @(negedge clk);
      #1;
      if (rst_n && dut.u_seq.retire && nins < MAXTR &&
          (dut.u_seq.f_seq == rd68011_ucode_pkg::U_SEQ_DECODE)) begin
        ins_op[nins]  = dut.u_seq.ir;   // the instruction that just finished
        ins_pc[nins]  = dut.u_seq.ir_pc;
        ins_clk[nins] = clkcount;
        nins          = nins + 1;
      end
    end
  end

  // -- How long the write data has really had ---------------------------------
  //
  // `d_o` is loaded on the falling edge entering S3, and the microword that
  // supplies the data became current on the rising edge that started S0. The
  // states in between alternate edges unconditionally -- S0 to S1 on a falling
  // edge, S1 to S2 on a rising one, S2 to S3 on a falling one -- and nothing in
  // the sequencer moves while a cycle is in progress, because `retire` waits
  // for the bus unit. So the data has had three half clocks.
  //
  // Static timing analysis sees a rising-edge launch and a falling-edge capture
  // and allows half of one, which is why scripts/rd68011.xdc puts a multicycle
  // on this register's data input. That constraint is only sound while what is
  // measured here stays at 3 or more, so it is measured rather than argued: at
  // every load, how many edges the captured value had already been stable for.
  int          wdata_stable, wdata_margin;
  logic [15:0] wdata_prev;
  logic        wdata_capture;

  assign wdata_capture =
      ((dut.u_biu.st_n_nxt == rd68011_pkg::ST_S3) && dut.u_biu.cyc_is_write) ||
       (dut.u_biu.st_n_nxt == rd68011_pkg::ST_S15);

  initial begin
    wdata_stable = 0;
    wdata_margin = 99;
    wdata_prev   = 16'h0;
    forever begin
      @(negedge clk);
      // The value this falling edge latches is the one that was there before
      // it, so the run that matters ended at the previous edge: read
      // `wdata_stable` before this edge updates it. It counts edges at which
      // the value was already unchanged, so the settling time in half clocks
      // is one more than that.
      if (rst_n && wdata_capture && ((wdata_stable + 1) < wdata_margin)) begin
        wdata_margin = wdata_stable + 1;
        if (wdata_margin < 3) begin
          $display("FAIL: write data had %0d half clocks to settle, and scripts/rd68011.xdc assumes 3",
                   wdata_margin);
          errors = errors + 1;
        end
      end
      #1;
      if (dut.u_seq.req_wdata !== wdata_prev) wdata_stable = 0;
      else                                    wdata_stable = wdata_stable + 1;
      wdata_prev = dut.u_seq.req_wdata;
      @(posedge clk);
      #1;
      if (dut.u_seq.req_wdata !== wdata_prev) wdata_stable = 0;
      else                                    wdata_stable = wdata_stable + 1;
      wdata_prev = dut.u_seq.req_wdata;
    end
  end

  // -- When an interrupt may be taken -----------------------------------------
  //
  // The whole rule, in one place. UM 3.5 makes level seven unmaskable and UM
  // section 6 makes every other level a comparison against the mask, so an
  // interrupt is legitimate only if the line is at seven or is above the mask
  // -- and it must be legitimate *at the instant it is taken*, because that is
  // the instant the level is latched and the level is what the acknowledge
  // carries and what the handler's mask becomes.
  //
  // Stated here rather than in rtl/ because rtl/ has no assertions in it and
  // has to elaborate under yosys and Vivado as well; stated in the harness
  // rather than in one testbench because it then holds for every program, every
  // reference vector and every co-simulated instruction, not just for the
  // directed cases that provoked it. doc/bugs-found.md has what it caught.
  always @(posedge clk) begin
    if (rst_n && dut.u_seq.commit && dut.u_seq.take_irq) begin
      if (!((dut.u_seq.irq_level == 3'd7) ||
            (dut.u_seq.irq_level > dut.u_seq.sr[10:8]))) begin
        $display("FAIL: interrupt taken at level %0d with the mask at %0d",
                 dut.u_seq.irq_level, dut.u_seq.sr[10:8]);
        errors = errors + 1;
      end
    end
  end

  // -- Checking ---------------------------------------------------------------
  task automatic expect_tr(input int i, input logic [31:0] addr,
                           input logic [2:0] fc, input logic rw,
                           input string what);
    begin
      if (i >= ntr) begin
        $display("FAIL: %s: only %0d bus cycles, wanted at least %0d",
                 what, ntr, i + 1);
        errors = errors + 1;
      end else begin
        if ({9'd0, tr_addr[i]} !== {8'd0, addr[23:1]}) begin
          $display("FAIL: %s: cycle %0d at %06h, expected %06h",
                   what, i, {tr_addr[i], 1'b0}, addr);
          errors = errors + 1;
        end
        if (tr_fc[i] !== fc) begin
          $display("FAIL: %s: cycle %0d function code %0d, expected %0d",
                   what, i, tr_fc[i], fc);
          errors = errors + 1;
        end
        if (tr_rw[i] !== rw) begin
          $display("FAIL: %s: cycle %0d is a %s, expected a %s",
                   what, i, tr_rw[i] ? "read" : "write",
                   rw ? "read" : "write");
          errors = errors + 1;
        end
      end
    end
  endtask

  task automatic expect_u32(input string what, input logic [31:0] got,
                            input logic [31:0] want);
    if (got !== want) begin
      $display("FAIL: %s is %08h, expected %08h", what, got, want);
      errors = errors + 1;
    end
  endtask

  task automatic expect_int(input string what, input int got, input int want);
    if (got != want) begin
      $display("FAIL: %s is %0d, expected %0d", what, got, want);
      errors = errors + 1;
    end
  endtask

  // -- Loading ----------------------------------------------------------------
  task automatic poke_w(input logic [23:1] addr, input logic [15:0] val);
    mem.poke(addr, val);
  endtask

  task automatic poke_l(input logic [23:1] addr, input logic [31:0] val);
    begin
      mem.poke(addr,          val[31:16]);
      mem.poke(addr + 23'd1,  val[15:0]);
    end
  endtask

  // Does not zero the error count: a test that resets the core between
  // sections should still report every error it found.
  task automatic core_reset();
    begin
      rst_n      = 1'b0;
      mem_waits  = 8'd0;
      mem_m6800  = 1'b0;
      br_n_i      = 1'b1;
      iack_auto   = 1'b1;
      iack_berr   = 1'b0;
      iack_vector = 8'd64;
      bgack_n_i  = 1'b1;
      ipl_n_i    = 3'b111;
      berr_en    = 1'b0;
      berr_addr  = 23'd0;
      berr_retry = 1'b0;
      berr_count = 0;
      tb_halt_n  = 1'b1;
      loop_inv_n_i = 1'b1;
      // RESET and HALT asserted together is what resets the processor
      // (UM 5.5); the sequencer sits at its reset entry point until they go.
      reset_n_i  = 1'b0;
      repeat (4) @(posedge clk);
      @(negedge clk);
      rst_n = 1'b1;
      repeat (4) @(posedge clk);
    end
  endtask

  task automatic core_start();
    begin
      ntr = 0;
      @(negedge clk);
      reset_n_i = 1'b1;
    end
  endtask

  task automatic core_done(input string name);
    begin
      if (wdata_margin != 99)
        $display("  write data settled %0d half clocks before it was latched",
                 wdata_margin);
      if (errors == 0) $display("PASS: %s", name);
      else             $display("FAIL: %s, %0d error(s)", name, errors);
      $finish;
    end
  endtask

`endif
