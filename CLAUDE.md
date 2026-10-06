# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

A Sun-2 workstation as a MiSTer core: an MC68010, the Sun-2 MMU, an Am9513
timer, two Zilog 8530 SCCs, an Intel 82586 Ethernet, a SCSI disk and tape, and
the Sun-2 colour board, booting the real Rev Q boot PROM, installing SunOS 4.0
from tape and running SunView in colour.

The machine was first a replica on a QMTech Wukong and an Arrow DECA, and this
core was ported from it. That work -- the board-era simulation flows and
testbenches, the boot-block probes and tools, and the long record of what was
found and how -- lives in the development repository,
**https://github.com/danifunker/Sun-2_MiSTer**. This repository holds what
builds the core, what a user needs to run it, the Verilator tests for the
MiSTer core, and the docs the README links to. When this file says "the dev
repo", it means that one.

## Building

Quartus Prime **Lite 17.0.2**, the version MiSTer's framework supports. Nothing
else is needed: no submodules, no generated sources, no scripts to run first.
Keep it that way -- a MiSTer core has to build from a plain checkout.

```sh
quartus_sh --flow compile Sun-2          # -> output_files/Sun-2.rbf
```

* **A full compile is 17 to 20 minutes** (synthesis about 5, the fitter about
  10). **Past 45 minutes, kill it and find out why** -- a fitter that runs long
  is iterating on something it cannot close, and the one time it happened here
  the router sat at 117% congestion for over an hour (see *Clocks*). Run one
  Quartus build at a time.
* **A one-minute check** that every file resolves and elaborates, without a
  fit. The pre-flow script only runs under `--flow`, so make `build_id.v`
  first, and its arguments are not optional:

  ```sh
  quartus_sh -t sys/build_id.tcl compile Sun-2 Sun-2
  quartus_map Sun-2 -c Sun-2 --analysis_and_elaboration
  ```

  The release tree gives 0 errors and 78 warnings, none of them `Warning
  (10236)`. A 10236 is an implicit net: an identifier Quartus did not find
  declared and silently made a one-bit wire for. Treat a new one as an error.
* **After a fit**, read the timing summary and the fit report's *Global & Other
  Fast Signals*. The released build (`5b8df3a`) is 34,695 ALMs (83%), 187 of 553
  RAM blocks, 35 DSPs, setup slack +0.090 ns on the HDMI clock, **+0.285 ns on
  cpu_clk**, +0.920 on clk_mem and +2.138 on clk_pix. cpu_clk must be on a
  global clock (GCLK). If it is not, the build is wrong, whatever the slack
  says.

## The machine, and where it is fixed

One configuration, a **Sun-2/160 with the colour board**, set in `Sun-2.qsf`'s
`VERILOG_MACRO` block and nowhere else:

| macro | what |
|---|---|
| `SUN2_VME` | the VME CPU board (Machine Type 2) and its Rev Q PROM, the only Sun-2 PROM built with a colour console |
| `SUN2_VME_SCSI` | Sun's VME SCSI/RTC board: the disk (sd0), the tape (st0) and the MM58167 clock |
| `SUN2_FB` | the on-board 1152x900 mono frame buffer, whose control register carries the colour jumper |
| `SUN2_CGTWO` | the colour board, 1152x900x8 at VME 0x400000, with its raster-op units |
| `SUN2_WB_FIFO`, `SUN2_WB_CACHE` | the cached FIFO bridge from the 68010 bus to memory |
| `SUN2_CPU_RD68011` | the RD68011 CPU core |
| `SUN2_QUARTUS` | Quartus-specific spellings in shared RTL |
| `SUN2_BOOTROM_LOAD` | the boot PROM is loaded from `boot0.rom` at start-up, not built into the bitstream |
| `SUN2_IDPROM_LOAD` | the ID PROM can be overwritten from `boot1.rom` |

`rtl/sun2-common/sun2_config.vh` derives everything machine-dependent from
these. Its MultiBus branch and the `rtl/sun2-multibus/` cards are in the dev
repo, not here. Two Quartus rules about this block:

* **Plain names only.** A sized literal such as `30'h03E00000` does not survive
  `VERILOG_MACRO`, so every value has to be `sun2_config.vh`'s default.
* **Quartus discards `$fatal`.** The elaboration guards in `sun2_fpga.v` that
  reject impossible combinations only fire in a simulator, so nothing checks a
  combination at build time.

The OSD's *Colour board* (`status[12]`, On by default) fits or removes the
colour board at reset. With it fitted the colour jumper is set, the PROM puts
its console there, and the colour picture is shown. The mono board stays in the
machine either way, as it does in a real 2/160.

### Clocks

| clock | MHz | from | drives |
|---|---|---|---|
| clk_mem | 100 | `rtl/pll.v` out 0 | SDRAM, the memory side of the bridge, `hps_io`, the colour board's engine, `DDRAM_CLK` |
| cpu_clk | 20, 52% duty | out 1 | the machine, the disk and tape seams, keyboard/mouse |
| clk_pix | 83.333 | out 2 | the 1160x904 raster, 60.4 Hz |
| clk_mii | 2.5 | out 3 | the 82586's MII: 10 Mb/s |
| clk_ser | 4.9152 | `rtl/pll_serial.v` | the SCCs (9600 baud from the PROM's own table), the Am9513, the MM58167 |

`Sun-2.sdc` cuts every crossing between them, because each one is designed as
an asynchronous crossing (it lists them). A new crossing must be one too: two
flops marked `SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS`, or a
dual-clock RAM with a toggle or a request/acknowledge.

**The main PLL has no global clock lines to spare.** It sits on the right edge
of the die, and the global lines it can reach are taken by the HPS, HDMI,
clk_mem, cpu_clk and clk_pix. clk_mii got a regional clock, a quarter of the
die, which is fine for its few hundred registers. Once, clk_mii was used as
`DDRAM_CLK` and forced global, which pushed **cpu_clk** onto a regional clock
and the whole machine into one quadrant. That is the 80-minute fit above. So
`DDRAM_CLK` is clk_mem. Nothing new should get its own clock from this PLL
without checking *Global & Other Fast Signals* afterwards.

**cpu_clk's 52% duty cycle is deliberate.** The worst path is inside RD68011,
from the microcode ROM to `u_biu.d_o`, and it is launched on the rising edge
and caught on the falling one, so it gets the clock's *high time*, not its
period. The two half-period path families are unequal, and the split gives the
tighter one the extra time. `rtl/patched/rd68011/rd68011_shifter.sv` exists for
the same path: `count % w` with `w` a signal made Quartus build a divider on
it, and the patched copy reduces the count without `%`.

### Memory

**SDRAM** (`rtl/sun2_mister_sdram.sv` in front of `rtl/sdram.sv`, BL8, CAS 2),
which needs at least the 32 MB module:

| what | where |
|---|---|
| 8 MiB main memory | from 0 |
| 128 KiB mono frame buffer | 16 MiB |
| the colour board's 1 MiB of pixels, a byte each | 24 MiB |

Each region is in its own bank, so the rows each one keeps open stay open. One
16-byte line is one burst. There are four clients: the CPU through the bridge,
the mono scan-out (absolute priority, small, and gated off while colour is
shown), the colour board's engine, and the colour scan-out. The colour
scan-out needs about half the SDRAM: it takes turns with the others and
demands priority only when `cs_urgent` says it is about to run dry.

**Every client holds its request until it is answered and sees the answer a
clock late**, so after every completion the adapter waits one clock (`S_GAP`)
before it looks at a request again. Without that gap, the request it just
answered is still visible and runs twice, and the repeat's data answers
whatever the client asks for next. Keep that rule for any new client.

**DDR3** holds the network's mailbox and nothing else.

## Layout

| path | what |
|---|---|
| `Sun-2.sv` | the `emu` top: the OSD string, PLLs, `hps_io`, the PROM and ID PROM loaders, resets, the bridges, video, the machine |
| `Sun-2.qsf`, `Sun-2.sdc`, `files.qip` | the configuration, the clock groups, and the source list |
| `rtl/sun2-common/` | the machine: bus, MMU, PROM, Am9513, SCC wiring, memory bridges, mono scan-out, SCSI core, MT-02 tape |
| `rtl/sun2-vme/` | what only a VME machine has: DVMA and bus arbitration, the 82586's control register, the VME SCSI board, the colour board and its scan-out |
| `rtl/sun2_mister_*.sv` | the MiSTer glue: SDRAM, disk and tape bridges, keyboard and mouse, bell, time of day, network |
| `rtl/sdram.sv`, `rtl/pll*.v`, `rtl/pll*/` | Sorgelig's SDRAM controller; the two PLLs, written by hand in the IP wizard's layout |
| `rtl/vendor/` | third-party cores copied in unmodified: RD68011, z8530_scc, Wish5380's SCSI target, Wish82586. Its README gives each one's upstream commit and licence |
| `rtl/patched/` | a vendored file the build needs changed before upstream has taken the change. Its README says what and why |
| `sys/` | Template_MiSTer's framework, verbatim at `3ea1134` |
| `releases/` | what goes on a MiSTer (below) |
| `tb/verilator/` | the Verilator tests: the glue, the tape, the patched shifter, the colour board, and the whole core (below) |
| `tools/mktape` | builds tape images (`.qic`) from a SunOS release, and empty labelled disks |
| `tools/rompatch.c`, `tools/sim_speedup_sun250.txt` | the PROM patcher and the patch list that shortens the PROM's delay loop and skips its destructive memory test, for `tb_emu` |
| `tools/cg2model/` | the colour board's C model, and a harness that runs SunOS 4.0's own libpixrect against it on Musashi, for `tb_cgtwo` |
| `doc/` | the install guide, the colour board's specification, future enhancements |

**`files.qip` is edited by hand, never from the Quartus IDE**, which rewrites
the qsf. Its order and file types matter:

* `rtl/sun2-common/*.v` is **Verilog-2001** and must stay `VERILOG_FILE`. The
  vendored cores, the bridges and the glue are SystemVerilog.
* **Packages come first.** `wish5380_pkg.sv` declares `blk_req_t` and
  `blk_rsp_t` at file scope, so it must be compiled before anything that uses
  them.
* `sys/sys.qip` is pulled in by `sys/sys.tcl`, and `rtl/pll.qip` by
  `sys/pll_q17.qip`. Do not list either again.
* `SEARCH_PATH rtl/sun2-common` is what finds `sun2_config.vh` and
  `sun2_attr.vh`.

**Never edit `rtl/vendor/` or `sys/` in place.** Fix a vendored core upstream
and copy it in again, updating `rtl/vendor/README.md`. If the build needs the
fix sooner, the changed file goes in `rtl/patched/` under the same path, and
`files.qip` points at it until upstream catches up. `sys/` is updated by copying
a newer Template_MiSTer over it whole.

## The contract with Main_MiSTer

The network and the generated ID PROM need a Main_MiSTer with Sun support:
`support/sun/` on the `sun-family` branch of
[danifunker/Main_MiSTer](https://github.com/danifunker/Main_MiSTer/tree/sun-family),
which serves the Sun-3 and SPARCstation cores too. `releases/MiSTer` is a build
of it. Main depends on the following, so **changing any of them breaks it**:

* **The core's name is `Sun-2`.** It is the first field of `CONF_STR`, and
  Main's core table is keyed on it.
* **`status[11:9]` is the OSD's *Network*:** eth0 (0, the default), Off, eth1,
  macvlan, tap0, in the SPARCstation core's order. Main reads the same bits.
* **ioctl index 0 is `boot0.rom`**, the 32 KiB PROM, as big-endian 16-bit
  words. The machine is held in reset until the whole image has arrived.
* **ioctl index 64 is `boot1.rom`**, a 32-byte ID PROM written over the
  built-in one. If there is no `boot1.rom`, Main sends one it generates from the
  MiSTer's Ethernet address (`08:00:20` plus the MiSTer's last three bytes), and
  sends it before `boot0.rom`. `releases/Sun-2_mkidprom.py` writes the same
  thing as a file, to pin an identity.
* **The network mailbox is in DDR3 at ARM physical `0x1FF00000`**, magic
  `S2ETH001`, in the SPARCstation core's layout with 16 receive slots
  (`rtl/sun2_mister_enet.sv` has the map). The core publishes it each time the
  machine leaves reset. That is always after Main has cleared any stale magic
  at start-up, because Main does that before it sends the PROM, and the
  machine is held in reset until the PROM arrives.
* **The disk is VD 0 (`SC0`) and the tape VD 1 (`S1`).** `SC` makes Main mount
  the last disk again whenever the core loads, which is what makes the PROM
  auto-boot SunOS.
* **The serial console is the MiSTer's UART at 9600** (`UART9600`). On the
  MiSTer, SunOS's `/dev/ttya` is `/dev/ttyS1`.

The time of day comes from `hps_io`'s RTC. Only the first value after
configuration is loaded, so a time set with `date(1)` stands until the core is
loaded again, as on a battery-backed clock. It is MiSTer's local time less 36
years: `rtl/sun2_mister_tod.sv` explains why 1990 is the right year for SunOS.

## Before you change the machine

What follows is true of the RTL in this tree and has each cost time. The dev
repo's `CLAUDE.md` has the full history.

**Everything hangs off the 68010 bus, and the MMU sees all of it.** The CPU
drives `P_A`/`P_FC`/`P_AS_n`/`P_RW_n`/`P_UDS_n`/`P_LDS_n`, and `sun2_mmu`
translates through the segment map, then the page map. The page map's TYPE
field selects memory (0), on-board I/O (1) or the VME bus. Device decode, the
protection check, the `C_S3..C_S24` timing chain, DTACK and the bus error
register all key off those wires. DVMA -- the 82586 and the SCSI board's DMA
-- arbitrates for the bus and drives the same wires (`top_fpga.v` muxes them),
so nothing downstream knows DVMA exists.

**Adding a device takes four things**, and missing the last one gives a silent
12-clock timeout and a bus error: instantiate it, add a `MATCH_*` term, add an
arm to the `P_DOUT` read mux before the `16'hDEAD` fall-through, **and** add
it to the read and/or write DTACK terms.

**The bus timeout is how the PROM finds what is fitted**, so anything that does
not decode an address must let the timeout fire. Three things are exempt,
because they cannot answer within `C_S24`'s twelve clocks:

* memory;
* the mono frame buffer;
* the colour board, for a cycle it has decoded (`mb_hit & mb_hold`).

An exempt access whose answer never comes **hangs the machine for good**,
rather than raising a bus error. That is the leading guess for the one hard
hang seen in colour SunView (2026-10-04: no keys, no L1-A, nothing on serial,
Main still up). It has not been reproduced or chased.

**A memory transaction belongs to a data phase, not a bus cycle.** A
read-modify-write (TAS) holds AS from its read half straight through its write
half. When the bridge tracked whole bus cycles, every TAS on memory lost its
write. Answers to the bridge are **tagged**, and an answer for another request
is dropped. That matters because of the next item.

**A refused cycle must not reach memory.** `MMU_REFUSE` is gated by AS, but the
`C_S` chain clears a clock after AS negates. So for one clock, a cycle the MMU
had refused looked like a memory cycle, and the bridge issued a request for it.
Its answer was then taken by the next master's read: one wrong word in tens of
thousands, on disk writes, for a month. `MMU_REFUSED` latches the refusal until
AS negates. Keep any new `MATCH_*` qualified by `MMU_OK`.

**The bridge's read cache** (`sun2_cached_fifo_bridge`, 512 lines of 16 bytes)
is write-through and no-allocate. It installs only an answer carrying the
phase's own tag. Coherence comes free from the bus mux: every master's writes
pass it, and the scan-outs only read. On the Wukong and the DECA it more than
doubled the machine's speed; it has not been measured on a MiSTer. Its lookup runs on the bus address the clock before the data phase, which is
sound because the address has settled by then.

**Resets are four nets, and the differences are load-bearing:**

* `P_RESET_n` is the 68010's RESET instruction plus the machine reset, and goes
  to the peripherals. It is a register, not a combinational term: a glitch on
  it reached an asynchronous preset in the 82586 once.
* `sys_reset` clears the enable and diagnostic registers, the MMU decode and
  DVMA.
* `por_reset` is the machine being switched on: configuration, and on MiSTer
  every reset from outside (the OSD's Reset, a core or MGL load). It resets the
  Am9513, the SCCs and the bridge's `ENABLE`. It is never the watchdog or a
  RESET instruction. When the OSD's Reset was not a `por_reset`, counter 1
  survived it, the PROM's power-up test failed, and the monitor printed
  `Watchdog reset!` and stopped at `>`.
* `cfg_reset` is configuration only, for the battery-backed MM58167.

Memory and video are reset only when the PLLs lose lock, so a machine reset
keeps the SDRAM's contents and the picture.

**Two context registers in one word.** The supervisor context is the even byte
and the user context the odd one, and each is written by a `movsb` to its own
byte, so `ctx_reg.v` must honour UDS/LDS. The PROM always sets both bytes to
the same value; SunOS is the first thing to make them differ.

**The MMU maintains the page map's referenced and modified bits** (entry bits 21
and 20). SunOS's `hat_ptesync` reads and clears them. Until the MMU set them,
no dirty page was ever written back, and nothing the machine wrote reached a
disk or the network. Three rules for them:

* The enable is a **level**, ended by its own idempotence gate, not a one-shot.
  A one-shot would miss the write half of a read-modify-write.
* **A denied access changes neither bit.** SunOS keeps its own data in an
  invalidated entry.
* FC 3 and FC 7 cycles set neither bit. DVMA cycles set them like any other
  access.

**The bus error register re-arms when it is read.** SunOS reads it and never
writes it. When it held the first error until written, the PROM's own device
probes were still latched when the kernel took a fault, and the kernel would
not recover.

**The console has two paths, and only one of them uses interrupts.** Kernel
`printf` goes out through the PROM's `putchar`, which polls RR0 and needs
neither interrupts nor WR9. Userspace goes through the interrupt-driven `zs`
driver. So a perfect autoconfig proves nothing about SCC interrupts. Both SCCs
interrupt at **level 6**; the "priority 3" in `GENERIC` is a software spl.
Kernel lines end `\r\r\r\n` and userspace lines a single `\r`, which tells you
which path a line came from. And `zsa_rxint` raises its soft interrupt only
every 20 characters, so **a short typed line looks exactly like dead input**.

**Device-model rules, each learned from a real bug:**

* **Edge-detect every bus strobe.** The bus holds `RD`/`WR` for several clocks,
  so a level-sensitive write acts more than once. The Am9513's data pointer
  auto-incremented under one, and the NMI ran at 98.9 Hz instead of 40 for
  years.
* **A read-to-clear register latches DOUT at the strobe's leading edge** and
  holds it, so the CPU sees the value from before the clear.
* **Tie every unused input.** An open input on a device model is an X in a
  status register. Three open pins on an SCC's RR0 caused spurious aborts to
  the monitor.
* **Never use an asynchronous input raw in combinational logic beside its own
  sampling flop.** The Am9513's raw oscillator reached its counters' clock
  enables, and the counters skipped counts. Two flops first, then
  edge-detect.
* **The Z8530's WR2 and WR9 belong to the chip, not to a channel**, and SunOS
  writes them through channel B. **A transmit-data write clears the transmit
  IP**, because NetBSD never issues the reset command. Both are fixed upstream
  in `rtl/vendor/z8530_scc` (`b9bcd67`).

**RD68011 is the only CPU in this tree** (`rtl/vendor/rd68011`, `f768c7f`). Two
of its bugs were found by this machine and are fixed upstream: a longword read
torn by a bus grant between its halves, and `ea_latch` being destroyed while a
fault frame was built, so a faulted push resumed at the wrong address. Every
child process SunOS forked used to die of the second one. The dev repo also
builds Suska, whose bus error frames cannot restart an instruction.

**The PROM is Rev Q VME** (`boot0.rom`, sha256 `8560ef68…4a3f`). It is built
from `sun/prom_monitor/msun/mon/RevQs` in the SunOS 3.4 source tree, with
`-DVME` and `S2COLOR`. Note that `msun` and `rsun` there are Rev Q and Rev R of
one tree, not MultiBus and VME. The colour jumper is bit 9 of the video control
register (`0xEE3800`). The dev repo has an annotated disassembly
(`doc/prom/boot0.lst`).

**The VME SCSI board carries the disk, the tape and the clock.** SCSI is at VME
A24 `0x200000`. Its eight registers alias every 16 bytes across the low 2 KiB,
because the board decodes only A1..A3. The MM58167 is at `0x200800`. The tape
(`sun2_mt02.sv`) is an Emulex MT-02 at SCSI target 4. It is read-only, and its
image format is the header `tools/mktape` writes. Its sense data has to satisfy
the PROM's driver and the kernel's at once, and the two disagree; the file's
header says how.

**The colour board** is specified in `doc/cgtwo.md`, from SunOS 4.0's own
libpixrect and kernel. Read that before touching `sun2_cgtwo.sv`. The board has
two halves:

* a card slot on cpu_clk, one request per data phase;
* an engine on clk_mem, which owns the registers, the eight raster-op units,
  the colour maps and the pixels.

They hand over with toggles. The board interrupts at level 4 with vector
`0xa8`. SunOS's `cgtwoprobe` writes through the raster-op units and checks what
it reads back, so without working raster-op units SunOS does not find the
board at all.

## Verifying a change

The tests are in `tb/verilator/` and need Verilator 5 (5.020 under WSL is what
they were last run with).

```sh
make -C tb/verilator                  # the ten unit tests: about 5.5 minutes, each ends PASS
make -C tb/verilator tb_emu           # the whole core: 3 simulated seconds, about 12 minutes
make -C tb/verilator tb_cgtwo         # the colour board against SunOS's own libpixrect
make -C tb/verilator clean; rm -rf build   # each compiled model is ~140 MB, a full set ~1.2 GB
```

* **The unit tests** cover the SDRAM adapter, the disk bridge, the keyboard and
  mouse (alone, and into the real Z8530 the way SunOS drives it), the bell, the
  network's MII side and mailbox, the time of day, the tape drive (against
  images `tools/mktape` itself builds), the SCSI core, and the patched shifter
  against upstream's for every input.
