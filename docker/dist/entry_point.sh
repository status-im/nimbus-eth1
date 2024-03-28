#!/usr/bin/env bash

# Copyright (c) 2020-2022 Status Research & Development GmbH. Licensed under
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
BINARIES="nimbus"
# RocksDB can be upgraded for new nimbus-eth1 versions, since it's built
# on-the-fly, as long as our fixes still apply (or are accepted upstream).
ROCKSDBVER="7.0.3"

build_rocksdb() {
  echo -e "\nBuilding: RocksDB"
  ROCKSDB_ARCHIVE="rocksdb-v${ROCKSDBVER}.tar.gz"
  ROCKSDB_DIR="rocksdb-${ROCKSDBVER}"

  mkdir -p build
  pushd build >/dev/null
  rm -rf "${ROCKSDB_DIR}"
  if [[ ! -e "${ROCKSDB_ARCHIVE}" ]]; then
    curl -L -s -S https://github.com/facebook/rocksdb/archive/v${ROCKSDBVER}.tar.gz -o "${ROCKSDB_ARCHIVE}"
  fi
  tar -xzf "${ROCKSDB_ARCHIVE}"

  pushd "${ROCKSDB_DIR}" >/dev/null

  # MINGW & cross-compilation support: https://github.com/facebook/rocksdb/pull/9752
  patch -p1 -i ../../docker/dist/0001-Makefile-support-Mingw-more-cross-compilation.patch
  # ARM support: https://github.com/facebook/rocksdb/issues/8609#issuecomment-1009572506
  #patch -p1 -i ../../docker/dist/rocksdb-7.0.2-arm.patch

  # This seems the best way to get rid of those huge debugging symbols.
  sed -i \
    -e '/ -g$/d' \
    Makefile

  # Avoid random symbol names for global vars.
  sed -i \
    -e 's/$(CXXFLAGS) -c $</$(CXXFLAGS) -frandom-seed=$< -c $</g' \
    Makefile

  make -j$(nproc) \
    DISABLE_WARNING_AS_ERROR=1 \
    FORCE_GIT_SHA="12345678" \
    git_tag="v${ROCKSDBVER}" \
    build_date="2001-01-01 12:34:56" \
    git_date="2001-01-01 12:34:56" \
    PORTABLE=1 \
    CROSS_COMPILE=true \
    V=1 \
    "$@" \
    static_lib &>build_log.txt

  popd >/dev/null
  popd >/dev/null
}

echo -e "\nPLATFORM=${PLATFORM}"
echo "ROCKSDBVER=${ROCKSDBVER}"

#- we need to build everything against libraries available inside this container, including the Nim compiler
#- "librocksdb.a" is a C++ library so we need to link it with the C++ profile
make clean
NIMFLAGS_COMMON="-d:disableMarchNative --gcc.options.debug:'-g1' --clang.options.debug:'-gline-tables-only' --passL:'/home/user/nimbus-eth1/build/rocksdb-${ROCKSDBVER}/librocksdb.a'"

if [[ "${PLATFORM}" == "Windows_amd64" ]]; then
  # Cross-compilation using the MXE distribution of Mingw-w64
  export PATH="/opt/mxe/usr/bin:${PATH}"
  CC=x86_64-w64-mingw32.static-gcc
  CXX=x86_64-w64-mingw32.static-g++
  ${CXX} --version

  build_rocksdb TARGET_OS=MINGW CXX="${CXX}"

  make -j$(nproc) update-from-ci

  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    QUICK_AND_DIRTY_COMPILER=1 \
    deps-common
    #deps-common build/generate_makefile
  make \
    -j$(nproc) \
    -C vendor/nim-nat-traversal/vendor/miniupnp/miniupnpc \
    -f Makefile.mingw \
    CC="${CC}" \
    libminiupnpc.a &>/dev/null
  make \
    -j$(nproc) \
    -C vendor/nim-nat-traversal/vendor/libnatpmp-upstream \
    CC="${CC}" \
    CFLAGS="-Wall -Os -DWIN32 -DNATPMP_STATICLIB -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4 ${CFLAGS}" \
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
  make \
    -j$(nproc) \
    CC="${CC}" \
    CXX="${CXX}" \
    CXXFLAGS="${CXXFLAGS} -D__STDC_FORMAT_MACROS -D_WIN32_WINNT=0x0600" \
    USE_VENDORED_LIBUNWIND=1 \
    LOG_LEVEL="TRACE" \
    NIMFLAGS="${NIMFLAGS_COMMON} --os:windows --gcc.exe=${CC} --gcc.linkerexe=${CXX} --passL:'-static' -d:BLSTuseSSSE3=1" \
    ${BINARIES}
