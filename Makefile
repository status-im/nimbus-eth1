# Copyright (c) 2018-2025 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

SHELL := bash # the shell used internally by "make"

# used inside the included makefiles
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

LINK_PCRE := 0

EXCLUDED_NIM_PACKAGES := 	\
  vendor/nimbus-eth2/vendor/nim-bearssl               \
  vendor/nimbus-eth2/vendor/nim-blscurve              \
  vendor/nimbus-eth2/vendor/nim-bearssl               \
  vendor/nimbus-eth2/vendor/nim-blscurve              \
  vendor/nimbus-eth2/vendor/nimbus-build-system       \
  vendor/nimbus-eth2/vendor/nim-chronicles            \
  vendor/nimbus-eth2/vendor/nim-chronos               \
  vendor/nimbus-eth2/vendor/nim-confutils             \
  vendor/nimbus-eth2/vendor/nimcrypto                 \
  vendor/nimbus-eth2/vendor/nim-eth                   \
  vendor/nimbus-eth2/vendor/nim-faststreams           \
  vendor/nimbus-eth2/vendor/nim-http-utils            \
  vendor/nimbus-eth2/vendor/nim-json-rpc              \
  vendor/nimbus-eth2/vendor/nim-json-serialization    \
  vendor/nimbus-eth2/vendor/nim-libbacktrace          \
  vendor/nimbus-eth2/vendor/nim-metrics               \
  vendor/nimbus-eth2/vendor/nim-nat-traversal         \
  vendor/nimbus-eth2/vendor/nim-results               \
  vendor/nimbus-eth2/vendor/nim-secp256k1             \
  vendor/nimbus-eth2/vendor/nim-serialization         \
  vendor/nimbus-eth2/vendor/nim-snappy                \
  vendor/nimbus-eth2/vendor/nim-sqlite3-abi           \
  vendor/nimbus-eth2/vendor/nim-ssz-serialization     \
  vendor/nimbus-eth2/vendor/nim-stew                  \
  vendor/nimbus-eth2/vendor/nim-stint                 \
  vendor/nimbus-eth2/vendor/nim-testutils             \
  vendor/nimbus-eth2/vendor/nim-toml-serialization    \
  vendor/nimbus-eth2/vendor/nim-unittest2             \
  vendor/nimbus-eth2/vendor/nim-web3                  \
  vendor/nimbus-eth2/vendor/nim-websock               \
  vendor/nimbus-eth2/vendor/nim-zlib                  \
  vendor/nimbus-eth2/vendor/nim-taskpools             \
  vendor/nimbus-eth2/vendor/nim-normalize             \
  vendor/nimbus-eth2/vendor/nim-unicodedb             \
  vendor/nimbus-eth2/vendor/nim-libp2p                \
  vendor/nimbus-eth2/vendor/nim-presto                \
  vendor/nimbus-eth2/vendor/nim-zxcvbn                \
  vendor/nimbus-eth2/vendor/nim-kzg4844               \
  vendor/nimbus-eth2/vendor/nim-minilru               \
  vendor/nimbus-eth2/vendor/nimbus-security-resources \
  vendor/nimbus-eth2/vendor/NimYAML

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

# debugging tools + testing tools
TOOLS := \
	test_tools_build \
	nrpc
TOOLS_DIRS := \
	nrpc \
	tests
# comma-separated values for the "clean" target
TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(TOOLS))

# Portal debugging tools + testing tools
PORTAL_TOOLS := \
	nimbus_portal_bridge \
	eth_data_exporter \
	portalcli \
	fcli_db
PORTAL_TOOLS_DIRS := \
	portal/bridge \
	portal/bridge/common \
	portal/bridge/beacon \
	portal/bridge/history \
	portal/tools
# comma-separated values for the "clean" target
PORTAL_TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(FLUFFY_TOOLS))

# Namespaced variables to avoid conflicts with other makefiles
OS_PLATFORM = $(shell $(CC) -dumpmachine)
ifneq (, $(findstring darwin, $(OS_PLATFORM)))
  SHAREDLIBEXT = dylib
