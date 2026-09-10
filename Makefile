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

# PINNED firmware version. Firmware 0.7.x sizes RAM slots by ROM type (a
# single 2364 = 8KB, a multi-ROM set = 64KB; pre-0.7.0 everything was 64KB,
# which is the only reason loading a single-ROM overlay set into the
# multi-ROM-served slot ever worked -- per Piers, an accident). LOAD_SLOT
# now refuses the size mismatch, so cfg/onerom-stock.json carries each
# overlay image tripled into a 3-chip multi set to match (hardware-validated
# on 0.7.1, 2026-09-04; the tripled-overlay workaround still holds on 0.7.2,
# hardware-validated 2026-09-09). Moved 0.7.1 -> 0.7.2 chasing the recurring
# "One ROM drops off USB during programming" gremlin (0.7.2 is where a proper
# "copy single ROM into multi-ROM slot" primitive + the ROM-bank-swap command
# architecture were expected; revisit those when needed).
ONEROM_FW_VERSION ?= 0.7.2

# Plugins are supplied on the CLI (not pinned in the config JSONs), so every
# build picks the latest plugin versions compatible with the firmware the CLI
# targets -- required from firmware v0.7.0 on, which needs newer plugins than
# the old pinned URLs (per Piers, the One ROM author). The CLI places the
# system plugin in slot 0 and the user plugin in slot 1, shifting the config's
# ROM sets up to slots 2+ -- byte-identical to the old plugins-in-config layout,
# so RBCP's absolute slot numbers (stock=3, font B=6) are preserved. host-control
# (a user plugin) is only on the stock-fallback firmware that drives the RBCP
# bank swap; the plain/pure-stock/memtest images take just usb.
ONEROM_PLUGINS       := --plugin usb --plugin host-control
ONEROM_PLUGINS_USB   := --plugin usb

