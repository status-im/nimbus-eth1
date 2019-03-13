# Copyright (c) 2018-2019 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by "make"
GIT_CLONE := git clone --quiet --recurse-submodules
GIT_PULL := git pull --recurse-submodules
GIT_STATUS := git status
#- the Nimble dir can't be "[...]/vendor", or Nimble will start looking for
#  version numbers in repo dirs (because those would be in its subdirectories)
#- duplicated in "env.sh" for the env var with the same name
NIMBLE_DIR := vendor/.nimble
REPOS_DIR := vendor
ifeq ($(OS), Windows_NT)
  PWD := pwd -W
else
  PWD := pwd
endif
# we want a "recursively expanded" (delayed interpolation) variable here, so we can set CMD in rule recipes
RUN_CMD_IN_ALL_REPOS = git submodule foreach --recursive --quiet 'echo -e "\n\e[32m$$name:\e[39m"; $(CMD)'; echo -e "\n\e[32m$$($(PWD)):\e[39m"; $(CMD)
# absolute path, since it will be run at various subdirectory depths
ENV_SCRIPT := "$(CURDIR)/env.sh"
# duplicated in "env.sh" to prepend NIM_DIR/bin to PATH
NIM_DIR := vendor/Nim
# extra parameters for the Nim compiler
NIM_PARAMS := $(EXTRA_NIM_PARAMS)
# verbosity level
V := 1
NIM_PARAMS := $(NIM_PARAMS) --verbosity:$(V)
HANDLE_OUTPUT :=
ifeq ($(V), 0)
  NIM_PARAMS := $(NIM_PARAMS) --hints:off --warnings:off
  HANDLE_OUTPUT := &>/dev/null
endif
# Chronicles log level
LOG_LEVEL :=
ifdef LOG_LEVEL
  NIM_PARAMS := $(NIM_PARAMS) -d:chronicles_log_level=$(LOG_LEVEL)
endif

#- forces a rebuild of csources, Nimble and a complete compiler rebuild, in case we're called after pulling a new Nim version
#- uses our Git submodules for csources and Nimble (Git doesn't let us place them in another submodule)
#- build_all.sh looks at the parent dir to decide whether to copy the resulting csources binary there,
#  but this is broken when using symlinks, so build csources separately (we get parallel compiling as a bonus)
#- Windows is a special case, as usual
#- macOS is also a special case, with its "ln" not supporting "-r"
ifeq ($(OS), Windows_NT)
  # the AppVeyor 32-build is done on a 64-bit image, so we need to override the architecture detection
  ifeq ($(ARCH_OVERRIDE), x86)
    UCPU := ucpu=i686
  else
    UCPU :=
  endif

  BUILD_CSOURCES := \
    $(MAKE) myos=windows $(UCPU) clean $(HANDLE_OUTPUT) && \
    $(MAKE) myos=windows $(UCPU) CC=gcc LD=gcc $(HANDLE_OUTPUT)
  EXE_SUFFIX := .exe
else
  BUILD_CSOURCES := \
    $(MAKE) clean $(HANDLE_OUTPUT) && \
    $(MAKE) LD=$(CC) $(HANDLE_OUTPUT)
  EXE_SUFFIX :=
endif
BUILD_NIM := cd $(NIM_DIR) && \
	rm -rf bin/nim_csources csources dist/nimble && \
	ln -s ../Nim-csources csources && \
	mkdir -p dist && \
	ln -s ../../nimble dist/nimble && \
	cd csources && \
	$(BUILD_CSOURCES) && \
	cd - >/dev/null && \
	[ -e csources/bin ] && { \
		cp -a csources/bin/nim bin/nim && \
		cp -a csources/bin/nim bin/nim_csources && \
		rm -rf csources/bin; \
	} || { \
		cp -a bin/nim bin/nim_csources; \
	} && \
	sh build_all.sh $(HANDLE_OUTPUT)
NIM_BINARY := $(NIM_DIR)/bin/nim$(EXE_SUFFIX)
# md5sum - macOS is a special case
ifeq ($(shell uname), Darwin)
  MD5SUM := md5 -r
else
  MD5SUM := md5sum
endif

# guess who does parsing before variable expansion
COMMA := ,
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
# debugging tools + testing tools
TOOLS := premix persist debug dumper hunter regress tracerTestGen persistBlockTestGen
# comma-separated values for the "clean" target
TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(TOOLS))