else
ifneq (, $(findstring mingw, $(OS_PLATFORM))$(findstring cygwin, $(OS_PLATFORM))$(findstring msys, $(OS_PLATFORM)))
  SHAREDLIBEXT = dll
else
  SHAREDLIBEXT = so
endif
endif

VERIF_PROXY_OUT_PATH ?= build/libverifproxy/

.PHONY: \
	all \
	$(TOOLS) \
	$(FLUFFY_TOOLS) \
	deps \
	update \
	nimbus \
	nimbus_execution_client \
	nimbus_portal_client \
	fluffy \
	nimbus_verified_proxy \
	libverifproxy \
	external_sync \
	test \
	test-reproducibility \
	clean \
	libnimbus.so \
	libnimbus.a \
	libbacktrace \
	rocksdb \
	dist-linux-amd64 \
	dist-linux-arm64 \
	dist-windows-amd64 \
	dist-macos-arm64 \
	dist \
	eest \
	t8n \
	t8n_test \
	evmstate \
	evmstate_test

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
# selectively download nimbus-eth2 submodules because we don't need all of it's modules
# also holesky already exceeds github LFS quota

# We don't need these `vendor/holesky` files but fetching them
# may trigger 'This repository is over its data quota' from GitHub
GIT_SUBMODULE_CONFIG := -c lfs.fetchexclude=/public-keys/all.txt,/metadata/genesis.ssz,/parsed/parsedConsensusGenesis.json

GIT_SUBMODULE_UPDATE := git -c submodule."vendor/nimbus-eth2".update=none submodule update --init --recursive; \
  git $(GIT_SUBMODULE_CONFIG) submodule update vendor/nimbus-eth2; \
  cd vendor/nimbus-eth2; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/holesky; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/sepolia; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/hoodi; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/gnosis-chain-configs; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init --recursive vendor/nim-kzg4844; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/mainnet; \
  cd ../..

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
all: | $(TOOLS) nimbus_execution_client

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

# "-d:release" cannot be added to config.nims

NIM_PARAMS += -d:release
ifneq ($(if $(ENABLE_LINE_NUMBERS),$(ENABLE_LINE_NUMBERS),0),0)
NIM_PARAMS += -d:chronicles_line_numbers:1
endif

ifeq ($(DISABLE_MARCH_NATIVE),1)
NIM_PARAMS += -d:disableMarchNative
endif

ifeq ($(BOEHM_GC),1)
NIM_PARAMS += --mm:boehm
endif

T8N_PARAMS := -d:chronicles_default_output_device=stderr -d:use_system_rocksdb

ifeq ($(USE_LIBBACKTRACE), 0)
  NIM_PARAMS += -d:disable_libbacktrace
endif

deps: | deps-common nat-libs nimbus.nims
ifneq ($(USE_LIBBACKTRACE), 0)
deps: | libbacktrace
endif

# eth protocol settings, rules from "execution_chain/sync/protocol/eth/variables.mk"
NIM_PARAMS := $(NIM_PARAMS) $(NIM_ETH_PARAMS)

#- deletes and recreates "nimbus.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf nimbus.nims && \
		$(MAKE) nimbus.nims $(HANDLE_OUTPUT)

init: | sanity-checks update-test
	rm -rf nimbus.nims && \
		$(MAKE) nimbus.nims $(HANDLE_OUTPUT)
	+ "$(MAKE)" --no-print-directory deps-common

# builds the tools, wherever they are
$(TOOLS): | build deps rocksdb
	for D in $(TOOLS_DIRS); do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/$@ "$${TOOL_DIR}/$@.nim"

nimbus_execution_client: | build deps rocksdb
	echo -e $(BUILD_MSG) "build/nimbus_execution_client" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/nimbus_execution_client "execution_chain/nimbus_execution_client.nim"

check_revision: nimbus_execution_client
	scripts/check_revision.sh

nimbus: nimbus_execution_client
	echo "The nimbus target is deprecated and will soon change meaning, use 'nimbus_execution_client' instead"

# symlink
nimbus.nims:
	ln -s nimbus.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

# nim-rocksdb
ROCKSDB_CI_CACHE := build/rocksdb

