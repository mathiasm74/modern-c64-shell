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
SRC_C := src/shell.c src/parser.c src/commands/builtins.c src/commands/fs.c src/commands/mem.c
OBJ   := $(patsubst src/%.s,$(BUILD)/%.o,$(SRC_S)) \
         $(patsubst src/%.c,$(BUILD)/%.o,$(SRC_C))

BASIC  := $(BUILD)/basic.bin
KERNAL := $(BUILD)/kernal.bin
ROM16K := $(BUILD)/rom16k.bin

.PHONY: all clean check-tools run test test-verbose

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
$(KERNAL): $(OBJ) $(CFG) | $(BUILD)
	$(LD) -C $(CFG) $(OBJ) $(RTLIB)
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
# e.g. `make run DISK=test/data/test.d64`.
run: all
	SKIP_BUILD=1 VICE=$(VICE) DISK=$(DISK) ./run.sh $(VICEFLAGS)

test: all
	$(PYTHON) test/run_tests.py

# Same suite, but show the launch command, monitor traffic, and tracebacks.
test-verbose: all
	VICE_VERBOSE=1 $(PYTHON) test/run_tests.py

clean:
	rm -rf $(BUILD)