* **`tb_emu`** builds the core from this tree's `files.qip` and `Sun-2.qsf`
  macros, so it cannot drift from the build. Only the PLLs, `hps_io` and the
  SDRAM chip are models. It makes its PROM from `releases/boot0.rom`
  (`BOOT_ROM=` for another) with `tools/sim_speedup_sun250.txt` applied, and
  sends it through the real loader. `DISK=`, `TAPE=` and `KEYS=` feed it.
  With the colour board in, the console is the screen: each changed frame is
  written to `run_tb_emu/screen_*.pgm`, and the serial `console.log` stays
  empty. A run with no disk ends at the Sun-2/160 banner, `Probing I/O bus: sd
  ie`, and `Waiting for disk to spin up...`. Its `stats:` lines measure the
  bridge, the cache and the SDRAM's clients.
* **`tb_cgtwo`** replays a bus trace of SunOS 4.0's libpixrect, recorded by
  `tools/cg2model`'s harness, into `sun2_cgtwo.sv`, and checks every read and
  the whole megabyte. It needs the SunOS 4.0 Sun-2 tapes (`TAPE40=`, the
  directory holding `tape1/`) and fetches Musashi, so it is not part of the
  default target.
* **Each `mutate_*.sh`** breaks the RTL on purpose and checks that its test
  notices. Run it after the test it names.

