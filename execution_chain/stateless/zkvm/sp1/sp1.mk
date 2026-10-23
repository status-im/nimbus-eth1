# Copyright (c) 2026 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# SP1: https://github.com/succinctlabs/sp1
#
# Supplies the ISA, the static library and the linker script, all prebuilt, so
# the only thing left here is the platform layer newlib needs underneath. The
# library implements the zkevm-standards io and accelerator interfaces.

SP1_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

# The ISA the riscv-target standard specifies.
ZKVM_ARCH ?= -march=rv64im -mabi=lp64 -mcmodel=medany
ZKVM_CPU := riscv64

# Released as zkevm-sdk-v<version>.tar.gz on
# https://github.com/succinctlabs/sp1/releases
SP1_SDK ?= build/sp1-sdk

ZKVM_LIB := $(SP1_SDK)/libzkevm.a
ZKVM_LD := $(SP1_SDK)/zkvm.ld
ZKVM_CHECKS := check_sp1_sdk

# SP1's loader rejects a segment that is both writable and executable, and
# disassembles the executable one whole, so .rodata may not share it.
#
# zkvm.ld aligns sections to 16 bytes, expecting ld.lld, which pads and splits
# by itself. GNU ld only starts a segment on a page boundary, so it puts all
# four sections in one RWX segment. max-page-size lets it split at 16 bytes and
# separate-code then keeps .rodata out of the code segment.
ZKVM_LD_FLAGS := -Wl,-z,max-page-size=16 -Wl,-z,separate-code

# libzkevm.a covers _start, the allocator, exit and memcpy, so the glue is only
# what newlib needs under it.
ZKVM_GLUE := $(SP1_DIR)newlib_glue.c

.PHONY: check_sp1_sdk

check_sp1_sdk:
	@[ -f "$(ZKVM_LIB)" ] && [ -f "$(ZKVM_LD)" ] || { \
		echo "ERROR: SP1 zkEVM SDK not found under $(SP1_SDK)"; \
		echo "  fetch it with:"; \
		echo "    V=v6.6.0; mkdir -p $(SP1_SDK) && curl -sSL \\"; \
		echo "      https://github.com/succinctlabs/sp1/releases/download/\$$V/zkevm-sdk-\$$V.tar.gz \\"; \
		echo "      | tar -xz -C $(SP1_SDK) --strip-components=1"; \
		echo "  or pass SP1_SDK=<path>"; exit 1; }