# Version string, taken from the single source of truth (the boot banner in
# reset.s, e.g. "v0.1.48") so the flashable artifact name can't go stale.
VERSION := $(shell grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' src/reset.s | head -1)

# The flashable deliverable (stock-fallback firmware): named for distribution as
# c64-tardis-dos-<version>-for-onerom-<board>.bin.
ONEROM_STOCK_OUT := $(BUILD)/c64-tardis-dos-$(VERSION)-for-onerom-$(ONEROM_BOARD).bin

ASFLAGS   := --cpu 6502
# `make TRACE=1` builds the RBCP swap with border-color stage stamps
# (RBCP_BOOT_TRACE, src/rbcp/launch.s) for timing the stock-ROM handoff on
# hardware -- $D020 shows even while the display is blanked. Debug builds
# only; make does not track the flag, so `make clean` when toggling it.
ifeq ($(TRACE),1)
ASFLAGS += -D RBCP_BOOT_TRACE
endif
# Optional extra ca65/cc65 defines. `make EXTRA_DEFS='-D NO_RBCP'` builds the
# C128 C64-mode variant, which strips ALL boot/idle One ROM RBCP (reset.s +
# shell.c) -- that firmware has no host-control plugin, so a handshake hangs the
# boot before the display comes up. make doesn't track the flag, so `make clean`
# when toggling it.
EXTRA_DEFS ?=
ASFLAGS += $(EXTRA_DEFS)
# The C128 build's overlay flash sets have different loadable-set indices than
# the C64 firmware (see tools/gen_overlay_pages.py), so tell the generator.
ifneq (,$(findstring TARGET_C128,$(EXTRA_DEFS)))
export OVL_C128 := 1
endif
# -I src so a C file can include a header by its path under src/, e.g.
# "commands/builtins.h", from anywhere in the tree.
CC65FLAGS := -t none -O --cpu 6502 -I src -I $(BUILD) $(EXTRA_DEFS)

# cc65 data dir (asminc, include, cfg, target libs). The tools normally find this
# relative to their own binary, but a cc65 built from source and installed to a
# non-default prefix (e.g. ~/.local) can bake in the wrong search path -- the
# assembler then can't find asminc headers like longbranch.mac. Set it explicitly,
# relative to the cc65 binary, so it's correct for a brew install AND a from-source
# install. (Harmless when the tools would have found it anyway.)
export CC65_HOME := $(abspath $(dir $(shell command -v cc65))../share/cc65)

# -Cl (static locals) on the RESIDENT shell C only: ~+470 free BASIC-ROM bytes.
# It trips cc65 issue #1077 on released compilers (<= V2.19) -- a post-increment
# subscript on a constant-address base (cast-pointer #define) with a static char
# index miscompiles to a pre-increment. This codebase uses constant-address
# accesses everywhere (mailboxes, fixed buffers), so on V2.18 it corrupted
# hardware-only paths the VICE suite can't see (garbled help, cd stage-5, flaky
# ls/dir, "8 >" prompt; v0.39-v0.41). Only a FROM-SOURCE (git) cc65 has the #1077
# fix, so gate -Cl on that: a "Git" build gets it, a released build silently skips
# it and stays correct. Overlays never get -Cl (cached/re-run; outside the 16KB
# ROM, so no benefit). Validated: test_cd (the #1077 canary) passes with -Cl on
# the git compiler; full suite green. Re-enabled v0.43 after the from-source swap.
CC65_IS_GIT := $(shell cc65 --version 2>&1 | grep -c Git)
ifeq ($(CC65_IS_GIT),1)
CC65FLAGS_RESIDENT := $(CC65FLAGS) -Cl
else
CC65FLAGS_RESIDENT := $(CC65FLAGS)
endif

# cc65 runtime library: the `none` target carries the runtime helpers (stack,
# zerobss, copydata, ...) without any platform startup or conio. Located
# relative to the cc65 binary so the build is self-contained on any install.
CC65_LIBDIR := $(dir $(shell command -v cc65))../share/cc65/lib
RTLIB       := $(CC65_LIBDIR)/none.lib

# Link order matters: reset.o must come first so `reset` lands at $E000.
SRC_S := src/reset.s src/irq.s src/screen.s src/kernal_stubs.s src/c_io.s src/iec.s \
         src/fastload_recv.s src/fastload_send.s src/svc.s src/complete.s \
         src/rbcp/rbcp.s src/rbcp/launch.s
SRC_C := src/shell.c src/parser.c src/fastload.c \
         src/commands/builtins.c src/commands/fs.c src/commands/mem.c src/commands/config.c \
         src/commands/overlay.c
OBJ   := $(patsubst src/%.s,$(BUILD)/%.o,$(SRC_S)) \
         $(patsubst src/%.c,$(BUILD)/%.o,$(SRC_C))

BASIC  := $(BUILD)/basic.bin
KERNAL := $(BUILD)/kernal.bin
ROM16K := $(BUILD)/rom16k.bin

.PHONY: all banks clean check-tools run test test-verbose onerom onerom-flash onerom-stock onerom-pure-stock-flash onerom-c128 onerom-c128-flash onerom-c64c onerom-c64c-flash memtest memtest-flash sizes

all: $(ROM16K)

# Per-command ROM code-size report (body + call-graph-attributed helpers).
sizes: all
	@python3 tools/cmd_sizes.py $(BUILD)

$(BUILD):
	mkdir -p $(BUILD)

# mkdir -p $(@D): sources under a subdirectory (e.g. src/commands/) mirror
# their path into build/, so the output directory may not exist yet.
$(BUILD)/%.o: src/%.s | $(BUILD)
	@mkdir -p $(@D)
	$(AS) $(ASFLAGS) -o $@ $<

# The RBCP library uses `.include "rbcp_defs.s"` / `.include "rbcp_config.s"`,
# which ca65 resolves but make doesn't track. Force a rebuild of rbcp.o (and
# launch.o, which includes the defs too) if either include changes.
$(BUILD)/rbcp/rbcp.o: src/rbcp/rbcp_defs.s src/rbcp/rbcp_config.s
$(BUILD)/rbcp/launch.o: src/rbcp/rbcp_defs.s src/rbcp/rbcp_config.s

# Tardis overlay library (PLAN.md backlog #4). Each overlay in src/overlays/
# is linked standalone (single-page at the $CE00 cache, multi-page at $8800)
# and padded to a 256-byte page multiple. The overlays then pack into TWO 8KB
# flash sets, each a 2364 chip_set in the One ROM firmware: set A (loadable ROM
# set 2) = about+files+dir, set B (loadable ROM set 3) = edit. Two sets, not
# one 16KB set, because a SLOT_PEEK across two chips of a single set isn't
# contiguous; keeping each overlay wholly inside one 8KB chip means every fetch
# stays in the proven 8KB-SLOT_PEEK case. Not part of the 16KB shell ROM --
# only the onerom-stock firmware carries them. The A/B split and intra-set
# page order are defined in tools/gen_overlay_pages.py (LAYOUT) and mirrored by
# the overlays_a/b.bin rules below; build/overlay_pages.h is generated from the
# .bin sizes so the resident thunks never hardcode a page or set number.
OVERLAYS := $(BUILD)/overlays/about.bin $(BUILD)/overlays/files.bin $(BUILD)/overlays/dir.bin $(BUILD)/overlays/edit.bin $(BUILD)/overlays/picker.bin
# Set/page order MUST match LAYOUT in tools/gen_overlay_pages.py. set A keeps
# files+dir (30 pages); set B holds edit+about+picker (27) -- the two 20-page
# overlays (files, edit) must stay in different 32-page chips.
# Set packing (three 32-page sets since v0.1.63): A = files alone (room to
# grow -- it's the overlay that keeps growing), B = edit+dir (32, exactly
# full), C = about+picker (9). overlays_c is APPENDED in onerom-stock.json so
# font B's loadable set index stays 4; C is loadable set 5.
OVERLAYS_A := $(BUILD)/overlays/files.bin
OVERLAYS_B := $(BUILD)/overlays/edit.bin
OVERLAYS_C := $(BUILD)/overlays/about.bin $(BUILD)/overlays/picker.bin $(BUILD)/overlays/dir.bin
OVERLAY_SETS := $(BUILD)/overlays_a.bin $(BUILD)/overlays_b.bin $(BUILD)/overlays_c.bin

# The edit overlay is cc65-compiled C linked standalone at $8800 (multi-page;
# cfg/overlay_edit.cfg). crt0 must link first so the header sits at the base.
# The binary is padded to a 256 multiple so later overlays stay page-aligned.
$(BUILD)/overlays/edit.s: src/overlays/edit.c | $(BUILD)
	@mkdir -p $(BUILD)/overlays
	$(CC) $(CC65FLAGS) -o $@ $<
$(BUILD)/overlays/edit_c.o: $(BUILD)/overlays/edit.s
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/overlays/edit.bin: $(BUILD)/overlays/crt0.o $(BUILD)/overlays/edit_c.o cfg/overlay_edit.cfg
	$(LD) -C cfg/overlay_edit.cfg -o $@ $(BUILD)/overlays/crt0.o $(BUILD)/overlays/edit_c.o $(RTLIB)
	python3 -c "f=open('$@','r+b'); f.seek(0,2); n=f.tell(); f.write(b'\xff'*((-n)%256))"
	@echo "  edit overlay: $$(wc -c < $@) bytes"

# The files overlay (cat/less/cp/mv/rm), same multi-page C recipe as edit.
$(BUILD)/overlays/files.s: src/overlays/files.c | $(BUILD)
	@mkdir -p $(BUILD)/overlays
	$(CC) $(CC65FLAGS) -o $@ $<
$(BUILD)/overlays/files_c.o: $(BUILD)/overlays/files.s
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/overlays/files.bin: $(BUILD)/overlays/crt0_files.o $(BUILD)/overlays/files_c.o cfg/overlay_files.cfg
	$(LD) -C cfg/overlay_files.cfg -o $@ $(BUILD)/overlays/crt0_files.o $(BUILD)/overlays/files_c.o $(RTLIB)
	python3 -c "f=open('$@','r+b'); f.seek(0,2); n=f.tell(); f.write(b'\xff'*((-n)%256))"
	@echo "  files overlay: $$(wc -c < $@) bytes"

# The dir overlay (dir/ls/pwd); calls the resident IEC/Epyx via the $FF80 table
# (cfg/overlay_dir.cfg binds the svc_* symbols there).
$(BUILD)/overlays/dir.s: src/overlays/dir.c src/overlays/svc.h | $(BUILD)
	@mkdir -p $(BUILD)/overlays
	$(CC) $(CC65FLAGS) -o $@ $<
$(BUILD)/overlays/dir_c.o: $(BUILD)/overlays/dir.s
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/overlays/dir.bin: $(BUILD)/overlays/crt0_dir.o $(BUILD)/overlays/dir_c.o cfg/overlay_dir.cfg
	$(LD) -C cfg/overlay_dir.cfg -o $@ $(BUILD)/overlays/crt0_dir.o $(BUILD)/overlays/dir_c.o $(RTLIB)
	python3 -c "f=open('$@','r+b'); f.seek(0,2); n=f.tell(); f.write(b'\xff'*((-n)%256))"
	@echo "  dir overlay: $$(wc -c < $@) bytes"

# The about overlay is self-contained asm linked multi-page at $8800
# (cfg/overlay_about.cfg); padded to a 256 multiple to stay page-aligned.
$(BUILD)/overlays/about.bin: $(BUILD)/overlays/about.o cfg/overlay_about.cfg
	$(LD) -C cfg/overlay_about.cfg -o $@ $(BUILD)/overlays/about.o
	python3 -c "f=open('$@','r+b'); f.seek(0,2); n=f.tell(); f.write(b'\xff'*((-n)%256))"
	@echo "  about overlay: $$(wc -c < $@) bytes"

# The color-picker overlay (border/bg/text with no value): cc65 C, only
# k_chrout/k_getin (crt0_picker.s, cfg/overlay_picker.cfg).
$(BUILD)/overlays/picker.s: src/overlays/picker.c | $(BUILD)
	@mkdir -p $(BUILD)/overlays
	$(CC) $(CC65FLAGS) -o $@ $<
$(BUILD)/overlays/picker_c.o: $(BUILD)/overlays/picker.s
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/overlays/picker.bin: $(BUILD)/overlays/crt0_picker.o $(BUILD)/overlays/picker_c.o cfg/overlay_picker.cfg
	$(LD) -C cfg/overlay_picker.cfg -o $@ $(BUILD)/overlays/crt0_picker.o $(BUILD)/overlays/picker_c.o $(RTLIB)
	python3 -c "f=open('$@','r+b'); f.seek(0,2); n=f.tell(); f.write(b'\xff'*((-n)%256))"
	@echo "  picker overlay: $$(wc -c < $@) bytes"


$(BUILD)/overlays/%.o: src/overlays/%.s | $(BUILD)
	@mkdir -p $(BUILD)/overlays
	$(AS) $(ASFLAGS) -o $@ $<
$(BUILD)/overlays/%.bin: $(BUILD)/overlays/%.o cfg/overlay.cfg
	$(LD) -C cfg/overlay.cfg -o $@ $<

# --- ROM-expansion PoC banks (docs/ROM-EXPANSION.md, Option A) ---------------
# A bank is a self-contained 8KB ROM image served at $A000-$BFFF in place of the
# base set's BASIC half; cfg/bank.cfg links it there with a $A000 JMP-table ABI.
# (The generic $(BUILD)/%.o rule above assembles src/banks/*.s -> build/banks/*.o.)
$(BUILD)/banks/%.bin: $(BUILD)/banks/%.o cfg/bank.cfg
	$(LD) -C cfg/bank.cfg -o $@ $<
	@echo "  $(@F) : $$(wc -c < $@) bytes"
banks: $(BUILD)/banks/bank1.bin
# Generated overlay page-number map (start page of each overlay), derived from
# the actual .bin sizes. The resident overlay thunks include it; their .s
# therefore depend on it, and it depends on the overlay .bin -- so the page
# numbers are always consistent with what's in the overlay sets.
$(BUILD)/overlay_pages.h: $(OVERLAYS) tools/gen_overlay_pages.py
	@python3 tools/gen_overlay_pages.py $(BUILD) > $@
$(BUILD)/commands/overlay.s: $(BUILD)/overlay_pages.h
$(BUILD)/commands/fs.s: $(BUILD)/overlay_pages.h

# The overlay library is two independent 8KB flash sets (each a single 2364 in
# cfg/onerom-stock.json). Each holds whole overlays packed from page 0, so a
# fetch's SLOT_PEEK always stays within one 8KB chip. The A/B grouping here
# MUST match LAYOUT in tools/gen_overlay_pages.py.
#
# These depend on the Makefile itself: the *order/membership* of OVERLAYS_A/B
# lives only in this file, so a regrouping (e.g. moving an overlay between sets)
# leaves the member .bins untouched -- without this dep, make would see the
# stale set binary as newer than its prereqs and skip the rebuild, baking the
# old page layout into the firmware (resident macros then mismatch -> stage 5).
define pack_overlay_set
	cat $(1) > $@
	python3 -c "import sys; f=open('$@','r+b'); f.seek(0,2); n=f.tell(); \
	  assert n <= 8192, '$@ overflow (%d > 8192)' % n; f.write(b'\xff'*(8192-n))"
	@echo "  $(@F): $$(wc -c < $@) bytes"
endef

$(BUILD)/overlays_a.bin: $(OVERLAYS_A) Makefile
	$(call pack_overlay_set,$(OVERLAYS_A))

$(BUILD)/overlays_c.bin: $(OVERLAYS_C) Makefile
	$(call pack_overlay_set,$(OVERLAYS_C))

$(BUILD)/overlays_b.bin: $(OVERLAYS_B) Makefile
	$(call pack_overlay_set,$(OVERLAYS_B))


# C is compiled to assembly by cc65, then assembled by ca65 (keep the .s so a
# build leaves the generated assembly around for inspection).
.PRECIOUS: $(BUILD)/%.s
$(BUILD)/%.s: src/%.c | $(BUILD)
	@mkdir -p $(@D)
	$(CC) $(CC65FLAGS_RESIDENT) -o $@ $<

$(BUILD)/%.o: $(BUILD)/%.s | $(BUILD)
	@mkdir -p $(@D)
	$(AS) $(ASFLAGS) -o $@ $<

# One ld65 invocation writes both binaries (file= is set per memory area in
# the linker config). kernal.bin is the rule target; basic.bin rides along.
# The cc65 runtime library resolves the stack/zerobss/copydata helpers the
# compiled C pulls in.
# -Ln writes a VICE label file (build/labels.txt) for monitor debugging and so
# tests can locate exported symbols (e.g. keytab_shift) in the ROM.
$(KERNAL): $(OBJ) $(CFG) tools/patch_freemem.py | $(BUILD)
	$(LD) -C $(CFG) $(OBJ) $(RTLIB) -Ln $(BUILD)/labels.txt -m $(BUILD)/rom.map
	@python3 tools/patch_freemem.py $(BUILD)   # fill the boot-screen "rom free" line
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

# Full suite: `make test`. Fast iteration: `make test M=fastload` (or
# M="disk rm") runs only the modules whose name contains the substring(s).
# VICE_JOBS=N overrides the parallel worker count.
test: all $(OVERLAY_SETS)
	$(PYTHON) test/run_tests.py $(M)

# Build a One ROM firmware image holding both halves as a single multi-ROM set
# (kernal.bin + basic.bin, served via two_cs_one_addr -- two active-low chip
# selects on a shared address bus, matching the C64's KERNAL and BASIC /CS).
# Output: build/onerom-<board>.bin. Flash with `make onerom-flash`.
onerom: $(BASIC) $(KERNAL)
	$(ONEROM) firmware build --board $(ONEROM_BOARD) --version $(ONEROM_FW_VERSION) \
		--config-file $(ONEROM_CFG) $(ONEROM_PLUGINS_USB) \
		--out $(BUILD)/onerom-$(ONEROM_BOARD).bin
	@echo "  onerom fw : $$(wc -c < $(BUILD)/onerom-$(ONEROM_BOARD).bin) bytes ($(ONEROM_BOARD))"

# Build a One ROM firmware that pairs our shell with stock C64 BASIC+KERNAL
# as a second bank, plus the user/host-control plugin so the shell can drive a
# runtime bank-switch via the RBCP protocol (see src/rbcp/). All stock ROMs --
# the C64 BASIC/KERNAL and both character ROMs (US charset 901225-01 for font A,
# Swedish/German charset 325018-02 for font B) -- are fetched from Zimmers by
# URL (see the `file` entries in cfg/onerom-stock.json), so no local ROM copies
# are needed; the onerom CLI downloads and caches them. Only our own build
# outputs remain local prerequisites.
# The C= boot menu (loadable ROM set 0) is r107sl's c64-bootloader, built from
# vendored source (third-party/c64-bootloader/) into build/c64_bootloader.bin --
# NOT the pre-built binary Piers hosts, whose v0.1.0 predates firmware 0.7.x and
# fails GET_FLASH_SLOT_INFO_ALL (see the third-party README).
BOOTLOADER   := $(BUILD)/c64_bootloader.bin
BOOTLOADER_SRC := $(wildcard third-party/c64-bootloader/*.s third-party/c64-bootloader/*.c \
	third-party/c64-bootloader/*.inc third-party/c64-bootloader/*.h third-party/c64-bootloader/rom.cfg)
$(BOOTLOADER): $(BOOTLOADER_SRC) tools/build_bootloader.sh | $(BUILD)
	tools/build_bootloader.sh $@

# JiffyDOS is commercial, so unlike the stock ROMs (Zimmers URLs) it stays a
# local user-supplied file; the C= boot menu (cfg/onerom-stock.json set 3)
# offers it as a bootable KERNAL.
ONEROM_STOCK_DEPS   := $(BASIC) $(KERNAL) $(OVERLAY_SETS) $(BOOTLOADER) stock-roms/JiffyDOS_C64.bin
onerom-stock: $(ONEROM_STOCK_DEPS)
	$(ONEROM) firmware build --board $(ONEROM_BOARD) --version $(ONEROM_FW_VERSION) \
		--config-file cfg/onerom-stock.json $(ONEROM_PLUGINS) \
		--out $(ONEROM_STOCK_OUT)
	@echo "  onerom fw : $$(wc -c < $(ONEROM_STOCK_OUT)) bytes -> $(ONEROM_STOCK_OUT)"

# Build the firmware AND flash a connected One ROM, then reboot it into the
# running (byte-serving) state. Plug the device in (USB), then `make onerom-
# flash`. Uses cfg/onerom-stock.json so the device gets host-control + the
# stock-ROM second bank -- host-control is also what the reboot-into-running
# step needs (the plain single-bank cfg/onerom.json firmware can't be rebooted,
# which is why the old onerom-flash stopped working). ONEROM_BOARD must match
# the connected device; pass ONEROM_SERIAL='5*' (wildcard) to pick one of many.
onerom-flash: $(ONEROM_STOCK_DEPS)
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--board $(ONEROM_BOARD) --version $(ONEROM_FW_VERSION) \
		--config-file cfg/onerom-stock.json $(ONEROM_PLUGINS) \
		--out $(ONEROM_STOCK_OUT)
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') reboot

# Baseline / bisect target: flash *only* stock C64 BASIC+KERNAL (plus the
# system/usb plugin so we can still manage the device). None of our shell,
# no host-control plugin. Used to answer "is the OneROM hardware+wiring
# fine?" -- if this boots cleanly to the stock C64 READY prompt but our
# shell flashes show artifacts, the issue is in our ROM image; if even
# this shows artifacts, the issue is OneROM-side.
onerom-pure-stock-flash:
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--board $(ONEROM_BOARD) --version $(ONEROM_FW_VERSION) \
		--config-file cfg/onerom-pure-stock.json $(ONEROM_PLUGINS_USB) \
		--out $(BUILD)/onerom-pure-stock-$(ONEROM_BOARD).bin
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') reboot

# Commodore 128 firmware: Tardis DOS as the C64-mode ROM in socket U32, so GO64
# gives the shell while C128 mode stays stock. Built by tools/build_c128.sh
# (compiles the shell with -D TARGET_C128 and packs the 16KB U32 image + the
# overlay flash sets for the One ROM). See the "C128 / C64-mode port" section in
# CLAUDE.md. Shares the build/ tree with the C64 build, so the script cleans
# first -- and you must `make clean` before a subsequent plain C64 build.
C128_BOARD ?= fire-28-c
onerom-c128:
	ONEROM_BOARD=$(C128_BOARD) tools/build_c128.sh

# Flash it. NO `onerom reboot` here on purpose: on the C128 the One ROM needs a
# true power-off cold boot to serve cleanly (a reboot-into-running left it dark),
# so the flash just programs and tells you to power-cycle by hand.
onerom-c128-flash: onerom-c128
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--firmware $(BUILD)/tardis-c128-$(C128_BOARD).bin
	@echo ""
	@echo "Flashed. COLD-BOOT the One ROM: power the C128 fully off AND briefly"
	@echo "unplug the One ROM's USB, then reconnect and power on. Then type GO64."

# ----------------------------------------------------------------------------
# Commodore 64C firmware: Tardis DOS for a C64C's SINGLE combined KERNAL+BASIC
# ROM (251913), served by a 28-pin One ROM (default fire-28-a). A 28-pin board
# has no X1 pin, so it can't serve the breadbin's separate 24-pin KERNAL+BASIC
# 2364s (a multi-CS set) -- but the C64C's one combined 16KB chip serves as a
# single ROM, which it can. Built by tools/build_c64c.sh (reuses the combined-
# ROM TARGET_C128 mode; skips the char ROM, so `font` fails). See the "C64C
# port" section in CLAUDE.md. Shares build/ with the C64 build, so the script
# cleans first -- and you must `make clean` before a subsequent plain C64 build.
C64C_BOARD ?= fire-28-a
C64C_VERSION := $(shell grep -o 'v0\.1\.[0-9]*' src/commands/builtins.c | head -1)
onerom-c64c:
	ONEROM_BOARD=$(C64C_BOARD) tools/build_c64c.sh

# Flash it. Like the C128, a 28-pin One ROM serving a combined image wants a
# true power-off cold boot to serve cleanly, so this programs WITHOUT a reboot
# and tells you to power-cycle by hand.
onerom-c64c-flash: onerom-c64c
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--firmware $(BUILD)/c64c-tardis-dos-$(C64C_VERSION)-for-onerom-$(C64C_BOARD).bin
	@echo ""
	@echo "Flashed. COLD-BOOT the One ROM: power the C64C fully off AND briefly"
	@echo "unplug the One ROM's USB, then reconnect and power on."

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
	$(ONEROM) firmware build --board $(ONEROM_BOARD) --version $(ONEROM_FW_VERSION) \
		--config-file cfg/onerom-memtest.json $(ONEROM_PLUGINS_USB) \
		--out $(BUILD)/onerom-memtest-$(ONEROM_BOARD).bin
	@echo "  onerom-memtest fw : $$(wc -c < $(BUILD)/onerom-memtest-$(ONEROM_BOARD).bin) bytes ($(ONEROM_BOARD))"

memtest-flash: $(MEMTEST_KERNAL) $(MEMTEST_BASIC)
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') program \
		--board $(ONEROM_BOARD) --version $(ONEROM_FW_VERSION) \
		--config-file cfg/onerom-memtest.json $(ONEROM_PLUGINS_USB) \
		--out $(BUILD)/onerom-memtest-$(ONEROM_BOARD).bin
	$(ONEROM) $(if $(ONEROM_SERIAL),--serial '$(ONEROM_SERIAL)') reboot

# Same suite, but show the launch command, monitor traffic, and tracebacks.
test-verbose: all
	VICE_VERBOSE=1 $(PYTHON) test/run_tests.py

clean:
	rm -rf $(BUILD)
