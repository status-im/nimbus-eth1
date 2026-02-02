#!/usr/bin/env bash

# Copyright (c) 2020-2026 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

set -e

cd /home/user/nimbus-eth1
git config --global core.abbrev 8

if [[ -z "${1}" ]]; then
  echo "Usage: $(basename ${0}) PLATFORM"
  exit 1
fi

PLATFORM="${1}"
BINARIES="nimbus nimbus_verified_proxy"
ROCKSDB_DIR=/usr/rocksdb

echo -e "\nPLATFORM=${PLATFORM}"

copy_rocksdb() {
  mkdir -p vendor/nim-rocksdb/build
  cp ${ROCKSDB_DIR}/* vendor/nim-rocksdb/build
  ROCKSDBVER=$(cat "${ROCKSDB_DIR}/version.txt")
  echo "ROCKSDBVER=${ROCKSDBVER}"
}

#- we need to build everything against libraries available inside this container, including the Nim compiler
#- "librocksdb.a" is a C++ library so we need to link it with the C++ profile
make clean
NIMFLAGS_COMMON="-d:disableMarchNative --gcc.options.debug:'-g1' --clang.options.debug:'-gline-tables-only'"

if [[ "${PLATFORM}" == "windows_amd64" ]]; then
  # Cross-compilation using the llvm distribution of Mingw-w64
  export PATH="/opt/llvm-mingw-ucrt/bin:${PATH}"
  CC=x86_64-w64-mingw32-gcc
  CXX=x86_64-w64-mingw32-g++
  ${CXX} --version

  copy_rocksdb

  make -j$(nproc) init

  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    QUICK_AND_DIRTY_COMPILER=1 \
    USE_SYSTEM_ROCKSDB=0 \
    deps-common

  make \
    -j$(nproc) \
    -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc \
    -f Makefile.mingw \
    CC="${CC}" \
    OS=mingw \
    libminiupnpc.a &>/dev/null

  make \
    -j$(nproc) \
    -C vendor/nim-nat-traversal/vendor/libnatpmp-upstream \
    CC="${CC}" \
    CFLAGS="-Wall -Os -DWIN32 -DNATPMP_STATICLIB -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4 ${CFLAGS}" \
    OS=mingw \
    libnatpmp.a &>/dev/null

  # We set CXX and add CXXFLAGS for libunwind's C++ code, even though we don't
  # use those C++ objects. I don't see an easy way of disabling the C++ parts in
  # libunwind itself.
  #
  # "libunwind.a" combines objects produced from C and C++ code. Even though we
  # don't link any C++-generated objects, the linker still checks them for
  # undefined symbols, so we're forced to use g++ as a linker wrapper.
  # For some reason, macOS's Clang doesn't need this trick, nor do native (and
  # newer) Mingw-w64 toolchains on Windows.
  #
  # nim-blscurve's Windows SSSE3 detection doesn't work when cross-compiling,
  # so we enable it here.

  # -d:PREFER_HASHTREE_SHA256:false, does not works with llvm mingw compiler
  make \
    -j$(nproc) \
    CC="${CC}" \
    CXX="${CXX}" \
    OS=Windows_NT \
    CXXFLAGS="${CXXFLAGS} -D__STDC_FORMAT_MACROS -D_WIN32_WINNT=0x0600" \
    USE_VENDORED_LIBUNWIND=1 \
    LOG_LEVEL="TRACE" \
    USE_SYSTEM_ROCKSDB=0 \
    NIMFLAGS="${NIMFLAGS_COMMON} -d:PREFER_HASHTREE_SHA256:false --os:windows --gcc.exe=${CC} --gcc.linkerexe=${CXX} --passL:-static --passL:-lshlwapi --passL:-lrpcrt4 -d:BLSTuseSSSE3=1" \
    ${BINARIES}

elif [[ "${PLATFORM}" == "linux_arm64" ]]; then
  export PATH="/opt/aarch64/bin:${PATH}"
  CC="aarch64-none-linux-gnu-gcc"
  CXX="aarch64-none-linux-gnu-g++"
  ${CXX} --version

  copy_rocksdb

  make -j$(nproc) init

  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    QUICK_AND_DIRTY_COMPILER=1 \
    USE_SYSTEM_ROCKSDB=0 \
    deps-common

  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    CC="${CC}" \
    CXX="${CXX}" \
    NIMFLAGS="${NIMFLAGS_COMMON} --cpu:arm64 --arm64.linux.gcc.exe=${CC} --arm64.linux.gcc.linkerexe=${CXX} --passL:'-static-libstdc++'" \
    PARTIAL_STATIC_LINKING=1 \
    USE_SYSTEM_ROCKSDB=0 \
    ${BINARIES}

elif [[ "${PLATFORM}" == "macos_arm64" ]]; then
  export PATH="/osxcross/bin:${PATH}"
  export LD_LIBRARY_PATH="/osxcross/lib:$LD_LIBRARY_PATH"
  export OSXCROSS_MP_INC=1 # sets up include and library paths
  export ZERO_AR_DATE=1    # avoid timestamps in binaries
  DARWIN_VER="24.5"
  CC="aarch64-apple-darwin${DARWIN_VER}-clang"
  CXX="aarch64-apple-darwin${DARWIN_VER}-clang++"
  AR="aarch64-apple-darwin${DARWIN_VER}-ar"
  RANLIB="aarch64-apple-darwin${DARWIN_VER}-ranlib"
  DSYMUTIL="aarch64-apple-darwin${DARWIN_VER}-dsymutil"
  ${CXX} --version

  copy_rocksdb

  make -j$(nproc) init

  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    QUICK_AND_DIRTY_COMPILER=1 \
    USE_SYSTEM_ROCKSDB=0 \
    deps-common

  make \
    -j$(nproc) \
    CC="${CC}" \
    LIBTOOL="aarch64-apple-darwin${DARWIN_VER}-libtool" \
    OS="darwin" \
    NIMFLAGS="${NIMFLAGS_COMMON} --os:macosx --cpu:arm64 --passC:'-mcpu=apple-a14' --clang.exe=${CC}" \
    USE_SYSTEM_ROCKSDB=0 \
    nat-libs

  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    CC="${CC}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    CMAKE="aarch64-apple-darwin${DARWIN_VER}-cmake" \
    CMAKE_ARGS="-DCMAKE_TOOLCHAIN_FILE=/osxcross/toolchain.cmake" \
    DSYMUTIL="${DSYMUTIL}" \
    FORCE_DSYMUTIL=1 \
    USE_VENDORED_LIBUNWIND=1 \
    USE_SYSTEM_ROCKSDB=0 \
    NIMFLAGS="${NIMFLAGS_COMMON} --os:macosx --cpu:arm64 --passC:'-mcpu=apple-a14' --passL:-mcpu=apple-a14 --passL:-static-libstdc++ --clang.exe=${CC} --clang.linkerexe=${CXX}" \
    ${BINARIES}

else # linux_amd64
  g++ --version

  copy_rocksdb

  make -j$(nproc) init

  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    NIMFLAGS="${NIMFLAGS_COMMON} --gcc.linkerexe=g++ --passL:'-static-libstdc++'" \
    PARTIAL_STATIC_LINKING=1 \
    QUICK_AND_DIRTY_COMPILER=1 \
    USE_SYSTEM_ROCKSDB=0 \
    ${BINARIES}
fi

# archive directory (we need the Nim compiler in here)
PREFIX="nimbus-eth1_${PLATFORM}_"
GIT_COMMIT="$(git rev-parse --short HEAD)"
VERSION="$(./env.sh nim --verbosity:0 --hints:off --warnings:off scripts/print_version.nims)"
DIR="${PREFIX}${VERSION}_${GIT_COMMIT}"
DIST_PATH="dist/${DIR}"
# delete old artefacts
rm -rf "dist/${PREFIX}"*.tar.gz
if [[ -d "${DIST_PATH}" ]]; then
  rm -rf "${DIST_PATH}"
fi

mkdir -p "${DIST_PATH}"
mkdir "${DIST_PATH}/build"

# copy and checksum binaries, copy docs
EXT=""
if [[ "${PLATFORM}" == "windows_amd64" ]]; then
  cp -a vendor/nim-rocksdb/build/librocksdb.dll "${DIST_PATH}/build/"
  EXT=".exe"
fi

for BINARY in ${BINARIES}; do
  cp -a "./build/${BINARY}${EXT}" "${DIST_PATH}/build/"
  if [[ "${PLATFORM}" =~ macOS ]]; then
    # Collect debugging info and filter out warnings.
    #
    # First two also happen with a native "dsymutil", while the next two only
    # with the "llvm-dsymutil" we use when cross-compiling.
    "${DSYMUTIL}" build/${BINARY} 2>&1 |
      grep -v "failed to insert symbol" |
      grep -v "could not find object file symbol for symbol" |
      grep -v "while processing" |
      grep -v "warning: line table parameters mismatch. Cannot emit." ||
      true
    cp -a "./build/${BINARY}.dSYM" "${DIST_PATH}/build/"
  fi
  cd "${DIST_PATH}/build"
  sha512sum "${BINARY}${EXT}" >"${BINARY}.sha512sum"
  cd - >/dev/null
done
sed -e "s/GIT_COMMIT/${GIT_COMMIT}/" docker/dist/README.md.tpl >"${DIST_PATH}/README.md"

if [[ "${PLATFORM}" == "linux_amd64" ]]; then
  sed -i -e 's/^make dist$/make dist-linux-amd64/' "${DIST_PATH}/README.md"
elif [[ "${PLATFORM}" == "linux_arm64" ]]; then
  sed -i -e 's/^make dist$/make dist-linux-arm64/' "${DIST_PATH}/README.md"
elif [[ "${PLATFORM}" == "windows_amd64" ]]; then
  sed -i -e 's/^make dist$/make dist-windows-amd64/' "${DIST_PATH}/README.md"
  cp -a docker/dist/README-Windows.md.tpl "${DIST_PATH}/README-Windows.md"
elif [[ "${PLATFORM}" == "macos_arm64" ]]; then
  sed -i -e 's/^make dist$/make dist-macos-arm64/' "${DIST_PATH}/README.md"
fi

# create the tarball
cd dist
tar -czf "${DIR}.tar.gz" "${DIR}"
# don't leave the directory hanging around
rm -rf "${DIR}"
cd - >/dev/null
