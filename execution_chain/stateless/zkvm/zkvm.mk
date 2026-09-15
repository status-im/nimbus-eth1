# Copyright (c) 2026 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Builds the guest into a zkVM ELF, e.g.:
#
#   make ZKVM=zisk stateless_guest_zkvm
#
# Adding a zkVM means adding zkvm/<name>/<name>.mk setting the variables below.
# Nothing in this file changes.
#
#   ZKVM_ARCH     -march/-mabi/-mcmodel for the ISA the vendor mandates
#   ZKVM_CPU      Nim --cpu, since not every zkVM is 64-bit
#   ZKVM_LIB      the vendor's static library
#   ZKVM_LD       linker script
#   ZKVM_GLUE     C sources for the platform layer
#   ZKVM_CHECKS   targets that must pass before building, optional

ZKVM ?= zisk

ZKVM_DIR := $(dir $(lastword $(MAKEFILE_LIST)))

.PHONY: stateless_guest_zkvm check_zkvm_gcc

include $(ZKVM_DIR)$(ZKVM)/$(ZKVM).mk

# One-off guest debugging, e.g. ZKVM_EXTRA_PASSC=-DZKVM_SBRK_DEBUG,
# ZKVM_EXTRA_NIM=-d:disableLTO, ZKVM_EXTRA_PASSL=-Wl,--wrap=memcpy
ZKVM_EXTRA_PASSC ?=
ZKVM_EXTRA_NIM ?=
ZKVM_EXTRA_PASSL ?=

# A GNU cross toolchain with newlib, so the guest gets a C library.
ZKVM_GCC ?= riscv-none-elf-gcc

# -nostdlib drops the default search paths, so ask the compiler where its
# sysroot and libgcc live. Multilib selection keys off -march/-mabi, hence the
# arch flags.
#
# Recursively expanded (= not :=) so they only run when a zkVM target is built.
ZKVM_SYSROOT_LIBDIR = $(shell $(ZKVM_GCC) $(ZKVM_ARCH) -print-sysroot)/lib/$(shell $(ZKVM_GCC) $(ZKVM_ARCH) -print-multi-directory)
ZKVM_LIBGCC_DIR = $(dir $(shell $(ZKVM_GCC) $(ZKVM_ARCH) -print-libgcc-file-name))

ZKVM_NIM_CC := --cc:gcc --gcc.exe:"$(ZKVM_GCC)" --gcc.linkerexe:"$(ZKVM_GCC)"

#   -D_POSIX_THREADS  newlib's <pthread.h> only declares the pthread_mutex_*
#                     functions when this is set. The glue defines them.
#   -nostartfiles     drop crt0, whose _start would otherwise win over the
#                     vendor archive's. Keeps the C library.
#   -g0               nothing debugs the guest through DWARF, and it is most of
#                     the file: 52M with it, 6.9M without.
ZKVM_PASSC := -D_POSIX_THREADS=1 $(ZKVM_ARCH) -ffunction-sections -fdata-sections -g0
ZKVM_PASSL = $(ZKVM_ARCH) -nostdlib -nostartfiles -Wl,--build-id=none -Wl,--gc-sections -T $(ZKVM_LD) -L$(ZKVM_SYSROOT_LIBDIR) -L$(ZKVM_LIBGCC_DIR) $(ZKVM_LIB) -Wl,--start-group -lc -lgcc -lnosys -Wl,--end-group

check_zkvm_gcc:
	@printf 'int main(void){return 0;}' | $(ZKVM_GCC) $(ZKVM_ARCH) -c -x c - -o /dev/null 2>/dev/null || { \
		echo "ERROR: '$(ZKVM_GCC)' is missing or cannot emit $(ZKVM_ARCH)."; \
		echo "  Point ZKVM_GCC at an xPack riscv-none-elf-gcc, or put it on PATH."; exit 1; }

ZKVM_ELF := build/stateless_guest_$(ZKVM).elf

stateless_guest_zkvm: | build deps check_zkvm_gcc $(ZKVM_CHECKS)
	$(ENV_SCRIPT) $(NIMC) c $(STATELESS_GUEST_FLAGS) $(ZKVM_EXTRA_NIM) -d:release -d:zkvmTarget --debugger:off \
		--cpu:$(ZKVM_CPU) --os:any -d:enable_zkvm_accelerators \
		$(ZKVM_NIM_CC) \
		--passC:"$(ZKVM_PASSC) $(ZKVM_EXTRA_PASSC)" \
		--passL:"$(ZKVM_PASSL) $(ZKVM_EXTRA_PASSL)" \
		$(foreach g,$(ZKVM_GLUE),--compile:"$(g)") \
		-o:$(ZKVM_ELF) "execution_chain/stateless/stateless_guest.nim"
	@echo "built $(ZKVM_ELF)"
