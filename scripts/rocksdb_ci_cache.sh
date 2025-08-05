#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

set -e

# script arguments
[[ $# -ne 1 ]] && { echo "Usage: $0 rocksdb_cache_dir"; }
ROCKSDB_CACHE="$1"

cd "$(dirname "${BASH_SOURCE[0]}")"/..

REPO_DIR="${PWD}"
BUILD_DEST="${REPO_DIR}/vendor/nim-rocksdb/build"

: "${MAKE:=make}"

# Windows detection
if uname | grep -qiE "mingw|msys"; then
  ON_WINDOWS=1
else
  ON_WINDOWS=0
fi

# Copy files from ci cache folder
if [[ -n "$ROCKSDB_CI_CACHE" && -d "$ROCKSDB_CI_CACHE" ]]; then
  mkdir -p ${BUILD_DEST}
  cp -a "$ROCKSDB_CI_CACHE"/* "$BUILD_DEST"/ || true # let this one fail with an empty cache dir
fi

# This scripts has it's own logic to detect rebuilt or not
if [[ "$ON_WINDOWS" == "0" ]]; then
  MAKE="${MAKE}" ${REPO_DIR}/vendor/nim-rocksdb/scripts/build_static_deps.sh
else
  MAKE="${MAKE}" ${REPO_DIR}/vendor/nim-rocksdb/scripts/build_dlls_windows.sh
  mkdir -p ${REPO_DIR}/build
  cp -a vendor/nim-rocksdb/build/librocksdb.dll build
fi

# Copy files to ci cache folder
if [[ -n "$ROCKSDB_CI_CACHE" ]]; then
  rm -rf "$ROCKSDB_CI_CACHE"
  mkdir "$ROCKSDB_CI_CACHE"
  cp "$BUILD_DEST"/* "$ROCKSDB_CI_CACHE"/
fi
