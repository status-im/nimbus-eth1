# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

REPO_ROOT        ?= .
NVP_WASM_OUT     ?= $(REPO_ROOT)/build/libverifproxy_wasm

NVP_WASM_EMCC_EXPORTED_FUNCTIONS := ["_wasmStart","_wasmStop","_wasmCall","_wasmDeliverExecutionTransport","_wasmDeliverBeaconTransport","_wasmFreeString","_wasmProcessTasks","_malloc","_free","_wasmExecCtxUrl","_wasmExecCtxName","_wasmExecCtxParams","_wasmBeaconCtxUrl","_wasmBeaconCtxEndpoint","_wasmBeaconCtxParams"]
NVP_WASM_EMCC_EXPORTED_RUNTIME   := ["ccall","cwrap","UTF8ToString","stringToNewUTF8","addFunction","removeFunction"]

NVP_WASM_EMCC_FLAGS := \
  -sEXPORTED_FUNCTIONS='$(NVP_WASM_EMCC_EXPORTED_FUNCTIONS)' \
  -sEXPORTED_RUNTIME_METHODS='$(NVP_WASM_EMCC_EXPORTED_RUNTIME)' \
  -sALLOW_MEMORY_GROWTH=1 \
  -sALLOW_TABLE_GROWTH=1 \
  -sINITIAL_MEMORY=512MB \
  -sSTACK_SIZE=8MB \
  -sABORTING_MALLOC=1 \
  -sMODULARIZE=1 \
  -sEXPORT_NAME=VerifProxyModule \
  -sEXPORT_ES6=1

NVP_WASM_EMCC_DEBUG_FLAGS := -sASSERTIONS=2 -sSTACK_OVERFLOW_CHECK=2
NVP_WASM_WRAPPER_O        := $(NVP_WASM_OUT)/wasm_wrapper.o
NVP_WASM_WRAPPER_C        := $(REPO_ROOT)/nimbus_verified_proxy/bindings/wasm/wasm_wrapper.c

NVP_WASM_NIM_FLAGS := \
  -d:emscripten \
  -d:release \
  "--path:$(REPO_ROOT)/nimbus_verified_proxy/bindings/wasm/shims"

.PHONY: nimbus_verified_proxy_wasm nimbus_verified_proxy_wasm_debug

nimbus_verified_proxy_wasm: $(NVP_WASM_OUT)/verifproxy_wasm.js

nimbus_verified_proxy_wasm_debug: $(NVP_WASM_WRAPPER_O)
	@mkdir -p "$(NVP_WASM_OUT)"
	@echo "==> Building WASM (debug)"
	nim c \
	  $(NVP_WASM_NIM_FLAGS) \
	  --debugger:native \
	  -d:debug \
	  --passL:"$(NVP_WASM_WRAPPER_O)" \
	  --passL:"-O0 -g4 --profiling-funcs -Wl,--error-limit=0 $(NVP_WASM_EMCC_FLAGS) $(NVP_WASM_EMCC_DEBUG_FLAGS)" \
	  -o:"$(NVP_WASM_OUT)/verifproxy_wasm.js" \
	  nimbus_verified_proxy/bindings/c/setup.nim

$(NVP_WASM_OUT)/verifproxy_wasm.js: $(NVP_WASM_WRAPPER_O)
	@mkdir -p "$(NVP_WASM_OUT)"
	@echo "==> Building WASM (release)"
	nim c \
	  $(NVP_WASM_NIM_FLAGS) \
	  --passL:"$(NVP_WASM_WRAPPER_O)" \
	  --passL:"-O1 -flto -Wl,--error-limit=0 $(NVP_WASM_EMCC_FLAGS)" \
	  -o:"$(NVP_WASM_OUT)/verifproxy_wasm.js" \
	  nimbus_verified_proxy/bindings/c/setup.nim

$(NVP_WASM_WRAPPER_O): $(NVP_WASM_WRAPPER_C)
	@mkdir -p "$(NVP_WASM_OUT)"
	emcc -c -I$(REPO_ROOT)/nimbus_verified_proxy/bindings/c $< -o $@
	@echo "[CC] wasm_wrapper.c"
