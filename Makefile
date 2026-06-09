# Makefile - C64 Shell ROM (Phase 0)
#
#   make            build build/kernal.bin, build/basic.bin, build/rom16k.bin
#   make test       build, then run the VICE smoke test
#   make run        build, then launch VICE with the ROM
#   make check-tools verify the toolchain is on PATH
#   make clean      remove build artifacts

AS     := ca65
LD     := ld65
CC     := cc65
PYTHON := python3
VICE   := x64sc

BUILD  := build
CFG    := cfg/rom.cfg

# One ROM firmware build (see `make onerom`). The board defaults to a 24-pin
# Fire; override per your hardware, e.g. `make onerom ONEROM_BOARD=fire-28-a`.
# `tools/onerom scan --list-boards` lists known boards.
ONEROM       := tools/onerom
ONEROM_BOARD ?= fire-24-e
ONEROM_CFG   := cfg/onerom.json

ASFLAGS   := --cpu 6502
# -I src so a C file can include a header by its path under src/, e.g.
# "commands/builtins.h", from anywhere in the tree.
CC65FLAGS := -t none -O --cpu 6502 -I src

# cc65 runtime library: the `none` target carries the runtime helpers (stack,
# zerobss, copydata, ...) without any platform startup or conio. Located
# relative to the cc65 binary so the build is self-contained on any install.
CC65_LIBDIR := $(dir $(shell command -v cc65))../share/cc65/lib
RTLIB       := $(CC65_LIBDIR)/none.lib

# Link order matters: reset.o must come first so `reset` lands at $E000.
SRC_S := src/reset.s src/irq.s src/screen.s src/kernal_stubs.s src/c_io.s src/iec.s \
         src/fastload_blob.s src/fastload_recv.s src/fastload_send.s \
         src/rbcp/rbcp.s src/rbcp/launch.s
SRC_C := src/shell.c src/parser.c src/fastload.c \
         src/commands/builtins.c src/commands/fs.c src/commands/mem.c src/commands/config.c
OBJ   := $(patsubst src/%.s,$(BUILD)/%.o,$(SRC_S)) \
         $(patsubst src/%.c,$(BUILD)/%.o,$(SRC_C))

BASIC  := $(BUILD)/basic.bin
KERNAL := $(BUILD)/kernal.bin
ROM16K := $(BUILD)/rom16k.bin

.PHONY: all clean check-tools run test test-verbose onerom onerom-flash onerom-stock onerom-stock-flash onerom-pure-stock-flash memtest memtest-flash

all: $(ROM16K)

$(BUILD):
	mkdir -p $(BUILD)

# mkdir -p $(@D): sources under a subdirectory (e.g. src/commands/) mirror
# their path into build/, so the output directory may not exist yet.
$(BUILD)/%.o: src/%.s | $(BUILD)
	@mkdir -p $(@D)
	$(AS) $(ASFLAGS) -o $@ $<

# The RBCP library uses `.include "rbcp_defs.s"` / `.include "rbcp_config.s"`,
# which ca65 resolves but make doesn't track. Force a rebuild of rbcp.o if
# either include changes.
$(BUILD)/rbcp/rbcp.o: src/rbcp/rbcp_defs.s src/rbcp/rbcp_config.s

# Drive-side fast-loader image. Assembled separately (origin $0500 in the
# 1541's RAM) and incbin'd into the host ROM by src/fastload_blob.s. The
# blob's object depends on the bin so make tracks the dep graph correctly.
$(BUILD)/fastload_drive.bin: src/fastload_drive.s cfg/fastload_drive.cfg | $(BUILD)
	$(AS) $(ASFLAGS) -o $(BUILD)/fastload_drive.o src/fastload_drive.s
	$(LD) -C cfg/fastload_drive.cfg $(BUILD)/fastload_drive.o -o $@
	@echo "  fastload_drive.bin: $$(wc -c < $@) bytes"
$(BUILD)/fastload_blob.o: $(BUILD)/fastload_drive.bin

# C is compiled to assembly by cc65, then assembled by ca65 (keep the .s so a
# build leaves the generated assembly around for inspection).
.PRECIOUS: $(BUILD)/%.s
$(BUILD)/%.s: src/%.c | $(BUILD)
	@mkdir -p $(@D)
	$(CC) $(CC65FLAGS) -o $@ $<