.PHONY: all $(TOOLS) deps github-ssh build-nim update status ntags ctags nimbus testsuite test clean mrproper fetch-dlls beacon_node validator_keygen clean_eth2_network_simulation_files eth2_network_simulation test-libp2p-daemon

# default target, because it's the first one that doesn't start with '.'
all: $(TOOLS) nimbus

# builds the tools, wherever they are
$(TOOLS): | build deps
	for D in premix tests; do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -o:build/$@ "$${TOOL_DIR}/$@.nim" && \
		echo -e "\nThe binary is in './build/$@'.\n"

# a phony target, because teaching `make` how to do conditional recompilation of Nim projects is too complicated
nimbus: | build deps
	$(ENV_SCRIPT) nim nimbus $(NIM_PARAMS) nimbus.nims && \
		echo -e "\nThe binary is in './build/nimbus'.\n"

# dir
build:
	mkdir $@

#- runs only the first time and after `make update`, so have "normal"
#  (timestamp-checked) prerequisites here
#- $(NIM_BINARY) is both a proxy for submodules having been initialised
#  and a check for the actual compiler build
deps: $(NIM_BINARY) $(NIMBLE_DIR) nimbus.nims

#- depends on Git submodules being initialised
#- fakes a Nimble package repository with the minimum info needed by the Nim compiler
#  for runtime path (i.e.: the second line in $(NIMBLE_DIR)/pkgs/*/*.nimble-link)
$(NIMBLE_DIR): | $(NIM_BINARY)
	mkdir -p $(NIMBLE_DIR)/pkgs
	git submodule foreach --quiet '\
		[ `ls -1 *.nimble 2>/dev/null | wc -l ` -gt 0 ] && { \
			mkdir -p $$toplevel/$(NIMBLE_DIR)/pkgs/$${sm_path#*/}-#head;\
			echo -e "$$($(PWD))\n$$($(PWD))" > $$toplevel/$(NIMBLE_DIR)/pkgs/$${sm_path#*/}-#head/$${sm_path#*/}.nimble-link;\
		} || true'

# symlink
nimbus.nims:
	ln -s nimbus.nimble $@

# builds and runs the testsuite
testsuite: | build deps
	$(ENV_SCRIPT) nim test $(NIM_PARAMS) nimbus.nims

#- builds the tools, to make sure they're still compilable
#- builds and runs all tests
test: | $(TOOLS) testsuite

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
clean:
	rm -rf build/{nimbus,$(TOOLS_CSV),all_tests,test_rpc,beacon_node,validator_keygen,*.exe} vendor/go/bin \
		$(NIMBLE_DIR) $(NIM_BINARY) $(NIM_DIR)/nimcache nimcache

# dangerous cleaning, because you may have not-yet-pushed branches and commits in those vendor repos you're about to delete
mrproper: clean
	rm -rf vendor

# for when you want to use SSH keys with GitHub
github-ssh:
	git config url."git@github.com:".insteadOf "https://github.com/"
	git submodule foreach --recursive 'git config url."git@github.com:".insteadOf "https://github.com/"'

#- re-builds the Nim compiler (not usually needed, because `make update` does it when necessary)
#- allows parallel building with the '+' prefix
build-nim: | deps
	+ $(BUILD_NIM)

#- initialises and updates the Git submodules
#- deletes the ".nimble" dir to force the execution of the "deps" target
#- allows parallel building with the '+' prefix
#- TODO: rebuild the Nim compiler after the corresponding submodule is updated
$(NIM_BINARY) update:
	git submodule update --init --recursive
	rm -rf $(NIMBLE_DIR)
	+ [ -e $(NIM_BINARY) ] || { $(BUILD_NIM); }

# don't use this target, or you risk updating dependency repos that are not ready to be used in Nimbus
update-remote:
	git submodule update --remote

# runs `git status` in all Git repos
status: | $(REPOS)
	$(eval CMD := $(GIT_STATUS))
	$(RUN_CMD_IN_ALL_REPOS)

#- actually binaries, but have them as phony targets to force rebuilds
beacon_node validator_keygen: | build deps
	$(ENV_SCRIPT) nim c $(NIM_PARAMS) -o:build/$@ $(REPOS_DIR)/nim-beacon-chain/beacon_chain/$@.nim

clean_eth2_network_simulation_files:
	rm -rf $(REPOS_DIR)/nim-beacon-chain/tests/simulation/data

