# Copyright (c) 2018-2020 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by Make

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

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
	test \
	test-reproducibility \
	clean \
	libnimbus.so \
	libnimbus.a \
	wrappers \
	wrappers-static \
	libbacktrace

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

# "-d:release" implies "--stacktrace:off" and it cannot be added to config.nims
ifeq ($(USE_LIBBACKTRACE), 0)
NIM_PARAMS := $(NIM_PARAMS) -d:debug -d:disable_libbacktrace
else
NIM_PARAMS := $(NIM_PARAMS) -d:release
endif

deps: | deps-common nat-libs nimbus.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
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
		$(ENV_SCRIPT) nim nimbus $(NIM_PARAMS) nimbus.nims

# symlink
nimbus.nims:
	ln -s nimbus.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

# builds and runs the test suite
test: | build deps
	$(ENV_SCRIPT) nim test $(NIM_PARAMS) nimbus.nims

# primitive reproducibility test
test-reproducibility:
	+ [ -e build/nimbus ] || $(MAKE) V=0 nimbus; \
		MD5SUM1=$$($(MD5SUM) build/nimbus | cut -d ' ' -f 1) && \
		rm -rf nimcache/*/nimbus && \
		$(MAKE) V=0 nimbus && \
		MD5SUM2=$$($(MD5SUM) build/nimbus | cut -d ' ' -f 1) && \
		[ "$$MD5SUM1" = "$$MD5SUM2" ] && echo -e "\e[92mSuccess: identical binaries.\e[39m" || \
			{ echo -e "\e[91mFailure: the binary changed between builds.\e[39m"; exit 1; }

# usual cleaning
clean: | clean-common
	rm -rf build/{nimbus,$(TOOLS_CSV),all_tests,test_rpc,*_wrapper_test}
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

libnimbus.so: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c --app:lib --noMain --nimcache:nimcache/libnimbus $(NIM_PARAMS) -o:build/$@.0 wrappers/libnimbus.nim && \
		rm -f build/$@ && \
		ln -s $@.0 build/$@

# libraries for dynamic linking of non-Nim objects
EXTRA_LIBS_DYNAMIC := -L"$(CURDIR)/build" -lnimbus -lm
wrappers: | build deps libnimbus.so
	echo -e $(BUILD_MSG) "build/C_wrapper_example" && \
		$(CC) wrappers/wrapper_example.c -Wl,-rpath,'$$ORIGIN' $(EXTRA_LIBS_DYNAMIC) -g -o build/C_wrapper_example
	echo -e $(BUILD_MSG) "build/go_wrapper_example" && \
		go build -ldflags "-linkmode external -extldflags '$(EXTRA_LIBS_DYNAMIC)'" -o build/go_wrapper_example wrappers/wrapper_example.go wrappers/cfuncs.go
	echo -e $(BUILD_MSG) "build/go_wrapper_whisper_example" && \
		go build -ldflags "-linkmode external -extldflags '$(EXTRA_LIBS_DYNAMIC)'" -o build/go_wrapper_whisper_example wrappers/wrapper_whisper_example.go wrappers/cfuncs.go

libnimbus.a: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		rm -f build/$@ && \
		$(ENV_SCRIPT) nim c --app:staticlib --noMain --nimcache:nimcache/libnimbus_static $(NIM_PARAMS) -o:build/$@ wrappers/libnimbus.nim && \
		[[ -e "$@" ]] && mv "$@" build/ # workaround for https://github.com/nim-lang/Nim/issues/12745

# These libraries are for statically linking non-Nim objects to libnimbus.a
# (where "vendor/nim-libbacktrace/libbacktrace.nim" doesn't get to set its LDFLAGS)
EXTRA_LIBS_STATIC := -L"$(CURDIR)/build" -lnimbus -L"$(CURDIR)/vendor/nim-libbacktrace/install/usr/lib" -lbacktracenim -lbacktrace -lm -ldl -lpcre
ifeq ($(shell uname), Darwin)
USE_VENDORED_LIBUNWIND := 1
endif # macOS
ifeq ($(OS), Windows_NT)
USE_VENDORED_LIBUNWIND := 1
endif # Windows
ifeq ($(USE_VENDORED_LIBUNWIND), 1)
EXTRA_LIBS_STATIC := $(EXTRA_LIBS_STATIC) -lunwind
endif # USE_VENDORED_LIBUNWIND
wrappers-static: | build deps libnimbus.a
	echo -e $(BUILD_MSG) "build/C_wrapper_example_static" && \
		$(CC) wrappers/wrapper_example.c -static -pthread $(EXTRA_LIBS_STATIC) -g -o build/C_wrapper_example_static
	echo -e $(BUILD_MSG) "build/go_wrapper_example_static" && \
		go build -ldflags "-linkmode external -extldflags '-static $(EXTRA_LIBS_STATIC)'" -o build/go_wrapper_example_static wrappers/wrapper_example.go wrappers/cfuncs.go
	echo -e $(BUILD_MSG) "build/go_wrapper_whisper_example_static" && \
		go build -ldflags "-linkmode external -extldflags '-static $(EXTRA_LIBS_STATIC)'" -o build/go_wrapper_whisper_example_static wrappers/wrapper_whisper_example.go wrappers/cfuncs.go

endif # "variables.mk" was not included

