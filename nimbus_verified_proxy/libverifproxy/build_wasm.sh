#!/usr/bin/env bash

# Build script to produce an Emscripten-based WASM version of the Nimbus
# verified proxy library.
#
# Requires emcc (Emscripten) in your PATH. Install with:
#   git clone https://github.com/emscripten-core/emsdk.git
#   cd emsdk && ./emsdk install latest-upstream
#   ./emsdk activate latest-upstream
#   source ./emsdk_env.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_SCRIPT="$REPO_ROOT/vendor/nimbus-build-system/scripts/env.sh"

# Output directory - can be overridden via VERIF_PROXY_WASM_OUT environment variable.
OUT="${VERIF_PROXY_WASM_OUT:-$REPO_ROOT/build/verifproxy_wasm}"

mkdir -p "$OUT"

# NIM_PARAMS is intentionally not forwarded: it carries host-only linker flags
# (e.g. -lpcre, -march=native, -flto=auto) that are incompatible with emcc.
cd "$REPO_ROOT"

"$ENV_SCRIPT" nim c \
  --noMain:on \
  --wasm32.linux.gcc.exe:emcc \
  --wasm32.linux.gcc.linkerexe:emcc \
  --cpu:wasm32 \
  --os:linux \
  -d:emscripten \
  -d:noSignalHandler \
  -d:useMalloc \
  -d:disableMarchNative \
  -d:disableLTO \
  -d:"libp2p_pki_schemes=secp256k1" \
  "--nimcache:$OUT/nimcache" \
  "--out:$OUT/verifproxy_wasm.js" \
  "--passL:nimbus_verified_proxy/libverifproxy/verifproxy_wasm.c" \
  '--passL:-sEXPORTED_FUNCTIONS=["_NimMain","_wasm_start","_wasm_stop","_wasm_call","_wasm_deliver_transport","_freeNimAllocatedString","_malloc","_free"]' \
  '--passL:-sEXPORTED_RUNTIME_METHODS=["UTF8ToString","stringToNewUTF8"]' \
  "--passL:-sALLOW_MEMORY_GROWTH=1" \
  "--passL:-sMODULARIZE=1" \
  "--passL:-sEXPORT_NAME=VerifProxyModule" \
  nimbus_verified_proxy/libverifproxy/verifproxy.nim

cp "$SCRIPT_DIR/verifproxy.h" "$OUT/"