eth2_network_simulation: | beacon_node validator_keygen clean_eth2_network_simulation_files
	SKIP_BUILDS=1 $(ENV_SCRIPT) $(REPOS_DIR)/nim-beacon-chain/tests/simulation/start.sh

vendor/go/bin/p2pd:
	cd vendor/go/src/github.com/libp2p/go-libp2p-daemon && \
		$(ENV_SCRIPT) go get ./... && \
		$(ENV_SCRIPT) go install ./...

test-libp2p-daemon: | vendor/go/bin/p2pd deps
	cd vendor/nim-libp2p && \
		$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) tests/testdaemon.nim && \
		rm -f tests/testdaemon

# https://bitbucket.org/nimcontrib/ntags/ - currently fails with "out of memory"
ntags:
	ntags -R .

#- a few files need to be excluded because they trigger an infinite loop in https://github.com/universal-ctags/ctags
#- limiting it to Nim files, because there are a lot of C files we don't care about
ctags:
	ctags -R --verbose=yes \
	--langdef=nim \
	--langmap=nim:.nim \
	--regex-nim='/(\w+)\*?\s*=\s*object/\1/c,class/' \
	--regex-nim='/(\w+)\*?\s*=\s*enum/\1/e,enum/' \
	--regex-nim='/(\w+)\*?\s*=\s*tuple/\1/t,tuple/' \
	--regex-nim='/(\w+)\*?\s*=\s*range/\1/s,subrange/' \
	--regex-nim='/(\w+)\*?\s*=\s*proc/\1/p,proctype/' \
	--regex-nim='/proc\s+(\w+)/\1/f,procedure/' \
	--regex-nim='/method\s+(\w+)/\1/m,method/' \
	--regex-nim='/proc\s+`([^`]+)`/\1/o,operator/' \
	--regex-nim='/template\s+(\w+)/\1/u,template/' \
	--regex-nim='/macro\s+(\w+)/\1/v,macro/' \
	--languages=nim \
	--exclude=nimcache \
	--exclude='*/Nim/tinyc' \
	--exclude='*/Nim/tests' \
	--exclude='*/Nim/csources' \
	--exclude=nimbus/genesis_alloc.nim \
	--exclude=$(REPOS_DIR)/nim-bncurve/tests/tvectors.nim \
	.

############################
# Windows-specific section #
############################

ifeq ($(OS), Windows_NT)
  # no tabs allowed for indentation here
  SQLITE_ARCHIVE_32 := sqlite-dll-win32-x86-3240000.zip
  SQLITE_ARCHIVE_64 := sqlite-dll-win64-x64-3240000.zip

  # the AppVeyor 32-build is done on a 64-bit image, so we need to override the architecture detection
  ifeq ($(ARCH_OVERRIDE), x86)
    ARCH := x86
  else
    ifeq ($(PROCESSOR_ARCHITEW6432), AMD64)
      ARCH := x64
    else
      ifeq ($(PROCESSOR_ARCHITECTURE), AMD64)
        ARCH := x64
      endif
      ifeq ($(PROCESSOR_ARCHITECTURE), x86)
        ARCH := x86
      endif
    endif
  endif

  ifeq ($(ARCH), x86)
    SQLITE_ARCHIVE := $(SQLITE_ARCHIVE_32)
    SQLITE_SUFFIX := _32
    ROCKSDB_DIR := x86
  endif
  ifeq ($(ARCH), x64)
    SQLITE_ARCHIVE := $(SQLITE_ARCHIVE_64)
    SQLITE_SUFFIX := _64
    ROCKSDB_DIR := x64
  endif

  SQLITE_URL := https://www.sqlite.org/2018/$(SQLITE_ARCHIVE)
  ROCKSDB_ARCHIVE := nimbus-deps.zip
  ROCKSDB_URL := https://github.com/status-im/nimbus-deps/releases/download/nimbus-deps/$(ROCKSDB_ARCHIVE)
  CURL := curl -O -L
  UNZIP := unzip -o

#- back to tabs
#- copied from .appveyor.yml
#- this is why we can't delete the whole "build" dir in the "clean" target
fetch-dlls: | build
	cd build && \
		$(CURL) $(SQLITE_URL) && \
		$(CURL) $(ROCKSDB_URL) && \
		$(UNZIP) $(SQLITE_ARCHIVE) && \
		cp -a sqlite3.dll sqlite3$(SQLITE_SUFFIX).dll && \
		$(UNZIP) $(ROCKSDB_ARCHIVE) && \
		cp -a $(ROCKSDB_DIR)/*.dll .
endif
