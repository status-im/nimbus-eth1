#!/usr/bin/env bash

# Copyright (c) 2025-2026 Status Research & Development GmbH.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/..

REPO_DIR="${PWD}"
FIXTURES_DIR="${REPO_DIR}/tests/fixtures"

# --- Current Release Develop ---
EEST_DEVELOP_NAME="Mainnet Develop"
EEST_DEVELOP_VERSION="v5.4.0"
EEST_DEVELOP_DIR="${FIXTURES_DIR}/eest_develop"
EEST_DEVELOP_ARCHIVE="fixtures_develop.tar.gz"
EEST_DEVELOP_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_DEVELOP_VERSION}/${EEST_DEVELOP_ARCHIVE}"

# --- BAL Release ---
EEST_BAL_NAME="tests-bal"
EEST_BAL_VERSION="v7.1.1"
EEST_BAL_DIR="${FIXTURES_DIR}/eest_bal"
EEST_BAL_ARCHIVE="fixtures_bal.tar.gz"
EEST_BAL_URL="https://github.com/ethereum/execution-specs/releases/download/${EEST_BAL_NAME}%40${EEST_BAL_VERSION}/${EEST_BAL_ARCHIVE}"

# --- zkevm Release ---
EEST_ZKEVM_NAME="zkevm"
EEST_ZKEVM_VERSION="v0.4.0"
EEST_ZKEVM_DIR="${FIXTURES_DIR}/eest_zkevm"
EEST_ZKEVM_ARCHIVE="fixtures_zkevm.tar.gz"
EEST_ZKEVM_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_ZKEVM_NAME}%40${EEST_ZKEVM_VERSION}/${EEST_ZKEVM_ARCHIVE}"

download_and_extract() {
  local url="$1"
  local dest_dir="$2"
  local name="$3"
  local version="$4"
  local archive="$5"

  if [[ ! -d "$dest_dir" ]]; then
    mkdir -p "$dest_dir"
  fi

  if [[ -f "${dest_dir}/version.txt" ]]; then
    local existing_version
    existing_version=$(cat "${dest_dir}/version.txt")

    if [[ ${existing_version} == "${version}" ]]; then
      echo "EEST fixtures for ${name} ${version} already downloaded in ${dest_dir}. Skipping."
      return
    fi
  fi

  # Remove any existing tests from a prior download
  rm -rf "${dest_dir}/blockchain_tests"
  rm -rf "${dest_dir}/blockchain_tests_engine"
  rm -rf "${dest_dir}/state_tests"

  echo "Downloading and extracting EEST test vectors for ${name} ${version}"

  cd "${FIXTURES_DIR}"
  curl -L "${url}" -o "${archive}"
  tar -xzf "${archive}" -C "${dest_dir}" --strip-components=1

  rm -rf "${dest_dir}/.meta"

  mv "${dest_dir}/blockchain_tests/static/state_tests/"* "${dest_dir}/blockchain_tests" 2>/dev/null || true
  rm -rf "${dest_dir}/blockchain_tests/static"

  mv "${dest_dir}/blockchain_tests_engine/static/state_tests/"* "${dest_dir}/blockchain_tests_engine" 2>/dev/null || true
  rm -rf "${dest_dir}/blockchain_tests_engine/static"

  mv "${dest_dir}/state_tests/static/state_tests/"* "${dest_dir}/state_tests" 2>/dev/null || true
  rm -rf "${dest_dir}/state_tests/static"

  # Remove unused tests
  rm -rf "${dest_dir}/blockchain_tests_engine_x"
  rm -rf "${dest_dir}/blockchain_tests_sync"
  rm -rf "${dest_dir}/transaction_tests"

  rm -f "${archive}"

  echo "${version}" > "${dest_dir}/version.txt"

  cd "${REPO_DIR}"
}

# Download stable and develop versions
download_and_extract "${EEST_DEVELOP_URL}" "${EEST_DEVELOP_DIR}" "${EEST_DEVELOP_NAME}" "${EEST_DEVELOP_VERSION}" "${EEST_DEVELOP_ARCHIVE}"
download_and_extract "${EEST_BAL_URL}" "${EEST_BAL_DIR}" "${EEST_BAL_NAME}" "${EEST_BAL_VERSION}" "${EEST_BAL_ARCHIVE}"
download_and_extract "${EEST_ZKEVM_URL}" "${EEST_ZKEVM_DIR}" "${EEST_ZKEVM_NAME}" "${EEST_ZKEVM_VERSION}" "${EEST_ZKEVM_ARCHIVE}"