* **A test earns its keep only if it fails on a mutation.** Break the RTL,
  check the test fails, and revert.
* **A zero is worth exactly as much as the control beside it.** Count the thing
  that must be busy beside the thing that must be zero.
* **Simulation cannot see clock-crossing, metastability or placement faults.**
  A failure that moves between builds of the same logic belongs to that class.
  An identical failure on every retry is software.

**On a board**, a healthy start is:

1. the PROM's self test;
2. `Sun Workstation, Model Sun-2/160` (or `Sun-2/50 or Sun-2/160` with colour
   Off);
3. an auto-boot from `sd(0,0,0)`;
4. `cgtwo0 at vme24 0x400000 vec 0xa8` and `ie0` in autoconfig;
5. `login:`, then `suntools` in colour.

For CPU work quote `/bin/time`'s `user`. Check `ps -aux` for a runaway daemon
first. A SunOS fault is an address until it is resolved: the dev repo's
`tools/pcsym` maps a PC to a kernel symbol, and `adb` on the Sun reads a core
file.

## Releases

`releases/` is synced to MiSTers as it is, so **nothing goes in it but what a
MiSTer needs**:

* the core, `Sun-2_YYYYMMDD.rbf`, with no letter suffix;
* `boot0.rom`;
* `MiSTer`, the Main_MiSTer build with Sun support;
* `Sun-2_mkidprom.py`, the `boot1.rom` writer.

