# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

REPO_ROOT            ?= .
VERIF_PROXY_WASM_OUT ?= $(REPO_ROOT)/build/libverifproxy_wasm
OUT     := $(VERIF_PROXY_WASM_OUT)
OBJ_DIR := $(OUT)/objs
NPROC   := $(shell nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

BEARSSL   := $(REPO_ROOT)/vendor/nim-bearssl/bearssl
SECP256K1 := $(REPO_ROOT)/vendor/nim-secp256k1/vendor/secp256k1
LTM       := $(REPO_ROOT)/vendor/libtommath
MCL       := $(REPO_ROOT)/vendor/nim-mcl/vendor/mcl
BLSCURVE  := $(REPO_ROOT)/vendor/nim-blscurve

CFLAGS := \
  -Os \
  -Wno-incompatible-pointer-types \
  -I$(REPO_ROOT)/vendor/nimbus-build-system/vendor/Nim/lib \
  -I$(REPO_ROOT)/vendor/nim-kzg4844/kzg4844/csources/src \
  -I$(REPO_ROOT)/vendor/nim-kzg4844/kzg4844/csources/blst/bindings \
  -D__BLST_PORTABLE__ \
  -I$(MCL)/include \
  -DMCL_FP_BIT=384 \
  -DMCL_FR_BIT=256 \
  -DCYBOZU_DONT_USE_STRING \
  -DCYBOZU_DONT_USE_EXCEPTION \
  -DMCL_BINT_ASM=1 \
  -DMCL_BINT_ASM_X64=0 \
  -DMCL_USE_LLVM \
  -DMCL_MSM=0 \
  -I$(LTM) \
  -I$(BEARSSL)/csources/src \
  -I$(BEARSSL)/csources/inc \
  -I$(BEARSSL)/abi \
  -I$(BEARSSL)/csources/tools

SECP_FLAGS := \
  -DENABLE_MODULE_ECDH=1 \
  -DENABLE_MODULE_RECOVERY=1 \
  -DENABLE_MODULE_SCHNORRSIG=1 \
  -DENABLE_MODULE_EXTRAKEYS=1 \
  -I$(SECP256K1) \
  -I$(SECP256K1)/src

NIMCACHE_SRCS := $(wildcard $(OUT)/nimcache/*.c)
PRESETS_C     := $(wildcard $(OUT)/nimcache/*presets.nim.c)
PRESETS_O     := $(patsubst $(OUT)/nimcache/%.c,$(OBJ_DIR)/nc/%.o,$(PRESETS_C))
LTM_SRCS      := $(wildcard $(LTM)/mp_*.c $(LTM)/s_mp_*.c)

BEARSSL_SRCS := \
  $(shell find $(BEARSSL)/csources/src -name "*.c" \
    ! -name "*_pclmul.c" ! -name "*_pwr8.c" \
    ! -name "*_x86ni*.c" ! -name "*_sse2.c") \
  $(BEARSSL)/secp256r1_verify/ec_p256_m64.c \
  $(BEARSSL)/secp256r1_verify/ecdsa_i31_vrfy_raw.c \
  $(BEARSSL)/certs/cacert20240311.c \
  $(BEARSSL)/csources/tools/vector.c \
  $(BEARSSL)/csources/tools/xmem.c \
  $(BEARSSL)/csources/tools/certs.c \
  $(BEARSSL)/csources/tools/files.c

NIMCACHE_OBJS := $(patsubst $(OUT)/nimcache/%.c, $(OBJ_DIR)/nc/%.o,         $(NIMCACHE_SRCS))
LTM_OBJS      := $(patsubst $(LTM)/%.c,          $(OBJ_DIR)/ltm/%.o,        $(LTM_SRCS))
BEARSSL_OBJS  := $(patsubst $(BEARSSL)/%.c,       $(OBJ_DIR)/bearssl/%.o,    $(BEARSSL_SRCS))

FIXED_OBJS := \
  $(OBJ_DIR)/blst_server.o \
  $(OBJ_DIR)/blst_sha256.o \
  $(OBJ_DIR)/ckzg.o \
  $(OBJ_DIR)/keccak.o \
  $(OBJ_DIR)/secp256k1.o \
  $(OBJ_DIR)/secp256k1_ecmult.o \
  $(OBJ_DIR)/secp256k1_ecmult_gen.o \
  $(OBJ_DIR)/verifproxy_wasm.o \
  $(OBJ_DIR)/mcl_fp.o \
  $(OBJ_DIR)/mcl_base32.o \
  $(OBJ_DIR)/mcl_bint32.o

ALL_OBJS := $(NIMCACHE_OBJS) $(LTM_OBJS) $(BEARSSL_OBJS) $(FIXED_OBJS)

.PHONY: wasm nim-to-c check-nimcache

check-nimcache:
	@[ -n "$(NIMCACHE_SRCS)" ] || { echo "Error: nimcache is empty — run 'make nim-to-c' before 'make wasm'"; exit 1; }

nim-to-c:
	mkdir -p "$(OUT)"
	rm -rf "$(OUT)/nimcache" "$(OUT)/objs"
	mkdir -p "$(OUT)/nimcache"
	@echo "==> Compiling Nim to C (nimcache)"
	nim c \
	  --cpu:wasm32 \
	  --os:linux \
	  "--path:$(REPO_ROOT)/nimbus_verified_proxy/libverifproxy/shims" \
	  -d:emscripten \
	  -d:noSignalHandler \
	  -d:useMalloc \
	  -d:disableMarchNative \
	  "-d:libp2p_pki_schemes=secp256k1" \
	  -d:disable_libbacktrace \
	  "-d:chronicles_timestamps=UnixTime" \
	  --noMain:on \
	  "--nimcache:$(OUT)/nimcache" \
	  -c \
	  nimbus_verified_proxy/libverifproxy/verifproxy.nim

wasm: $(OUT)/verifproxy_wasm.js

$(OUT)/verifproxy_wasm.js: check-nimcache $(ALL_OBJS)
	@echo "==> Linking $@"
	emcc -v \
	  -Os \
	  -flto \
	  -Wl,--error-limit=0 \
	  $(ALL_OBJS) \
	  -sEXPORTED_FUNCTIONS='["_NimMain","_wasm_start","_wasm_stop","_wasm_call","_wasm_deliver_transport","_freeNimAllocatedString","_malloc","_free"]' \
	  -sEXPORTED_RUNTIME_METHODS='["UTF8ToString","stringToNewUTF8"]' \
	  -sALLOW_MEMORY_GROWTH=1 \
	  -sMODULARIZE=1 \
	  -sEXPORT_NAME=VerifProxyModule \
	  -o $@

# nimcache
$(OBJ_DIR)/nc/%.o: $(OUT)/nimcache/%.c
	@mkdir -p $(dir $@)
	@emcc $(CFLAGS) -c $< -o $@
	@echo "[CC] nimcache/$*.c ...done"

# presets.nim.c is set as a special target to disable compile-time optimisation
# this is done because it takes a huge amount of time to compile with opt. Instead
# the file is directed for link time optimisation -flto
$(PRESETS_O): $(PRESETS_C)
	@echo "Compiling presets.nim without optimization"
	@mkdir -p $(dir $@)
	@emcc $(filter-out -Os,$(CFLAGS)) -O0 -flto -c $< -o $@
	@echo "[CC] nimcache/presets.nim.c (O0+flto) ...done"

# libtommath
$(OBJ_DIR)/ltm/%.o: $(LTM)/%.c
	@mkdir -p $(dir $@)
	@emcc $(CFLAGS) -c $< -o $@
	@echo "[CC] libtommath/$*.c ...done"


$(OBJ_DIR)/bearssl/%.o: $(BEARSSL)/%.c
	@mkdir -p $(dir $@)
	@emcc $(CFLAGS) -c $< -o $@
	@echo "[CC] bearssl/$*.c ...done"


$(OBJ_DIR)/blst_server.o: $(BLSCURVE)/vendor/blst/src/server.c
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) -c $< -o $@
	@echo "[CC] blst/server.c ...done"

$(OBJ_DIR)/blst_sha256.o: $(BLSCURVE)/blscurve/blst/blst_sha256.c
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) \
	  -I$(BLSCURVE)/vendor/blst/src \
	  -I$(BLSCURVE)/blscurve/blst \
	  -c $< -o $@
	@echo "[CC] blst/blst_sha256.c ...done"

$(OBJ_DIR)/ckzg.o: $(REPO_ROOT)/vendor/nim-kzg4844/kzg4844/csources/src/ckzg.c
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) -c $< -o $@
	@echo "[CC] kzg/ckzg.c ...done"

$(OBJ_DIR)/keccak.o: $(REPO_ROOT)/vendor/nim-eth/eth/keccak/keccak.c
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) -c $< -o $@
	@echo "[CC] nim-eth/keccak.c ...done"

$(OBJ_DIR)/secp256k1.o: $(SECP256K1)/src/secp256k1.c
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) $(SECP_FLAGS) -c $< -o $@
	@echo "[CC] secp256k1/secp256k1.c ...done"

$(OBJ_DIR)/secp256k1_ecmult.o: $(SECP256K1)/src/precomputed_ecmult.c
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) $(SECP_FLAGS) -c $< -o $@
	@echo "[CC] secp256k1/precomputed_ecmult.c ...done"

$(OBJ_DIR)/secp256k1_ecmult_gen.o: $(SECP256K1)/src/precomputed_ecmult_gen.c
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) $(SECP_FLAGS) -c $< -o $@
	@echo "[CC] secp256k1/precomputed_ecmult_gen.c ...done"

$(OBJ_DIR)/verifproxy_wasm.o: $(REPO_ROOT)/nimbus_verified_proxy/libverifproxy/verifproxy_wasm.c
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) -c $< -o $@
	@echo "[CC] libverifproxy/verifproxy_wasm.c ...done"

$(OBJ_DIR)/mcl_fp.o: $(MCL)/src/fp.cpp
	@mkdir -p $(OBJ_DIR)
	@emcc $(CFLAGS) -c $< -o $@
	@echo "[CC] mcl/fp.cpp ...done"

# LLVM IR files
$(OBJ_DIR)/mcl_base32.o: $(MCL)/src/base32.ll
	@mkdir -p $(OBJ_DIR)
	@emcc -c $< -o $@
	@echo "[CC] mcl/base32.ll ...done"

$(OBJ_DIR)/mcl_bint32.o: $(MCL)/src/bint32.ll
	@mkdir -p $(OBJ_DIR)
	@emcc -c $< -o $@
	@echo "[CC] mcl/bint32.ll ...done"
