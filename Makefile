# Copyright (c) 2018-2024 Status Research & Development GmbH. Licensed under
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
	vendor/nimbus-eth2/vendor/nim-bearssl 					\
	vendor/nimbus-eth2/vendor/nim-blscurve 					\
	vendor/nimbus-eth2/vendor/nim-bearssl 					\
	vendor/nimbus-eth2/vendor/nim-blscurve					\
	vendor/nimbus-eth2/vendor/nimbus-build-system		\
	vendor/nimbus-eth2/vendor/nim-chronicles				\
	vendor/nimbus-eth2/vendor/nim-chronos						\
	vendor/nimbus-eth2/vendor/nim-confutils					\
	vendor/nimbus-eth2/vendor/nimcrypto							\
	vendor/nimbus-eth2/vendor/nim-eth								\
	vendor/nimbus-eth2/vendor/nim-faststreams				\
	vendor/nimbus-eth2/vendor/nim-http-utils				\
	vendor/nimbus-eth2/vendor/nim-json-rpc					\
	vendor/nimbus-eth2/vendor/nim-json-serialization\
	vendor/nimbus-eth2/vendor/nim-libbacktrace			\
	vendor/nimbus-eth2/vendor/nim-metrics						\
	vendor/nimbus-eth2/vendor/nim-nat-traversal			\
  vendor/nimbus-eth2/vendor/nim-results     			\
	vendor/nimbus-eth2/vendor/nim-secp256k1					\
	vendor/nimbus-eth2/vendor/nim-serialization			\
	vendor/nimbus-eth2/vendor/nim-snappy						\
	vendor/nimbus-eth2/vendor/nim-sqlite3-abi				\
	vendor/nimbus-eth2/vendor/nim-ssz-serialization	\
	vendor/nimbus-eth2/vendor/nim-stew							\
	vendor/nimbus-eth2/vendor/nim-stint							\
	vendor/nimbus-eth2/vendor/nim-testutils					\
	vendor/nimbus-eth2/vendor/nim-toml-serialization\
	vendor/nimbus-eth2/vendor/nim-unittest2					\
	vendor/nimbus-eth2/vendor/nim-web3							\
	vendor/nimbus-eth2/vendor/nim-websock						\
	vendor/nimbus-eth2/vendor/nim-zlib							\
	vendor/nimbus-eth2/vendor/nim-taskpools					\
	vendor/nimbus-eth2/vendor/nim-normalize					\
	vendor/nimbus-eth2/vendor/nim-unicodedb					\
	vendor/nimbus-eth2/vendor/nim-libp2p						\
	vendor/nimbus-eth2/vendor/nim-presto						\
	vendor/nimbus-eth2/vendor/nim-zxcvbn						\
  vendor/nimbus-eth2/vendor/nim-kzg4844						\
  vendor/nimbus-eth2/vendor/nim-minilru						\
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

# Fluffy debugging tools + testing tools
FLUFFY_TOOLS := \
	portal_bridge \
	eth_data_exporter \
	blockwalk \
	portalcli \
	fcli_db
FLUFFY_TOOLS_DIRS := \
	fluffy/tools/portal_bridge \
	fluffy/tools/state_bridge \
	fluffy/tools
# comma-separated values for the "clean" target
FLUFFY_TOOLS_CSV := $(subst $(SPACE),$(COMMA),$(FLUFFY_TOOLS))

# Namespaced variables to avoid conflicts with other makefiles
VERIF_PROXY_OS = $(shell $(CC) -dumpmachine)
ifneq (, $(findstring darwin, $(VERIF_PROXY_OS)))
  VERIF_PROXY_SHAREDLIBEXT = dylib
else
ifneq (, $(findstring mingw, $(VERIF_PROXY_OS))$(findstring cygwin, $(VERIF_PROXY_OS))$(findstring msys, $(VERIF_PROXY_OS)))
  VERIF_PROXY_SHAREDLIBEXT = dll