$(BUILD)/%.o: $(BUILD)/%.s | $(BUILD)
	@mkdir -p $(@D)
	$(AS) $(ASFLAGS) -o $@ $<

# One ld65 invocation writes both binaries (file= is set per memory area in
# the linker config). kernal.bin is the rule target; basic.bin rides along.
# The cc65 runtime library resolves the stack/zerobss/copydata helpers the
# compiled C pulls in.
# -Ln writes a VICE label file (build/labels.txt) for monitor debugging and so
# tests can locate exported symbols (e.g. keytab_shift) in the ROM.
$(KERNAL): $(OBJ) $(CFG) | $(BUILD)
	$(LD) -C $(CFG) $(OBJ) $(RTLIB) -Ln $(BUILD)/labels.txt
	@echo "  basic.bin : $$(wc -c < $(BASIC)) bytes"
	@echo "  kernal.bin: $$(wc -c < $(KERNAL)) bytes"

$(BASIC): $(KERNAL) ;

$(ROM16K): $(BASIC) $(KERNAL)
	cat $(BASIC) $(KERNAL) > $(ROM16K)
	@echo "  rom16k.bin: $$(wc -c < $(ROM16K)) bytes"

check-tools:
	@ok=1; for t in $(AS) $(LD) $(CC) $(PYTHON) $(VICE); do \
		if command -v $$t >/dev/null 2>&1; then \
			printf "OK   %-8s %s\n" "$$t" "$$(command -v $$t)"; \
		else \
			printf "MISS %-8s NOT FOUND\n" "$$t"; ok=0; \
		fi; \
	done; \
	if [ $$ok -eq 1 ]; then echo "All required tools present."; else \
		echo "Missing tools; see CLAUDE.md Toolchain section."; exit 1; fi

# Pass DISK=path to attach a disk image on device 8 (needed for ls/load),
# e.g. `make run DISK=test/data/test.d64`. A fresh writable copy is mounted,
# so the tracked image is never modified by the session.
run: all
	SKIP_BUILD=1 VICE=$(VICE) DISK=$(DISK) ./run.sh $(VICEFLAGS)

test: all
	$(PYTHON) test/run_tests.py

# Build a One ROM firmware image holding both halves as a single multi-ROM set
# (kernal.bin + basic.bin, served via two_cs_one_addr -- two active-low chip
# selects on a shared address bus, matching the C64's KERNAL and BASIC /CS).
# Output: build/onerom-<board>.bin. Flash with `make onerom-flash`.
onerom: $(BASIC) $(KERNAL)
	$(ONEROM) firmware build --board $(ONEROM_BOARD) --config-file $(ONEROM_CFG) \
		--out $(BUILD)/onerom-$(ONEROM_BOARD).bin
	@echo "  onerom fw : $$(wc -c < $(BUILD)/onerom-$(ONEROM_BOARD).bin) bytes ($(ONEROM_BOARD))"

# Build a One ROM firmware that pairs our shell with stock C64 BASIC+KERNAL
# as a second bank, plus the user/host-control plugin so the shell can drive a
# runtime bank-switch via the RBCP protocol (see src/rbcp/). Requires stock
# C64 ROMs at stock-roms/ -- they're freely distributable from Commodore's
# released sources, drop them in yourself (gitignored).
ONEROM_STOCK_BASIC  := stock-roms/basic.901226-01.bin
ONEROM_STOCK_KERNAL := stock-roms/kernal.901227-03.bin
onerom-stock: $(BASIC) $(KERNAL) $(ONEROM_STOCK_BASIC) $(ONEROM_STOCK_KERNAL)
	$(ONEROM) firmware build --board $(ONEROM_BOARD) \
		--config-file cfg/onerom-stock.json \
		--out $(BUILD)/onerom-stock-$(ONEROM_BOARD).bin
	@echo "  onerom-stock fw : $$(wc -c < $(BUILD)/onerom-stock-$(ONEROM_BOARD).bin) bytes ($(ONEROM_BOARD))"

