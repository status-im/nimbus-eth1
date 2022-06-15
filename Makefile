# Copyright (c) 2018-2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

LINK_PCRE := 0

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

# debugging tools + testing tools
TOOLS := \
	test_tools_build
TOOLS_DIRS := \
	tests
# comma-separated values for the "clean" target
TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(TOOLS))

.PHONY: \
	all \
	$(TOOLS) \
	deps \
	update \
	nimbus \
	fluffy \
	test \
	test-reproducibility \
	clean \
	libnimbus.so \
	libnimbus.a \
	libbacktrace \
	dist-amd64 \
	dist-arm64 \
	dist-arm \
	dist-win64 \
	dist-macos \
	dist-macos-arm64 \
	dist

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# default target, because it's the first one that doesn't start with '.'
all: | $(TOOLS) nimbus

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

# default: use blst
USE_MIRACL := 0

# default: use nim native evm
ENABLE_EVMC := 0

# "-d:release" cannot be added to config.nims
NIM_PARAMS += -d:release

ifeq ($(USE_LIBBACKTRACE), 0)
  NIM_PARAMS += -d:disable_libbacktrace
endif

deps: | deps-common nat-libs nimbus.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

ifneq ($(USE_MIRACL), 0)
  NIM_PARAMS += -d:BLS_FORCE_BACKEND=miracl
endif

ifneq ($(ENABLE_EVMC), 0)
  NIM_PARAMS += -d:evmc_enabled
endif

# disabled by default, enable with ENABLE_VM2LOWMEM=1
ifneq ($(if $(ENABLE_VM2LOWMEM),$(ENABLE_VM2LOWMEM),0),0)
  NIM_PARAMS += -d:vm2_enabled -d:lowmem:1
else
  # disabled by default, enable with ENABLE_VM2=1
  ifneq ($(if $(ENABLE_VM2),$(ENABLE_VM2),0),0)
    NIM_PARAMS += -d:vm2_enabled
  endif
endif

# chunked messages enabled by default, use ENABLE_CHUNKED_RLPX=0 to disable
ifneq ($(if $(ENABLE_CHUNKED_RLPX),$(ENABLE_CHUNKED_RLPX),1),0)
NIM_PARAMS := $(NIM_PARAMS) -d:chunked_rlpx_enabled
endif

# legacy wire protocol enabled by default, use ENABLE_LEGACY_ETH66=0 to disable
ifneq ($(if $(ENABLE_LEGACY_ETH66),$(ENABLE_LEGACY_ETH66),1),0)
NIM_PARAMS := $(NIM_PARAMS) -d:legacy_eth66_enabled
endif

#- deletes and recreates "nimbus.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf nimbus.nims && \
		$(MAKE) nimbus.nims $(HANDLE_OUTPUT)

# builds the tools, wherever they are
$(TOOLS): | build deps
	for D in $(TOOLS_DIRS); do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -o:build/$@ "$${TOOL_DIR}/$@.nim"

# a phony target, because teaching `make` how to do conditional recompilation of Nim projects is too complicated
nimbus: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/$@ "nimbus/$@.nim"

# symlink
nimbus.nims:
	ln -s nimbus.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

# builds and runs the nimbus test suite
test: | build deps
	$(ENV_SCRIPT) nim test_rocksdb $(NIM_PARAMS) nimbus.nims
	$(ENV_SCRIPT) nim test $(NIM_PARAMS) nimbus.nims