A release is `output_files/Sun-2.rbf` built from committed RTL. When the rbf's
name changes, update the README's *What a user needs* to match.

## Open, and not bugs

* **Open:** the colour hang above.
* **Open:** the colour scan-out costs the CPU about 1%, but slows the colour
  board's own drawing about 3.5 times. The cause is the engine dropping its
  request between write-back halfwords. `doc/futureenhancements.md` has the
  tested fix and the alternatives; none is in the RTL.
* **Open:** the SunOS 4.0 libpixrect bugs listed in `doc/cgtwo.md`.
* **Not a bug: disks top out at 1 GiB.** Every Sun-2 SCSI driver sends the
  six-byte READ and WRITE, whose block address is 21 bits.
* **Not a bug: partitions top out just under 32 MB.** The standalone driver
  keeps a partition's size in 16 bits, so a 65536-block partition reads as
  empty.
* **Not a bug: GENERIC_SMALL has no colour driver.** It is the kernel the 4.0.3
  upgrade installs, so SunView will not start under it. Boot
  `sd()vmunix.orig`, which is GENERIC.
* **Not a bug: `SUMMARY INFORMATION BAD (SALVAGED)` means the clock went
  backwards.** It is not disk damage.

## Traps

* **A Windows checkout with `core.autocrlf` gives CRLF RTL**, and an edit that
  matches exact strings across lines can miss. Normalise, edit, and restore.
  Scripts are LF everywhere (`.gitattributes`).
* **A port left off an instantiation reaches the board dead.** `fb_video_en`
  was unconnected in every bitstream of the Wukong era, so the frame buffer
  could not display, while every simulation drove the module one level below
  and passed. Compare a module's port list against its instantiation
  mechanically, and watch for `Warning (10236)`.
* **A case statement wider than its labels is not a ROM to Quartus.** An
  incomplete case is built in gates, silently. Size an index to its table.
* **Quartus refuses a constant loop of more than 5000 iterations.**
  `VERILOG_CONSTANT_LOOP_LIMIT` is raised to 65536 in the qsf; assume any new
  array that is initialised in a loop needs it.
* **`$random` in an unguarded `initial` is an error in Quartus.** Keep
  simulation-only power-up randomness behind `SUN2_SIM`, as `ctx_reg.v` and
  `gen8bit_reg.v` do.
* **A module with no body is a black box**, which some flows refuse. `tolog`
  and the other simulation hooks are behind `SUN2_SIM` and are not in this
  tree.
