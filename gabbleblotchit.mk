#! /usr/bin/make -f
# -*- makefile -*-
#
# Gabbleblotchits -- from Vogon poetry (in case you care)
#

TARGET = gabbleblotchit
MAKEFILE = $(TARGET).mk

BUILD_ARGS = --verbosity:0 --hints:off -d:chronicles_log_level=TRACE
BUILD_ARGS += -o:build/$(TARGET) nimbus/$(TARGET).nim

RELEASE_FLAGS = -d:release

DEBUG_FLAGS = --debugger:native --debuginfo:on
DEBUG_FLAGS += --opt:none # -d:useGcAssert -d:memProfiler
DEBUG_FLAGS += --passC:-fsanitize=address --passC:-fno-omit-frame-pointer
#DEBUG_FLAGS += --passC:-fsanitize-recover=all
DEBUG_FLAGS += --passL:-fsanitize=address

OTHER_FLAGS =
ifeq ($(SWAP_SYNC_REFS),1)
OTHER_FLAGS += -d:swap_sync_refs
endif

BOEHM_FLAGS = $(DEBUG_FLAGS) --mm:boehm -d:boehm_enabled
BOEHM_ENV = ./env.sh
BOEHM_RUN = ASAN_OPTIONS=detect_leaks=0

NOBOEHM_FLAGS = $(DEBUG_FLAGS) -d:default_enabled
NOBOEHM_ENV = ./env.sh
NOBOEHM_RUN = ASAN_OPTIONS=verbose=1

NIMBASE_H = vendor/nimbus-build-system/vendor/Nim/lib/nimbase.h

# ----------------
.PHONY: default help

default: help

.SILENT: help
help::
	echo
	echo "Usage: $(MAKE) -f $(MAKEFILE) <target> <option>"
	echo
	echo "<target>: help             -- this help page"
	echo
	echo "          release          -- build release version"
	echo "          boehm            -- build test version with safe gc"
	echo "          noboehm          -- test version with unsafe default gc"
	echo
	echo "          brun             -- compile & run with boehm gc"
	echo "          nobrun           -- compile & run with std gc"
	echo "          check-nimbase    -- verify gcc/asan annotation"
	echo
	echo "<option>: SWAP_SYNC_REFS=1 -- swap descriptors in NimbusNode object"
	echo

# ----------------
.PHONY: release boehm brun noboehm nobrun run check-nimbase

check-nimbase noboehm nobrun::
	@gcc -dM -E $(NIMBASE_H) |\
	  grep CLANG_NO_SANITIZE_ADDRESS |\
	  grep no_sanitize_address >/dev/null || {\
	   echo "*** Check C header file $(NIMBASE_H).";\
	   echo "    The maco CLANG_NO_SANITIZE_ADDRESS might be empty. It should read";\
	   echo "    \"__attribute__((no_sanitize_address))\". For gcc, the file migh need";\
	   echo "    to be edited checking whether __GNUC__ is defined.";\
	   false;\
	}

release:
	@echo "*** Compiling without debugging support"
	./env.sh nim c $(OTHER_FLAGS) $(BUILD_ARGS)

boehm brun::
	@echo "*** Compiling for safe boehm gc"
	$(BOEHM_ENV) nim c $(OTHER_FLAGS) $(BOEHM_FLAGS) $(BUILD_ARGS)

brun::
	$(BOEHM_RUN) ./build/$(TARGET)

noboehm nobrun::
	@echo "*** Compiling for probably crashing gc"
	$(NOBOEHM_ENV) nim c $(OTHER_FLAGS) $(NOBOEHM_FLAGS) $(BUILD_ARGS)

nobrun::
	$(NOBOEHM_RUN) ./build/$(TARGET)

# ----------------
.PHONY: clean distclean clobber

clean distclean clobber:
	rm -f ./build/$(TARGET)

# End
