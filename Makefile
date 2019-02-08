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
# we want a "recursively expanded" (delayed interpolation) variable here, so we can set CMD in rule recipes
RUN_CMD_IN_ALL_REPOS = git submodule foreach --recursive --quiet 'echo -e "\n\e[32m$$name:\e[39m"; $(CMD)'; echo -e "\n\e[32m$$(pwd):\e[39m"; $(CMD)
# absolute path, since it will be run at various subdirectory depths
ENV_SCRIPT := "$(CURDIR)/env.sh"
# duplicated in "env.sh" to prepend NIM_DIR/bin to PATH
NIM_DIR := vendor/Nim
#- forces a rebuild of csources, Nimble and a complete compiler rebuild, in case we're called after pulling a new Nim version
#- uses our Git submodules for csources and Nimble (Git doesn't let us place them in another submodule)
#- recompiles Nimble with -d:release until we upgrade to nim-0.20 where koch does it by default
BUILD_NIM := cd $(NIM_DIR) && \
	rm -rf bin/nim_csources csources dist/nimble && \
	ln -sr ../Nim-csources csources && \
	ln -sr ../nimble dist/nimble && \
	sh build_all.sh && \
	$(ENV_SCRIPT) nim c -d:release --noNimblePath -p:compiler --nilseqs:on -o:bin/nimble dist/nimble/src/nimble.nim

	OpenSystemsLab/tempfile.nim \
	status-im/nim-eth \
	status-im/nim-blscurve \
.PHONY: all premix persist debug dumper hunter deps github-ssh build-nim update status ntags ctags nimbus test clean mrproper fetch-dlls beacon_node validator_keygen clean_eth2_network_simulation_files eth2_network_simulation

# default target, because it's the first one that doesn't start with '.'
all: premix persist debug dumper hunter nimbus

# debugging tools
premix persist debug dumper hunter: | build deps
	$(ENV_SCRIPT) nim c -o:build/$@ premix/$@.nim && \
		echo -e "\nThe binary is in './build/$@'.\n"

#- "--nimbleDir" is ignored for custom tasks: https://github.com/nim-lang/nimble/issues/495
#  so we can't run `nimble ... nimbus` or `nimble ... test`. We have to duplicate those custom tasks here.
#- a phony target, because teaching `make` how to do conditional recompilation of Nim projects is too complicated
nimbus: | build deps
	$(ENV_SCRIPT) nim c -o:build/nimbus nimbus/nimbus.nim && \
		echo -e "\nThe binary is in './build/nimbus'.\n"

# dir
build:
	mkdir $@

#- runs only the first time and after `make update` actually updates some repo,
#  or new repos are cloned, so have "normal" (timestamp-checked) prerequisites here
deps: $(NIM_DIR)/bin/nim $(NIMBLE_DIR)

#- depends on Git repos being fetched and our Nim and Nimble being built
#- runs `nimble develop` in those repos (but not in the Nimbus repo) - not
#  parallelizable, because package order matters
#- installs any remaining Nimbus dependency (those not in $(REPOS))
$(NIMBLE_DIR): | $(NIM_DIR)/bin/nim
	mkdir -p $(NIMBLE_DIR)/pkgs
	git submodule foreach --quiet '\
		[ `ls -1 *.nimble 2>/dev/null | wc -l ` -gt 0 ] && { \
			mkdir -p $$toplevel/$(NIMBLE_DIR)/pkgs/$${sm_path#*/}-#head;\
			echo -e "$$(pwd)\n$$(pwd)" > $$toplevel/$(NIMBLE_DIR)/pkgs/$${sm_path#*/}-#head/$${sm_path#*/}.nimble-link;\
		} || true'

# builds and runs all tests
test: | build deps
	$(ENV_SCRIPT) nim c -r -d:chronicles_log_level=ERROR -o:build/all_tests tests/all_tests.nim

# usual cleaning
clean:
	rm -rf build/{nimbus,all_tests,beacon_node,validator_keygen,*.exe} $(NIMBLE_DIR)

# dangerous cleaning, because you may have not-yet-pushed branches and commits in those vendor repos you're about to delete
mrproper: clean
	rm -rf vendor

# for when you want to use SSH keys
github-ssh:
	sed -i 's#https://github.com/#git@github.com:#' .git/config
	git config --file .gitmodules --get-regexp url | while read LINE; do \
		git config `echo $${LINE} | sed 's#https://github.com/#git@github.com:#'` \
		;done

#- re-builds the Nim compiler (not usually needed, because `make update` does it when necessary)
build-nim: | deps
	$(BUILD_NIM)

#- runs `git pull` in all Git repos, if there are new commits in the remote branch
#- rebuilds the Nim compiler after pulling new commits
#- deletes the ".nimble" dir to force the execution of the "deps" target if at least one repo was updated
#- ignores non-zero exit codes from [...] tests
$(NIM_DIR)/bin/nim update:
	git submodule update --init --recursive --rebase
	git submodule foreach --recursive 'git checkout $$(git config -f $$toplevel/.gitmodules submodule.$$name.branch || echo master)'
	rm -rf $(NIMBLE_DIR)
	[ -e $(NIM_DIR)/bin/nim ] || { $(BUILD_NIM); }

update-remote:
	git submodule update --remote --recursive --rebase

# runs `git status` in all Git repos
status: | $(REPOS)
	$(eval CMD := $(GIT_STATUS))
	$(RUN_CMD_IN_ALL_REPOS)

# https://bitbucket.org/nimcontrib/ntags/ - currently fails with "out of memory"
ntags:
	ntags -R .

#- actually binaries, but have them as phony targets to force rebuilds
beacon_node validator_keygen: | build deps
	$(ENV_SCRIPT) nim c -o:build/$@ $(REPOS_DIR)/nim-beacon-chain/beacon_chain/$@.nim

clean_eth2_network_simulation_files:
	rm -rf $(REPOS_DIR)/nim-beacon-chain/tests/simulation/data

eth2_network_simulation: | beacon_node validator_keygen clean_eth2_network_simulation_files
	SKIP_BUILDS=1 $(ENV_SCRIPT) $(REPOS_DIR)/nim-beacon-chain/tests/simulation/start.sh

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

  ifeq ($(PROCESSOR_ARCHITEW6432), AMD64)
    SQLITE_ARCHIVE := $(SQLITE_ARCHIVE_64)
    SQLITE_SUFFIX := _64
    ROCKSDB_DIR := x64
  else
    ifeq ($(PROCESSOR_ARCHITECTURE), AMD64)
      SQLITE_ARCHIVE := $(SQLITE_ARCHIVE_64)
      SQLITE_SUFFIX := _64
      ROCKSDB_DIR := x64
    endif
    ifeq ($(PROCESSOR_ARCHITECTURE), x86)
      SQLITE_ARCHIVE := $(SQLITE_ARCHIVE_32)
      SQLITE_SUFFIX := _32
      ROCKSDB_DIR := x86
    endif
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
