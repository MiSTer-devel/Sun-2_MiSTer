# RD68011 regression tests for this tree's own fixes to the CPU, run against
# the core as files.qip builds it (rtl/vendor/rd68011, with rtl/patched/rd68011
# in place of the files it replaces), under iverilog: the harness and the
# memory model are upstream RD68011's, which targets iverilog.
#
#   make -C tb/rd68011            run them
#   make -C tb/rd68011 hex M68K=m68k-linux-gnu    rebuild the .hex images
#
# rmwfault: a read-modify-write in loop mode (`and.l Dn,(An)+ ; dbf`) faulted
# on its read or its write half, and resumed by RTE. A fault on the write
# half comes after the pipe has handed over to the DBcc, and the core used to
# resume that DBcc with its own opcode as the displacement -- libpixrect's
# mem_rop under SunOS 4 (chesstool's SIGBUS) and anything else that writes a
# paged-out page in a tight loop. rmwfault.S runs it in supervisor mode with
# five handlers, rmwfault_user.S in user mode with the trace bit SunOS sets.
#
# The .hex images are checked in because the m68k cross toolchain is not part
# of the MiSTer build; `make hex` regenerates them where one is installed.

# The core as files.qip builds it: rtl/vendor/rd68011, with the files that
# rtl/patched/rd68011 replaces taken from there instead.
RTL  := ../../rtl/vendor/rd68011
PAT  := ../../rtl/patched/rd68011
PATCHED := $(notdir $(wildcard $(PAT)/*.sv))
SRCS := $(RTL)/rd68011_pkg.sv $(RTL)/gen/rd68011_ucode_pkg.sv \
        $(filter-out $(RTL)/gen/rd68011_ucode_pkg.sv,$(wildcard $(RTL)/gen/*.sv)) \
        $(filter-out $(RTL)/rd68011_pkg.sv $(addprefix $(RTL)/,$(PATCHED)),$(wildcard $(RTL)/*.sv)) \
        $(wildcard $(PAT)/*.sv) \
        rd68011_slave.sv rmwfault_tb.sv
OBJ  := obj
BERR := +berr=6273 +timeout=4000000

M68K ?= m68k-linux-gnu

all: rmwfault

$(OBJ)/rmwfault.vvp: $(SRCS) rd68011_core_harness.svh
	mkdir -p $(OBJ)
	iverilog -g2012 -Wno-timescale -I . -o $@ -s rmwfault_tb $(SRCS)

# Each program with the fault on the read half and on the write half; every
# run must PASS. 6273 is word 0x3102, the first word of a longword the loop
# writes.
rmwfault: $(OBJ)/rmwfault.vvp
	@fail=0; for p in rmwfault rmwfault_user; do for w in "" +berr_wr; do \
	  r=$$(vvp $(OBJ)/rmwfault.vvp +prog=$$p.hex $(BERR) $$w 2>&1 | grep -E '^(PASS|FAIL)' | head -1); \
	  echo "$$p $${w:-+berr_rd}: $$r"; case "$$r" in PASS*) ;; *) fail=1;; esac; \
	done; done; exit $$fail

hex:
	for p in rmwfault rmwfault_user; do \
	  $(M68K)-gcc -m68010 -nostdlib -c -x assembler-with-cpp -I. -Wa,-I. -o $(OBJ)/$$p.o $$p.S && \
	  $(M68K)-ld -T link.ld -o $(OBJ)/$$p.elf $(OBJ)/$$p.o && \
	  $(M68K)-objcopy -O binary $(OBJ)/$$p.elf $(OBJ)/$$p.bin && \
	  python3 bin2hex.py $(OBJ)/$$p.bin > $$p.hex || exit 1; done

clean:
	rm -rf $(OBJ)

.PHONY: all rmwfault hex clean
