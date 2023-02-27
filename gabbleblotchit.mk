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
DEBUG_FLAGS += --passL:-fsanitize=address

BOEHM_FLAGS = $(DEBUG_FLAGS) --mm:boehm -d:boehm_enabled

NOBOEHM_FLAGS = $(DEBUG_FLAGS) -d:default_enabled

NIM_ENV = ./env.sh
RUN_ENV = ASAN_OPTIONS=detect_leaks=0

# ----------------
.PHONY: default help

default: help


.SILENT: help
help::
	echo
	echo "Usage: $(MAKE) -f $(MAKEFILE) <target> <option>"
	echo
	echo "<target>: help      -- this help page"
	echo
	echo "          release   -- build release version"
	echo "          boehm     -- build test version with safe gc"
	echo "          noboehm   -- build test version with unsafe default gc"
	echo "          run       -- run previously built version"
	echo
	echo "          brun      -- same as double targets boehm and run"
	echo "          nobrun    -- same as double targets noboehm and run"
	echo

# ----------------
.PHONY: release boehm brun noboehm nobrun run

release:
	@echo "*** Compiling without debugging support"
	./env.sh nim c $(OTHER_FLAGS) $(BUILD_ARGS)

boehm brun::
	@echo "*** Compiling for safe boehm gc"
	$(NIM_ENV) nim c $(OTHER_FLAGS) $(BOEHM_FLAGS) $(BUILD_ARGS)

noboehm nobrun::
	@echo "*** Compiling for probably crashing gc"
	$(NIM_ENV) nim c $(OTHER_FLAGS) $(NOBOEHM_FLAGS) $(BUILD_ARGS)

brun nobrun run::
	@test -x ./build/$(TARGET) || {\
	  echo "*** Please compile first (for details see \"help\" target)";\
	  false; }

brun nobrun run::
	$(RUN_ENV) ./build/$(TARGET) --sync-mode=full --discovery=none

# ----------------
.PHONY: clean distclean clobber

clean distclean clobber:
	rm -f ./build/$(TARGET)

# End
