# Copyright (c) 2026 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# ZisK: https://github.com/0xPolygonHermez/zisk
#
# Supplies the ISA and the static library. The linker script is ours, since zisk
# ships none that conforms to the standard.

ZISK_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

# The ISA the riscv-target standard specifies. Must match what
# libziskos_staticlib.a was built with.
ZKVM_ARCH ?= -march=rv64im -mabi=lp64 -mcmodel=medany
ZKVM_CPU := riscv64

# To be built from a zisk checkout
ZISK_LIB ?= build/libziskos_staticlib.a

ZKVM_LIB := $(ZISK_LIB)
ZKVM_LD := $(ZISK_DIR)link.ld
ZKVM_CHECKS := check_zisk_staticlib

# newlib is the C library, so the glue only has to supply the syscalls beneath it.
ZKVM_GLUE := $(ZISK_DIR)newlib_glue.c

.PHONY: check_zisk_staticlib

check_zisk_staticlib:
	@[ -f "$(ZISK_LIB)" ] || { echo "ERROR: ZisK static library not found at $(ZISK_LIB)"; \
		echo "  build it from a zisk checkout with:"; \
		echo "    cargo +nightly build -p ziskos-staticlib --release \\"; \
		echo "      --target riscv64im-unknown-none-elf -Z build-std=core,alloc \\"; \
		echo "      --config 'profile.release.lto=\"fat\"' --features panic-handler"; \
		echo "  then copy it to $(ZISK_LIB), or pass ZISK_LIB=<path>"; exit 1; }