ifneq ($(USE_SYSTEM_ROCKSDB), 0)
rocksdb:
	+ MAKE="$(MAKE)" \
		scripts/rocksdb_ci_cache.sh $(ROCKSDB_CI_CACHE)
else
rocksdb:
endif

eest:
	scripts/eest_ci_cache.sh

# builds and runs the nimbus test suite
test: | build deps rocksdb eest
	$(ENV_SCRIPT) nim test $(NIM_PARAMS) nimbus.nims

test_import: nimbus_execution_client
	$(ENV_SCRIPT) nim test_import $(NIM_PARAMS) nimbus.nims

# builds and runs an EVM-related subset of the nimbus test suite
test-evm: | build deps rocksdb
	$(ENV_SCRIPT) nim test_evm $(NIM_PARAMS) nimbus.nims

build_fuzzers:
	$(ENV_SCRIPT) nim build_fuzzers $(NIM_PARAMS) nimbus.nims

# Primitive reproducibility test.
#
# On some platforms, with some GCC versions, it may not be possible to get a
# deterministic order for debugging info sections - even with
# "-frandom-seed=...". Striping the binaries should make them identical, though.
test-reproducibility:
	+ [ -e build/nimbus_execution_client ] || $(MAKE) V=0 nimbus_execution_client; \
		MD5SUM1=$$($(MD5SUM) build/nimbus_execution_client | cut -d ' ' -f 1) && \
		rm -rf nimcache/*/nimbus_execution_client && \
		$(MAKE) V=0 nimbus_execution_client && \
		MD5SUM2=$$($(MD5SUM) build/nimbus_execution_client | cut -d ' ' -f 1) && \
		[ "$$MD5SUM1" = "$$MD5SUM2" ] && echo -e "\e[92mSuccess: identical binaries.\e[39m" || \
			{ echo -e "\e[91mFailure: the binary changed between builds.\e[39m"; exit 1; }

# Portal related targets

nimbus_portal_client: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/$@ "portal/client/$@.nim"

# alias for nimbus_portal_client
portal: | nimbus_portal_client

# primitive reproducibility test for nimbus_portal_client
portal-test-reproducibility:
	+ [ -e build/portal ] || $(MAKE) V=0 nimbus_portal_client; \
		MD5SUM1=$$($(MD5SUM) build/nimbus_portal_client | cut -d ' ' -f 1) && \
		rm -rf nimcache/*/nimbus_portal_client && \
		$(MAKE) V=0 nimbus_portal_client && \
		MD5SUM2=$$($(MD5SUM) build/nimbus_portal_client | cut -d ' ' -f 1) && \
		[ "$$MD5SUM1" = "$$MD5SUM2" ] && echo -e "\e[92mSuccess: identical binaries.\e[39m" || \
			{ echo -e "\e[91mFailure: the binary changed between builds.\e[39m"; exit 1; }

# builds and runs the Portal test suite
all_portal_tests: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_log_level=ERROR -o:build/$@ "portal/tests/$@.nim"

# alias for all_portal_tests
portal-test: | all_portal_tests

# builds the Portal tools, wherever they are
$(PORTAL_TOOLS): | build deps
	for D in $(PORTAL_TOOLS_DIRS); do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/$@ "$${TOOL_DIR}/$@.nim"

# builds all the Portal tools
portal-tools: | $(PORTAL_TOOLS)

# Build test_portal_testnet
test_portal_testnet: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -o:build/$@ "portal/scripts/$@.nim"

# builds the uTP test app
utp-test-app: | build deps
	$(ENV_SCRIPT) nim utp_test_app $(NIM_PARAMS) nimbus.nims

# builds and runs the utp integration test suite
utp-test: | build deps
	$(ENV_SCRIPT) nim utp_test $(NIM_PARAMS) nimbus.nims

# Deprecated legacy targets, to be removed sometime in the future

# Legacy target, same as nimbus_portal_client, deprecated
fluffy: | build deps
	echo -e "\033[0;31mWarning:\033[0m The fluffy target and binary is deprecated, use 'make nimbus_portal_client' instead"
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/$@ "portal/client/nimbus_portal_client.nim"