# Primitive reproducibility test.
#
# On some platforms, with some GCC versions, it may not be possible to get a
# deterministic order for debugging info sections - even with
# "-frandom-seed=...". Striping the binaries should make them identical, though.
test-reproducibility:
	+ [ -e build/nimbus ] || $(MAKE) V=0 nimbus; \
		MD5SUM1=$$($(MD5SUM) build/nimbus | cut -d ' ' -f 1) && \
		rm -rf nimcache/*/nimbus && \
		$(MAKE) V=0 nimbus && \
		MD5SUM2=$$($(MD5SUM) build/nimbus | cut -d ' ' -f 1) && \
		[ "$$MD5SUM1" = "$$MD5SUM2" ] && echo -e "\e[92mSuccess: identical binaries.\e[39m" || \
			{ echo -e "\e[91mFailure: the binary changed between builds.\e[39m"; exit 1; }

# Fluffy related targets
# builds the fluffy client
fluffy: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim fluffy $(NIM_PARAMS) nimbus.nims

# primitive reproducibility test
fluffy-test-reproducibility:
	+ [ -e build/fluffy ] || $(MAKE) V=0 fluffy; \
		MD5SUM1=$$($(MD5SUM) build/fluffy | cut -d ' ' -f 1) && \
		rm -rf nimcache/*/fluffy && \
		$(MAKE) V=0 fluffy && \
		MD5SUM2=$$($(MD5SUM) build/fluffy | cut -d ' ' -f 1) && \
		[ "$$MD5SUM1" = "$$MD5SUM2" ] && echo -e "\e[92mSuccess: identical binaries.\e[39m" || \
			{ echo -e "\e[91mFailure: the binary changed between builds.\e[39m"; exit 1; }

# builds and runs the fluffy test suite
fluffy-test: | build deps
	$(ENV_SCRIPT) nim testfluffy $(NIM_PARAMS) nimbus.nims

# builds the fluffy tools
fluffy-tools: | build deps
	$(ENV_SCRIPT) nim fluffy_tools $(NIM_PARAMS) nimbus.nims

# builds the fluffy tools
utp-test-app: | build deps
	$(ENV_SCRIPT) nim utp_test_app $(NIM_PARAMS) nimbus.nims

# builds and runs the utp integration test suite
utp-test: | build deps
	$(ENV_SCRIPT) nim utp_test $(NIM_PARAMS) nimbus.nims

# Build fluffy test_portal_testnet
fluffy-test-portal-testnet: | build deps
	$(ENV_SCRIPT) nim test_portal_testnet $(NIM_PARAMS) nimbus.nims

# usual cleaning
clean: | clean-common
	rm -rf build/{nimbus,fluffy,$(TOOLS_CSV),all_tests,db/test_kvstore_rocksdb,test_rpc,all_fluffy_tests,portalcli,*.dSYM}
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

# Note about building Nimbus as a library:
#
# There were `wrappers`, `wrappers-static`, `libnimbus.so` and `libnimbus.a`
# target scripts here, and C and Go examples for calling the Nimbus library in
# directory `wrappers/`.  They have been removed because they only wrapped
# Whisper protocol support, which has been removed as it is obsolete.
#
# This note is kept so that anyone wanting to build Nimbus as a library or call
# from C or Go will know it has been done before.  The previous working version
# can be found in Git history.  Look for the `nimbus-eth1` commit that adds
# this comment and removes `wrappers/*`.

dist-amd64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh amd64

dist-arm64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh arm64

# We get an ICE on RocksDB-7.0.2 with "arm-linux-gnueabihf-g++ (Ubuntu 9.4.0-1ubuntu1~20.04.1) 9.4.0"
# and with "arm-linux-gnueabihf-g++ (Ubuntu 10.3.0-1ubuntu1) 10.3.0".
#dist-arm:
	#+ MAKE="$(MAKE)" \
		#scripts/make_dist.sh arm

dist-win64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh win64

dist-macos:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh macos

dist-macos-arm64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh macos-arm64

dist:
	+ $(MAKE) --no-print-directory dist-amd64
	+ $(MAKE) --no-print-directory dist-arm64
	#+ $(MAKE) --no-print-directory dist-arm
	+ $(MAKE) --no-print-directory dist-win64
	+ $(MAKE) --no-print-directory dist-macos
	+ $(MAKE) --no-print-directory dist-macos-arm64

endif # "variables.mk" was not included
