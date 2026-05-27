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

ASFLAGS := --cpu 6502

SRC_S := src/reset.s src/irq.s
OBJ   := $(patsubst src/%.s,$(BUILD)/%.o,$(SRC_S))

BASIC  := $(BUILD)/basic.bin
KERNAL := $(BUILD)/kernal.bin
ROM16K := $(BUILD)/rom16k.bin

.PHONY: all clean check-tools run test

all: $(ROM16K)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/%.o: src/%.s | $(BUILD)
	$(AS) $(ASFLAGS) -o $@ $<

# One ld65 invocation writes both binaries (file= is set per memory area in
# the linker config). kernal.bin is the rule target; basic.bin rides along.
$(KERNAL): $(OBJ) $(CFG) | $(BUILD)
	$(LD) -C $(CFG) $(OBJ)
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

run: all
	$(VICE) -kernal $(KERNAL) -basic $(BASIC) $(VICEFLAGS)

test: all
	$(PYTHON) test/smoke_test.py

clean:
	rm -rf $(BUILD)
