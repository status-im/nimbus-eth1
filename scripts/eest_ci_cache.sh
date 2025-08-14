#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/..

REPO_DIR="${PWD}"
FIXTURES_DIR="${REPO_DIR}/tests/fixtures"
EEST_DIR="${FIXTURES_DIR}/eest"
EEST_VERSION="v4.5.0"
EEST_ARCHIVE="fixtures_static.tar.gz"
EEST_ARCHIVE_FILE="${FIXTURES_DIR}/${EEST_ARCHIVE}"
EEST_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_VERSION}/${EEST_ARCHIVE}"

if [[ ! -d "$EEST_DIR" ]]; then
  mkdir -p ${EEST_DIR}
fi

if [[ -f "${EEST_DIR}/version.txt" ]]; then
  EEST_VERSION_BEFORE=$(cat "${EEST_DIR}/version.txt")

  if [[ ${EEST_VERSION_BEFORE} == ${EEST_VERSION} ]]; then
    echo "EEST fixtures already downloaded. Skipping download."
    exit 0
  fi

fi

echo "Downloading and extracting EEST test vectors"

cd "${FIXTURES_DIR}"
curl -L "${EEST_URL}" -o "${EEST_ARCHIVE}"
tar -xzf ${EEST_ARCHIVE} -C eest --strip-components=1

rm -rf eest/.meta
mv eest/blockchain_tests/static/state_tests/* eest/blockchain_tests
rm -rf eest/blockchain_tests/static

mkdir -p eest/engine_tests
mv eest/blockchain_tests_engine/static/state_tests/* eest/engine_tests
rm -rf eest/blockchain_tests_engine

mv eest/state_tests/static/state_tests/* eest/state_tests
rm -rf eest/state_tests/static

rm -f "${EEST_ARCHIVE}"

echo "${EEST_VERSION}" > eest/version.txt

cd "${REPO_DIR}"