elif [[ "${PLATFORM}" == "Linux_arm32v7" ]]; then
  CC="arm-linux-gnueabihf-gcc"
  CXX="arm-linux-gnueabihf-g++"
  ${CXX} --version

  build_rocksdb TARGET_ARCHITECTURE=arm CXX="${CXX}"

  make -j$(nproc) update-from-ci

  env CFLAGS="" make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    QUICK_AND_DIRTY_COMPILER=1 \
    deps-common
    #deps-common build/generate_makefile
  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    CC="${CC}" \
    NIMFLAGS="${NIMFLAGS_COMMON} --cpu:arm --gcc.exe=${CC} --gcc.linkerexe=${CXX} --passL:'-static'" \
    ${BINARIES}
elif [[ "${PLATFORM}" == "Linux_arm64v8" ]]; then
  CC="aarch64-linux-gnu-gcc"
  CXX="aarch64-linux-gnu-g++"
  ${CXX} --version

  build_rocksdb TARGET_ARCHITECTURE=arm64 CXX="${CXX}"

  make -j$(nproc) update-from-ci

  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    QUICK_AND_DIRTY_COMPILER=1 \
    deps-common
    #deps-common build/generate_makefile
  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    CC="${CC}" \
    NIMFLAGS="${NIMFLAGS_COMMON} --cpu:arm64 --gcc.exe=${CC} --gcc.linkerexe=${CXX} --passL:'-static-libstdc++'" \
    PARTIAL_STATIC_LINKING=1 \
    ${BINARIES}
elif [[ "${PLATFORM}" == "macOS_amd64" ]]; then
  export PATH="/opt/osxcross/bin:${PATH}"
  export OSXCROSS_MP_INC=1 # sets up include and library paths
  export ZERO_AR_DATE=1 # avoid timestamps in binaries
  DARWIN_VER="20.4"
  CC="o64-clang"
  CXX="o64-clang++"
  AR="x86_64-apple-darwin${DARWIN_VER}-ar"
  RANLIB="x86_64-apple-darwin${DARWIN_VER}-ranlib"
  DSYMUTIL="x86_64-apple-darwin${DARWIN_VER}-dsymutil"
  ${CXX} --version

  build_rocksdb TARGET_OS=Darwin CXX="${CXX}" AR="${AR}"

  make -j$(nproc) update-from-ci

  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    QUICK_AND_DIRTY_COMPILER=1 \
    deps-common
    #deps-common build/generate_makefile
  make \
    -j$(nproc) \
    CC="${CC}" \
    LIBTOOL="x86_64-apple-darwin${DARWIN_VER}-libtool" \
    OS="darwin" \
    NIMFLAGS="${NIMFLAGS_COMMON} --os:macosx --clang.exe=${CC}" \
    nat-libs
  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    CC="${CC}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    CMAKE="x86_64-apple-darwin${DARWIN_VER}-cmake" \
    CMAKE_ARGS="-DCMAKE_TOOLCHAIN_FILE=/opt/osxcross/toolchain.cmake" \
    DSYMUTIL="${DSYMUTIL}" \
    FORCE_DSYMUTIL=1 \
    USE_VENDORED_LIBUNWIND=1 \
    NIMFLAGS="${NIMFLAGS_COMMON} --os:macosx --clang.exe=${CC} --clang.linkerexe=${CXX} --passL:'-static-libstdc++ -mmacosx-version-min=10.14'" \
    ${BINARIES}
