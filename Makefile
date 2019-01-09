SHELL := bash # the shell used internally by "make"
GIT_CLONE := git clone --quiet --recurse-submodules
GIT_PULL := git pull --recurse-submodules
GIT_STATUS := git status
#- the Nimble dir can't be "[...]/vendor", or Nimble will start looking for
#  version numbers in repo dirs (because those would be in its subdirectories)
#- duplicated in "env.sh" for the env var with the same name
NIMBLE_DIR := vendor/.nimble
NIMBLE := nimble -y
REPOS_DIR := vendor/repos
# we want a "recursively expanded" (delayed interpolation) variable here, so we can set CMD in rule recipes
RUN_CMD_IN_ALL_REPOS = for D in . vendor/Nim $(REPOS); do echo -e "\n\e[32m$${D}:\e[39m"; cd "$$D"; $(CMD); cd - >/dev/null; done
# absolute path, since it will be run at various subdirectory depths
ENV_SCRIPT := "$(CURDIR)/env.sh"
# duplicated in "env.sh" to prepend NIM_DIR/bin to PATH
NIM_DIR := vendor/Nim
#- forces an update of csources and Nimble repos and a complete rebuild, in case we're called after pulling a new Nim version
#- recompiles Nimble with -d:release until we upgrade to nim-0.20 where koch does it by default
BUILD_NIM := cd $(NIM_DIR) && \
	rm -rf bin/nim_csources csources dist/nimble && \
	sh build_all.sh && \
	$(ENV_SCRIPT) nim c -d:release --noNimblePath -p:compiler --nilseqs:on -o:bin/nimble dist/nimble/src/nimble.nim

#- Git repositories for those dependencies that a Nimbus developer might want to
#  modify and test locally
#- their order ensures that `nimble develop` will run in a certain package's
#  repo before Nimble tries to install it as a (direct or indirect) dependency, in
#  order to avoid duplicate dirs in ".nimble/pgks/"
#- dependencies not listed here are handled entirely by Nimble with "install -y --depsOnly"
REPOS := $(addprefix $(REPOS_DIR)/, \
	status-im/nim-chronicles \
	cheatfate/nimcrypto \
	status-im/nim-ranges \
	status-im/nim-rlp \
	status-im/nim-stint \
	status-im/nim-rocksdb \
	status-im/nim-eth-trie \
	status-im/nim-byteutils \
	status-im/nim-eth-common \
	status-im/nim-http-utils \
	status-im/nim-asyncdispatch2 \
	status-im/nim-json-rpc \
	status-im/nim-faststreams \
	status-im/nim-std-shims \
	status-im/nim-serialization \
	status-im/nim-json-serialization \
	zah/nim-package-visible-types \
	status-im/nim-secp256k1 \
	jangko/snappy \
	status-im/nim-eth-keys \
	status-im/nim-eth-p2p \
	status-im/nim-eth-keyfile \
	status-im/nim-eth-bloom \
	status-im/nim-bncurve \
	status-im/nim-confutils \
	status-im/nim-beacon-chain \
	)

.PHONY: all deps github-ssh build-nim update status ntags ctags nimbus test clean mrproper fetch-dlls

# default target, because it's the first one that doesn't start with '.'
all: nimbus

#- "--nimbleDir" is ignored for custom tasks: https://github.com/nim-lang/nimble/issues/495
#  so we can't run `nimble ... nimbus` or `nimble ... test`. We have to duplicate those custom tasks here.
#- we could use a way to convince Nimble not to check the dependencies each and every time - https://github.com/nim-lang/nimble/issues/589
#- we don't want "-y" here, because the user should be reminded to run `make update`
#  after a manual `git pull` that adds to $(REPOS)
#- a phony target, because teaching `make` how to do conditional recompilation of Nim projects is too complicated
nimbus: | build deps
	$(ENV_SCRIPT) $(NIMBLE) c -o:build/nimbus nimbus/nimbus.nim && echo -e "\nThe binary is in './build/nimbus'."

# dir
build:
	mkdir $@

#- runs only the first time and after `make update` actually updates some repo,
#  so have a "normal" (timestamp-checked) prerequisite here
deps: $(NIMBLE_DIR)