else
  VERIF_PROXY_SHAREDLIBEXT = so
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
	nimbus_unified \
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
	dist-amd64 \
	dist-arm64 \
	dist-arm \
	dist-win64 \
	dist-macos \
	dist-macos-arm64 \
	dist

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
# selectively download nimbus-eth2 submodules because we don't need all of it's modules
# also holesky already exceeds github LFS quota

# We don't need these `vendor/holesky` files but fetching them
# may trigger 'This repository is over its data quota' from GitHub
GIT_SUBMODULE_CONFIG := -c lfs.fetchexclude=/public-keys/all.txt,/custom_config_data/genesis.ssz

GIT_SUBMODULE_UPDATE := git -c submodule."vendor/nimbus-eth2".update=none submodule update --init --recursive; \
  git $(GIT_SUBMODULE_CONFIG) submodule update vendor/nimbus-eth2; \
  cd vendor/nimbus-eth2; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/eth2-networks; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/holesky; \
  git $(GIT_SUBMODULE_CONFIG) submodule update --init vendor/sepolia; \
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

# default: use nim native evm
ENABLE_EVMC := 0

# "-d:release" cannot be added to config.nims

NIM_PARAMS += -d:release
ifneq ($(if $(ENABLE_LINE_NUMBERS),$(ENABLE_LINE_NUMBERS),0),0)
NIM_PARAMS += -d:chronicles_line_numbers:1
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

ifneq ($(ENABLE_EVMC), 0)
  NIM_PARAMS += -d:evmc_enabled
  T8N_PARAMS := -d:chronicles_enabled=off
endif

# eth protocol settings, rules from "nimbus/sync/protocol/eth/variables.mk"
NIM_PARAMS := $(NIM_PARAMS) $(NIM_ETH_PARAMS)

#- deletes and recreates "nimbus.nims" which on Windows is a copy instead of a proper symlink
update: | update-common
	rm -rf nimbus.nims && \
		$(MAKE) nimbus.nims $(HANDLE_OUTPUT)

update-from-ci: | sanity-checks update-test
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
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/nimbus_execution_client "nimbus/nimbus_execution_client.nim"

nimbus: nimbus_execution_client
	echo "The nimbus target is deprecated and will soon change meaning, use 'nimbus_execution_client' instead"

# symlink
nimbus.nims:
	ln -s nimbus.nimble $@

# nim-libbacktrace
libbacktrace:
	+ $(MAKE) -C vendor/nim-libbacktrace --no-print-directory BUILD_CXX_LIB=0

# nim-rocksdb

ifneq ($(USE_SYSTEM_ROCKSDB), 0)
ifeq ($(OS), Windows_NT)
rocksdb:
	+ vendor/nim-rocksdb/scripts/build_dlls_windows.bat && \
	cp -a vendor/nim-rocksdb/build/librocksdb.dll build
else
rocksdb:
	+ vendor/nim-rocksdb/scripts/build_static_deps.sh
endif
else
rocksdb:
endif

# builds and runs the nimbus test suite
test: | build deps rocksdb
	$(ENV_SCRIPT) nim test_rocksdb $(NIM_PARAMS) nimbus.nims
	$(ENV_SCRIPT) nim test $(NIM_PARAMS) nimbus.nims

test_import: nimbus_execution_client
	$(ENV_SCRIPT) nim test_import $(NIM_PARAMS) nimbus.nims

# builds and runs an EVM-related subset of the nimbus test suite
test-evm: | build deps rocksdb
	$(ENV_SCRIPT) nim test_evm $(NIM_PARAMS) nimbus.nims

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

# Fluffy related targets

# builds the fluffy client
fluffy: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/$@ "fluffy/$@.nim"