# Legacy target, same as nimbus_portal_bridge, deprecated
portal_bridge: | build deps
	echo -e "\033[0;31mWarning:\033[0m The portal_bridge target and binary is deprecated, use 'make nimbus_portal_bridge' instead"
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/$@ "portal/bridge/nimbus_portal_bridge.nim"

# Nimbus Verified Proxy related targets

# Builds the nimbus_verified_proxy
nimbus_verified_proxy: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim nimbus_verified_proxy $(NIM_PARAMS) nimbus.nims

# builds and runs the nimbus_verified_proxy test suite
nimbus-verified-proxy-test: | build deps
	$(ENV_SCRIPT) nim nimbus_verified_proxy_test $(NIM_PARAMS) nimbus.nims

# Shared library for verified proxy

libverifproxy: | build deps
	+ echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim --version && \
		$(ENV_SCRIPT) nim c --app:lib -d:"libp2p_pki_schemes=secp256k1" --noMain:on --threads:on --nimcache:nimcache/libverifproxy -o:$(VERIF_PROXY_OUT_PATH)/$@.$(SHAREDLIBEXT) $(NIM_PARAMS) nimbus_verified_proxy/libverifproxy/verifproxy.nim
	cp nimbus_verified_proxy/libverifproxy/verifproxy.h $(VERIF_PROXY_OUT_PATH)/
	echo -e $(BUILD_END_MSG) "build/$@"

eest_engine: | build deps
	$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_enabled:off -o:build/$@ "tests/eest/$@.nim"

eest_engine_test: | build deps eest eest_engine
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_enabled:off -o:build/$@ "tests/eest/$@.nim"

eest_blockchain: | build deps
	$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_enabled:off -o:build/$@ "tests/eest/$@.nim"

eest_blockchain_test: | build deps eest eest_blockchain
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_enabled:off -o:build/$@ "tests/eest/$@.nim"

eest_stateless_execution_test: | build deps eest eest_blockchain
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_enabled:off -o:build/$@ "tests/eest/$@.nim"

eest_full_test: | build deps eest_blockchain eest_engine
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_enabled:off -o:build/$@ "tests/eest/eest_blockchain_test.nim"
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_enabled:off -o:build/$@ "tests/eest/eest_engine_test.nim"

# builds transition tool
t8n: | build deps
	$(ENV_SCRIPT) nim c $(NIM_PARAMS) $(T8N_PARAMS) "tools/t8n/$@.nim"

# builds and runs transition tool test suite
t8n_test: | build deps t8n
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_default_output_device=stderr "tools/t8n/$@.nim"

# builds evm state test tool
evmstate: | build deps rocksdb
	$(ENV_SCRIPT) nim c $(NIM_PARAMS) "tools/evmstate/$@.nim"

# builds and runs evm state tool test suite
evmstate_test: | build deps evmstate
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) "tools/evmstate/$@.nim"

# builds txparse tool
txparse: | build deps
	$(ENV_SCRIPT) nim c $(NIM_PARAMS) "tools/txparse/$@.nim"

# usual cleaning
clean: | clean-common
	rm -rf build/{nimbus,nimbus_execution_client,nimbus_portal_client,fluffy,portal_bridge,libverifproxy,nimbus_verified_proxy,$(TOOLS_CSV),$(PORTAL_TOOLS_CSV),all_tests,test_kvstore_rocksdb,test_rpc,all_portal_tests,all_history_network_custom_chain_tests,test_portal_testnet,utp_test_app,utp_test,*.dSYM}
	rm -rf tools/t8n/{t8n,t8n_test}
	rm -rf tools/evmstate/{evmstate,evmstate_test}
	rm -rf tests/fixtures/eest
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

dist-linux-amd64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh linux-amd64

dist-linux-arm64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh linux-arm64

dist-windows-amd64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh windows-amd64

dist-macos-arm64:
	+ MAKE="$(MAKE)" \
		scripts/make_dist.sh macos-arm64

dist:
	+ $(MAKE) --no-print-directory dist-linux-amd64
	+ $(MAKE) --no-print-directory dist-linux-arm64
	+ $(MAKE) --no-print-directory dist-windows-amd64
	+ $(MAKE) --no-print-directory dist-macos-arm64

endif # "variables.mk" was not included