#- depends on Git repos being fetched and our Nim and Nimble being built
#- runs `nimble develop` in those repos (but not in the Nimbus repo) - not
#  parallelizable, because package order matters
#- installs any remaining Nimbus dependency (those not in $(REPOS))
$(NIMBLE_DIR): | $(REPOS) $(NIM_DIR)
	$(eval CMD := [ "$$$$D" = "." ] && continue; $(ENV_SCRIPT) $(NIMBLE) develop)
	$(RUN_CMD_IN_ALL_REPOS)
	$(ENV_SCRIPT) $(NIMBLE) install --depsOnly

#- clones the Git repos
#- can run in parallel with `make -jN`
$(REPOS):
	$(GIT_CLONE) https://github.com/$(subst $(REPOS_DIR)/,,$@) $@

#- clones and builds the Nim compiler and Nimble
$(NIM_DIR):
	$(GIT_CLONE) --depth 1 https://github.com/status-im/Nim $@
	$(BUILD_NIM)

# builds and runs all tests
test: | build deps
	$(ENV_SCRIPT) $(NIMBLE) c -r -d:chronicles_log_level=ERROR -o:build/all_tests tests/all_tests.nim

# usual cleaning
clean:
	rm -rf build/{nimbus,all_tests,*.exe} $(NIMBLE_DIR)

# dangerous cleaning, because you may have not-yet-pushed branches and commits in those vendor repos you're about to delete
mrproper: clean
	rm -rf vendor

# for when you have write access to a repo and you want to use SSH keys
github-ssh:
	sed -i 's#https://github.com/#git@github.com:#' .git/config $(NIM_DIR)/.git/config $(REPOS_DIR)/*/*/.git/config

#- re-builds the Nim compiler (not usually needed, because `make update` does it when necessary)
build-nim: | $(NIM_DIR)
	$(BUILD_NIM)

#- runs `git pull` in all Git repos, if there are new commits in the remote branch
#- rebuilds the Nim compiler after pulling new commits
#- deletes the ".nimble" dir to force the execution of the "deps" target if at least one repo was updated
#- ignores non-zero exit codes from [...] tests
update: | $(REPOS)
	$(eval CMD := \
		git remote update && \
		[ -n "$$$$(git rev-parse @{u})" -a "$$$$(git rev-parse @)" != "$$$$(git rev-parse @{u})" ] && \
		REPO_UPDATED=1 && \
		$(GIT_PULL) && \
		{ [ "$$$$D" = "$(NIM_DIR)" ] && { cd - >/dev/null; $(BUILD_NIM); }; } \
		|| true \
	)
	REPO_UPDATED=0; $(RUN_CMD_IN_ALL_REPOS); [ $$REPO_UPDATED = 1 ] && echo -e "\nAt least one repo updated. Deleting '$(NIMBLE_DIR)'." && rm -rf $(NIMBLE_DIR) || true

# runs `git status` in all Git repos
status: | $(REPOS)
	$(eval CMD := $(GIT_STATUS))
	$(RUN_CMD_IN_ALL_REPOS)

# https://bitbucket.org/nimcontrib/ntags/ - currently fails with "out of memory"
ntags:
	ntags -R .

beacon_node: | $(NIMBLE_DIR)
	$(ENV_SCRIPT) nim c -o:build/beacon_node vendor/repos/status-im/nim-beacon-chain/beacon_chain/beacon_node.nim

validator_keygen: | $(NIMBLE_DIR)
	$(ENV_SCRIPT) nim c -o:build/beacon_node vendor/repos/status-im/nim-beacon-chain/beacon_chain/validator_keygen.nim

clean_eth2_network_simulation_files:
	rm -f vendor/repos/status-im/nim-beacon-chain/tests/simulation/*.json

eth2_network_simulation: | beacon_node validator_keygen clean_eth2_network_simulation_files
	SKIP_BUILDS=1 $(ENV_SCRIPT) vendor/repos/status-im/nim-beacon-chain/tests/simulation/start.sh

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
	--exclude=$(REPOS_DIR)/status-im/nim-bncurve/tests/tvectors.nim \
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
