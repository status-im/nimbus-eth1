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
DEBUG_FLAGS += --opt:none -d:useGcAssert -d:memProfiler

BOEHM_FLAGS = $(DEBUG_FLAGS) --mm:boehm
NOBOEHM_FLAGS = $(DEBUG_FLAGS)

# ----------------
.PHONY: default help

default: help


.SILENT: help
help::
	echo
	echo "Usage: $(MAKE) -f $(MAKEFILE) <target>"
	echo
	echo "<target>: help     -- this help page"
	echo
	echo "          release  -- build release version"
	echo "          boehm    -- build test version with safe gc"
	echo "          noboehm  -- build test version with unsafe default gc"
	echo "          run      -- run previously built version"
	echo
	echo "          brun     -- same as double targets boehm and run"
	echo "          nobrun   -- same as double targets noboehm and run"
	echo

# ----------------
.PHONY: release boehm brun noboehm nobrun run

release:
	@echo "*** Compiling without debugging support"
	./env.sh nim c $(BUILD_ARGS)

boehm brun::
	@echo "*** Compiling for safe boehm gc"
	./env.sh nim c $(BOEHM_FLAGS) $(BUILD_ARGS)

noboehm nobrun::
	@echo "*** Compiling for probably crashing gc"
	./env.sh nim c $(NOBOEHM_FLAGS) $(BUILD_ARGS)

brun nobrun run::
	@test -x ./build/$(TARGET) || {\
	  echo "*** Please compile first (for details see \"help\" target)";\
	  false; }

brun nobrun run::
	./build/$(TARGET) --sync-mode=full --discovery=none

# ----------------
.PHONY: clean distclean clobber

clean distclean clobber:
	rm -f ./build/$(TARGET)

# End
