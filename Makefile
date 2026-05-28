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
SRC_S := src/reset.s src/irq.s src/screen.s src/kernal_stubs.s src/c_io.s src/iec.s
SRC_C := src/shell.c src/parser.c src/commands/builtins.c src/commands/fs.c src/commands/mem.c src/commands/config.c
OBJ   := $(patsubst src/%.s,$(BUILD)/%.o,$(SRC_S)) \
         $(patsubst src/%.c,$(BUILD)/%.o,$(SRC_C))

BASIC  := $(BUILD)/basic.bin
KERNAL := $(BUILD)/kernal.bin
ROM16K := $(BUILD)/rom16k.bin

.PHONY: all clean check-tools run test test-verbose onerom onerom-flash

all: $(ROM16K)

$(BUILD):
	mkdir -p $(BUILD)

# mkdir -p $(@D): sources under a subdirectory (e.g. src/commands/) mirror
# their path into build/, so the output directory may not exist yet.
$(BUILD)/%.o: src/%.s | $(BUILD)
	@mkdir -p $(@D)
	$(AS) $(ASFLAGS) -o $@ $<

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

# Build the firmware AND flash a connected One ROM in one step. Plug the device
# in (USB), then run `make onerom-flash`. ONEROM_BOARD must match the connected
# device. Pass ONEROM_SERIAL='5*' (or similar wildcard) to pick one of several.
onerom-flash: $(BASIC) $(KERNAL)
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--board $(ONEROM_BOARD) --config-file $(ONEROM_CFG) \
		--out $(BUILD)/onerom-$(ONEROM_BOARD).bin

# Same suite, but show the launch command, monitor traffic, and tracebacks.
test-verbose: all
	VICE_VERBOSE=1 $(PYTHON) test/run_tests.py

clean:
	rm -rf $(BUILD)