# primitive reproducibility test
fluffy-test-reproducibility:
	+ [ -e build/fluffy ] || $(MAKE) V=0 fluffy; \
		MD5SUM1=$$($(MD5SUM) build/fluffy | cut -d ' ' -f 1) && \
		rm -rf nimcache/*/fluffy && \
		$(MAKE) V=0 fluffy && \
		MD5SUM2=$$($(MD5SUM) build/fluffy | cut -d ' ' -f 1) && \
		[ "$$MD5SUM1" = "$$MD5SUM2" ] && echo -e "\e[92mSuccess: identical binaries.\e[39m" || \
			{ echo -e "\e[91mFailure: the binary changed between builds.\e[39m"; exit 1; }

# fluffy tests
all_history_network_custom_chain_tests: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_log_level=ERROR -d:mergeBlockNumber:38130 -d:nimbus_db_backend=sqlite -o:build/$@ "fluffy/tests/history_network_tests/$@.nim"


all_fluffy_tests: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
	$(ENV_SCRIPT) nim c -r $(NIM_PARAMS) -d:chronicles_log_level=ERROR -d:nimbus_db_backend=sqlite -o:build/$@ "fluffy/tests/$@.nim"

# builds and runs the fluffy test suite
fluffy-test: | all_fluffy_tests all_history_network_custom_chain_tests

# builds the fluffy tools, wherever they are
$(FLUFFY_TOOLS): | build deps rocksdb
	for D in $(FLUFFY_TOOLS_DIRS); do [ -e "$${D}/$@.nim" ] && TOOL_DIR="$${D}" && break; done && \
		echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:chronicles_log_level=TRACE -o:build/$@ "$${TOOL_DIR}/$@.nim"

# builds all the fluffy tools
fluffy-tools: | $(FLUFFY_TOOLS)

# Build fluffy test_portal_testnet
test_portal_testnet: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -o:build/$@ "fluffy/scripts/$@.nim"

# builds the uTP test app
utp-test-app: | build deps
	$(ENV_SCRIPT) nim utp_test_app $(NIM_PARAMS) nimbus.nims

# builds and runs the utp integration test suite
utp-test: | build deps
	$(ENV_SCRIPT) nim utp_test $(NIM_PARAMS) nimbus.nims

# Nimbus Verified Proxy related targets

# Builds the nimbus_verified_proxy
nimbus_verified_proxy: | build deps rocksdb
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim nimbus_verified_proxy $(NIM_PARAMS) nimbus.nims

# builds and runs the nimbus_verified_proxy test suite
nimbus-verified-proxy-test: | build deps rocksdb
	$(ENV_SCRIPT) nim nimbus_verified_proxy_test $(NIM_PARAMS) nimbus.nims

# Shared library for verified proxy

libverifproxy: | build deps rocksdb
	+ echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim --version && \
		$(ENV_SCRIPT) nim c --app:lib -d:"libp2p_pki_schemes=secp256k1" --noMain:on --threads:on --nimcache:nimcache/libverifproxy -o:$(VERIF_PROXY_OUT_PATH)/$@.$(VERIF_PROXY_SHAREDLIBEXT) $(NIM_PARAMS) nimbus_verified_proxy/libverifproxy/verifproxy.nim
	cp nimbus_verified_proxy/libverifproxy/verifproxy.h $(VERIF_PROXY_OUT_PATH)/
	echo -e $(BUILD_END_MSG) "build/$@"

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
	rm -rf build/{nimbus,nimbus_execution_client,fluffy,libverifproxy,nimbus_verified_proxy,$(TOOLS_CSV),$(FLUFFY_TOOLS_CSV),all_tests,test_kvstore_rocksdb,test_rpc,all_fluffy_tests,all_history_network_custom_chain_tests,test_portal_testnet,utp_test_app,utp_test,*.dSYM}
	rm -rf tools/t8n/{t8n,t8n_test}
	rm -rf tools/evmstate/{evmstate,evmstate_test}
ifneq ($(USE_LIBBACKTRACE), 0)
	+ $(MAKE) -C vendor/nim-libbacktrace clean $(HANDLE_OUTPUT)
endif

# Nimbus unified related targets

# builds the unified client
# NIM_PARAMS := -d:release --parallelBuild:1 -d:libp2p_agents_metrics -d:KnownLibP2PAgents=nimbus,lighthouse,lodestar,prysm,teku,grandine $(NIM_PARAMS)
nimbus_unified: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
		$(ENV_SCRIPT) nim c $(NIM_PARAMS) -d:disable_libbacktrace -d:libp2p_pki_schemes=secp256k1 -o:build/$@ "nimbus_unified/$@.nim"
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