# Build the bank-swap firmware AND flash a connected One ROM, then reboot it
# into running mode. Same shape as onerom-flash, but uses cfg/onerom-stock.json
# so the device gets host-control + the stock-ROM second bank.
onerom-stock-flash: $(BASIC) $(KERNAL) $(ONEROM_STOCK_BASIC) $(ONEROM_STOCK_KERNAL)
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--board $(ONEROM_BOARD) --config-file cfg/onerom-stock.json \
		--out $(BUILD)/onerom-stock-$(ONEROM_BOARD).bin
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') reboot

# Baseline / bisect target: flash *only* stock C64 BASIC+KERNAL (plus the
# system/usb plugin so we can still manage the device). None of our shell,
# no host-control plugin. Used to answer "is the OneROM hardware+wiring
# fine?" -- if this boots cleanly to the stock C64 READY prompt but our
# shell flashes show artifacts, the issue is in our ROM image; if even
# this shows artifacts, the issue is OneROM-side.
onerom-pure-stock-flash: $(ONEROM_STOCK_BASIC) $(ONEROM_STOCK_KERNAL)
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--board $(ONEROM_BOARD) --config-file cfg/onerom-pure-stock.json \
		--out $(BUILD)/onerom-pure-stock-$(ONEROM_BOARD).bin
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') reboot

# Build the firmware AND flash a connected One ROM, then reboot it into the
# running (byte-serving) state. Plug the device in (USB), then `make onerom-
# flash`. ONEROM_BOARD must match the connected device. Pass ONEROM_SERIAL='5*'
# (or similar wildcard) to pick one of several. The reboot needs the USB system
# plugin embedded in the firmware (cfg/onerom.json -- slot 0).
onerom-flash: $(BASIC) $(KERNAL)
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--board $(ONEROM_BOARD) --config-file $(ONEROM_CFG) \
		--out $(BUILD)/onerom-$(ONEROM_BOARD).bin
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') reboot

# ----------------------------------------------------------------------------
# Hardware bus diagnostic ROM (`make memtest` / `make memtest-flash`).
#
# Standalone 16KB ROM that replaces the shell entirely. On boot it reads
# known sentinel bytes from BASIC and KERNAL banks and prints expected-vs-
# actual values to the screen. Helps distinguish address-line / data-line /
# CS / transient bus faults on real hardware. See src/memtest/memtest.s for
# the test layout.
# ----------------------------------------------------------------------------
MEMTEST_OBJ := $(BUILD)/memtest/memtest.o $(BUILD)/memtest/memtest_basic.o
MEMTEST_KERNAL := $(BUILD)/memtest-kernal.bin
MEMTEST_BASIC  := $(BUILD)/memtest-basic.bin

$(MEMTEST_KERNAL): $(MEMTEST_OBJ) cfg/memtest.cfg | $(BUILD)
	$(LD) -C cfg/memtest.cfg $(MEMTEST_OBJ) -Ln $(BUILD)/memtest-labels.txt
	@echo "  memtest-basic.bin : $$(wc -c < $(MEMTEST_BASIC)) bytes"
	@echo "  memtest-kernal.bin: $$(wc -c < $(MEMTEST_KERNAL)) bytes"

$(MEMTEST_BASIC): $(MEMTEST_KERNAL) ;

memtest: $(MEMTEST_KERNAL) $(MEMTEST_BASIC)
	$(ONEROM) firmware build --board $(ONEROM_BOARD) \
		--config-file cfg/onerom-memtest.json \
		--out $(BUILD)/onerom-memtest-$(ONEROM_BOARD).bin
	@echo "  onerom-memtest fw : $$(wc -c < $(BUILD)/onerom-memtest-$(ONEROM_BOARD).bin) bytes ($(ONEROM_BOARD))"

memtest-flash: $(MEMTEST_KERNAL) $(MEMTEST_BASIC)
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--board $(ONEROM_BOARD) --config-file cfg/onerom-memtest.json \
		--out $(BUILD)/onerom-memtest-$(ONEROM_BOARD).bin
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') reboot

# Same suite, but show the launch command, monitor traffic, and tracebacks.
test-verbose: all
	VICE_VERBOSE=1 $(PYTHON) test/run_tests.py

clean:
	rm -rf $(BUILD)
