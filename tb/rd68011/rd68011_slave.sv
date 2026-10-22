// SPDX-FileCopyrightText: 2026 Romain Dolbeau <romain@dolbeau.org>
// SPDX-License-Identifier: CERN-OHL-S-2.0
// Source location: https://github.com/MelkhiorVintageComputing/RD68011
// Bus slave model for RD68011 testbenches.
//
// A word-wide memory with a programmable number of wait states, plus an
// optional M6800 region that answers with VPA instead of DTACK.
//
// UM 5.6: "To properly control termination of a bus cycle [...] DTACK, BERR and
// HALT should be asserted and negated on the rising edge of the processor
// clock." This model does exactly that, so the tests exercise the sampling the
// manual assumes rather than a convenient one.
//
// Wait-state accounting: AS asserts on the rising edge of S2, so a slave that
// answers on the next rising edge (S4) is in time for the falling edge that
// ends S4 and inserts no wait states. WAITS is the number of extra clocks
// beyond that.

`timescale 1ns/1ps

module rd68011_slave #(
    parameter int   ADDR_BITS   = 12,    // size of the modelled memory, in words
    parameter logic [23:1] BASE = 23'h000000,
    parameter logic [23:1] MASK = 23'h7FF000
) (
    input  logic        clk,
    input  logic        rst_n,

    // Runtime configuration, so one testbench can sweep wait states and switch
    // a region between asynchronous and M6800 behaviour.
    input  logic  [7:0] waits,
    input  logic        m6800,   // answer with VPA instead of DTACK

    input  logic [23:1] a,
    input  logic        as_n,
    input  logic        uds_n,
    input  logic        lds_n,
    input  logic        rw,
    input  logic  [2:0] fc,

    input  logic [15:0] d_in,      // data the processor is driving
    output logic [15:0] d_out,
    output logic        d_oe,

    output logic        dtack_n,
    output logic        vpa_n
);

  logic [15:0] mem [0:(1<<ADDR_BITS)-1];

  logic        selected;
  logic        answered;
  int          waited;

  assign selected = !as_n && ((a & MASK) == (BASE & MASK));

  // Read data is driven whenever this slave is selected for a read. The
  // processor latches it on the falling edge of S6; driving it from the moment
  // of selection is the easy case, and the wait-state tests cover the late one.
  always_comb begin
    d_oe  = selected && rw;
    d_out = mem[a[ADDR_BITS:1]];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dtack_n  <= 1'b1;
      vpa_n    <= 1'b1;
      answered <= 1'b0;
      waited   <= 0;
    end else if (!selected) begin
      dtack_n  <= 1'b1;
      vpa_n    <= 1'b1;
      answered <= 1'b0;
      waited   <= 0;
    end else if (!answered) begin
      if (waited >= int'(waits)) begin
        answered <= 1'b1;
        if (m6800) vpa_n   <= 1'b0;
        else       dtack_n <= 1'b0;
      end else begin
        waited <= waited + 1;
      end
    end
  end

  // Writes land on the falling edge entering S7, when the processor negates the
  // data strobes -- the last moment the data is guaranteed valid.
  always_ff @(negedge clk) begin
    if (rst_n && selected && !rw) begin
      if (!uds_n) mem[a[ADDR_BITS:1]][15:8] <= d_in[15:8];
      if (!lds_n) mem[a[ADDR_BITS:1]][ 7:0] <= d_in[ 7:0];
    end
  end

  // Loading and inspection from the testbench.
  function automatic void poke(input logic [23:1] addr, input logic [15:0] val);
    mem[addr[ADDR_BITS:1]] = val;
  endfunction

  function automatic logic [15:0] peek(input logic [23:1] addr);
    peek = mem[addr[ADDR_BITS:1]];
  endfunction

  // Zero the lot, so that a program image loaded on top of it runs from
  // defined memory rather than from whatever the last test left.
  task automatic clear();
    for (int unsigned k = 0; k < (1 << ADDR_BITS); k = k + 1) mem[k] = 16'd0;
  endtask

  // Unused, but named so the port list stays honest.
  logic unused;
  assign unused = &{1'b1, fc};

endmodule
