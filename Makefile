# Copyright (c) 2018-2019 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# we don't want an error here, so we can handle things later, in the build-system-checks target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

# debugging tools + testing tools
TOOLS := premix persist debug dumper hunter regress tracerTestGen persistBlockTestGen
TOOLS_DIRS := premix tests
# comma-separated values for the "clean" target
TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(TOOLS))

.PHONY: all $(TOOLS) build-system-checks deps update nimbus test test-reproducibility clean libnimbus.so libnimbus.a wrappers wrappers-static

# default target, because it's the first one that doesn't start with '.'
all: build-system-checks $(TOOLS) nimbus

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
build-system-checks:
	@[[ -e "$(BUILD_SYSTEM_DIR)/makefiles" ]] || { \
		echo -e "'$(BUILD_SYSTEM_DIR)/makefiles' not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo -e "\nYou can now run '$(MAKE)' again."; \
		exit 1; \
		}

deps: | deps-common nimbus.nims

#- deletes and recreates "nimbus.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf nimbus.nims && \
		$(MAKE) nimbus.nims

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

libnimbus.so: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c --app:lib --noMain --nimcache:nimcache/libnimbus $(NIM_PARAMS) -o:build/$@.0 wrappers/libnimbus.nim && \
		rm -f build/$@ && \
		ln -s $@.0 build/$@

wrappers: | build deps libnimbus.so go-checks
	echo -e $(BUILD_MSG) "build/C_wrapper_example" && \
		$(CC) wrappers/wrapper_example.c -Wl,-rpath,'$$ORIGIN' -Lbuild -lnimbus -lm -g -o build/C_wrapper_example
	echo -e $(BUILD_MSG) "build/go_wrapper_example" && \
		go build -o build/go_wrapper_example wrappers/wrapper_example.go wrappers/cfuncs.go
	echo -e $(BUILD_MSG) "build/go_wrapper_whisper_example" && \
		go build -o build/go_wrapper_whisper_example wrappers/wrapper_whisper_example.go wrappers/cfuncs.go

libnimbus.a: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		rm -f build/$@ && \
		$(ENV_SCRIPT) nim c --app:staticlib --noMain --nimcache:nimcache/libnimbus_static $(NIM_PARAMS) -o:build/$@ wrappers/libnimbus.nim && \
		[[ -e "$@" ]] && mv "$@" build/ # workaround for https://github.com/nim-lang/Nim/issues/12745

wrappers-static: | build deps libnimbus.a go-checks
	echo -e $(BUILD_MSG) "build/C_wrapper_example_static" && \
		$(CC) wrappers/wrapper_example.c -static -pthread -Lbuild -lnimbus -lm -ldl -lpcre -g -o build/C_wrapper_example_static
	echo -e $(BUILD_MSG) "build/go_wrapper_example_static" && \
		go build -ldflags "-linkmode external -extldflags '-static -ldl -lpcre'" -o build/go_wrapper_example_static wrappers/wrapper_example.go wrappers/cfuncs.go
	echo -e $(BUILD_MSG) "build/go_wrapper_whisper_example_static" && \
		go build -ldflags "-linkmode external -extldflags '-static -ldl -lpcre'" -o build/go_wrapper_whisper_example_static wrappers/wrapper_example.go wrappers/cfuncs.go

wakunode: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim wakunode $(NIM_PARAMS) nimbus.nims