elif [[ "${PLATFORM}" == "macOS_arm64" ]]; then
  export PATH="/opt/osxcross/bin:${PATH}"
  export OSXCROSS_MP_INC=1 # sets up include and library paths
  export ZERO_AR_DATE=1 # avoid timestamps in binaries
  DARWIN_VER="20.4"
  CC="oa64-clang"
  CXX="oa64-clang++"
  AR="arm64-apple-darwin${DARWIN_VER}-ar"
  RANLIB="arm64-apple-darwin${DARWIN_VER}-ranlib"
  DSYMUTIL="arm64-apple-darwin${DARWIN_VER}-dsymutil"
  ${CXX} --version

  build_rocksdb TARGET_OS=Darwin TARGET_ARCHITECTURE=arm64 CXX="${CXX}" AR="${AR}"

  make -j$(nproc) update-from-ci

  make \
    -j$(nproc) \
    USE_LIBBACKTRACE=0 \
    QUICK_AND_DIRTY_COMPILER=1 \
    deps-common
    #deps-common build/generate_makefile
  make \
    -j$(nproc) \
    CC="${CC}" \
    LIBTOOL="arm64-apple-darwin${DARWIN_VER}-libtool" \
    OS="darwin" \
    NIMFLAGS="${NIMFLAGS_COMMON} --os:macosx --cpu:arm64 --passC:'-mcpu=apple-a14' --clang.exe=${CC}" \
    nat-libs
  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    CC="${CC}" \
    AR="${AR}" \
    RANLIB="${RANLIB}" \
    CMAKE="arm64-apple-darwin${DARWIN_VER}-cmake" \
    CMAKE_ARGS="-DCMAKE_TOOLCHAIN_FILE=/opt/osxcross/toolchain.cmake" \
    DSYMUTIL="${DSYMUTIL}" \
    FORCE_DSYMUTIL=1 \
    USE_VENDORED_LIBUNWIND=1 \
    NIMFLAGS="${NIMFLAGS_COMMON} --os:macosx --cpu:arm64 --passC:'-mcpu=apple-a13' --passL:'-mcpu=apple-a14 -static-libstdc++' --clang.exe=${CC} --clang.linkerexe=${CXX}" \
    ${BINARIES}
else
  # Linux AMD64
  g++ --version

  build_rocksdb

  make -j$(nproc) update-from-ci

  make \
    -j$(nproc) \
    LOG_LEVEL="TRACE" \
    NIMFLAGS="${NIMFLAGS_COMMON} --gcc.linkerexe=g++ --passL:'-static-libstdc++'" \
    PARTIAL_STATIC_LINKING=1 \
    QUICK_AND_DIRTY_COMPILER=1 \
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
if [[ "${PLATFORM}" == "Windows_amd64" ]]; then
  EXT=".exe"
fi
for BINARY in ${BINARIES}; do
  cp -a "./build/${BINARY}${EXT}" "${DIST_PATH}/build/"
  if [[ "${PLATFORM}" =~ macOS ]]; then
    # Collect debugging info and filter out warnings.
    #
    # First two also happen with a native "dsymutil", while the next two only
    # with the "llvm-dsymutil" we use when cross-compiling.
    "${DSYMUTIL}" build/${BINARY} 2>&1 \
      | grep -v "failed to insert symbol" \
      | grep -v "could not find object file symbol for symbol" \
      | grep -v "while processing" \
      | grep -v "warning: line table paramters mismatch. Cannot emit." \
      || true
    cp -a "./build/${BINARY}.dSYM" "${DIST_PATH}/build/"
  fi
  cd "${DIST_PATH}/build"
  sha512sum "${BINARY}${EXT}" > "${BINARY}.sha512sum"
  cd - >/dev/null
done
sed -e "s/GIT_COMMIT/${GIT_COMMIT}/" docker/dist/README.md.tpl > "${DIST_PATH}/README.md"

if [[ "${PLATFORM}" == "Linux_amd64" ]]; then
  sed -i -e 's/^make dist$/make dist-amd64/' "${DIST_PATH}/README.md"
elif [[ "${PLATFORM}" == "Linux_arm32v7" ]]; then
  sed -i -e 's/^make dist$/make dist-arm/' "${DIST_PATH}/README.md"
elif [[ "${PLATFORM}" == "Linux_arm64v8" ]]; then
  sed -i -e 's/^make dist$/make dist-arm64/' "${DIST_PATH}/README.md"
elif [[ "${PLATFORM}" == "Windows_amd64" ]]; then
  sed -i -e 's/^make dist$/make dist-win64/' "${DIST_PATH}/README.md"
  cp -a docker/dist/README-Windows.md.tpl "${DIST_PATH}/README-Windows.md"
elif [[ "${PLATFORM}" == "macOS_amd64" ]]; then
  sed -i -e 's/^make dist$/make dist-macos/' "${DIST_PATH}/README.md"
elif [[ "${PLATFORM}" == "macOS_arm64" ]]; then
  sed -i -e 's/^make dist$/make dist-macos-arm64/' "${DIST_PATH}/README.md"
fi

# create the tarball
cd dist
tar -czf "${DIR}.tar.gz" "${DIR}"
# don't leave the directory hanging around
rm -rf "${DIR}"
cd - >/dev/null
