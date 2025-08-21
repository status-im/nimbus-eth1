#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/..

REPO_DIR="${PWD}"
FIXTURES_DIR="${REPO_DIR}/tests/fixtures"

# --- Current Release Static ---
EEST_STATIC_NAME="Mainnet Static"
EEST_STATIC_VERSION="v4.5.0"
EEST_STATIC_DIR="${FIXTURES_DIR}/eest_static"
EEST_STATIC_ARCHIVE="fixtures_static.tar.gz"
EEST_STATIC_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_STATIC_VERSION}/${EEST_STATIC_ARCHIVE}"

# --- Current Release Stable ---
EEST_STABLE_NAME="Mainnet Stable"
EEST_STABLE_VERSION="v4.5.0"
EEST_STABLE_DIR="${FIXTURES_DIR}/eest_stable"
EEST_STABLE_ARCHIVE="fixtures_stable.tar.gz"
EEST_STABLE_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_STABLE_VERSION}/${EEST_STABLE_ARCHIVE}"

# --- Current Release Develop ---
EEST_DEVELOP_NAME="Mainnet Develop"
EEST_DEVELOP_VERSION="v4.5.0"
EEST_DEVELOP_DIR="${FIXTURES_DIR}/eest_develop"
EEST_DEVELOP_ARCHIVE="fixtures_develop.tar.gz"
EEST_DEVELOP_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_DEVELOP_VERSION}/${EEST_DEVELOP_ARCHIVE}"

# --- Devnet Release ---
EEST_DEVNET_NAME="fusaka-devnet-3"
EEST_DEVNET_VERSION="v1.0.0"
EEST_DEVNET_DIR="${FIXTURES_DIR}/eest_devnet"
EEST_DEVNET_ARCHIVE="fixtures_fusaka-devnet-3.tar.gz"
EEST_DEVNET_URL="https://github.com/ethereum/execution-spec-tests/releases/download/${EEST_DEVNET_NAME}%40${EEST_DEVNET_VERSION}/${EEST_DEVNET_ARCHIVE}"

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

  echo "Downloading and extracting EEST test vectors for ${name} ${version}"

  cd "${FIXTURES_DIR}"
  curl -L "${url}" -o "${archive}"
  tar -xzf "${archive}" -C "${dest_dir}" --strip-components=1

  rm -rf "${dest_dir}/.meta"
  mv "${dest_dir}/blockchain_tests/static/state_tests/"* "${dest_dir}/blockchain_tests" 2>/dev/null || true
  rm -rf "${dest_dir}/blockchain_tests/static"

  mkdir -p "${dest_dir}/engine_tests"
  mv "${dest_dir}/blockchain_tests_engine/static/state_tests/"* "${dest_dir}/engine_tests" 2>/dev/null || true
  rm -rf "${dest_dir}/blockchain_tests_engine"

  mv "${dest_dir}/state_tests/static/state_tests/"* "${dest_dir}/state_tests" 2>/dev/null || true
  rm -rf "${dest_dir}/state_tests/static"

  rm -f "${archive}"

  echo "${version}" > "${dest_dir}/version.txt"

  cd "${REPO_DIR}"
}

# Download stable and develop versions
download_and_extract "${EEST_STATIC_URL}" "${EEST_STATIC_DIR}" "${EEST_STATIC_NAME}" "${EEST_STATIC_VERSION}" "${EEST_STATIC_ARCHIVE}"
download_and_extract "${EEST_STABLE_URL}" "${EEST_STABLE_DIR}" "${EEST_STABLE_NAME}" "${EEST_STABLE_VERSION}" "${EEST_STABLE_ARCHIVE}"
download_and_extract "${EEST_DEVELOP_URL}" "${EEST_DEVELOP_DIR}" "${EEST_DEVELOP_NAME}" "${EEST_DEVELOP_VERSION}" "${EEST_DEVELOP_ARCHIVE}"
download_and_extract "${EEST_DEVNET_URL}" "${EEST_DEVNET_DIR}" "${EEST_DEVNET_NAME}" "${EEST_DEVNET_VERSION}" "${EEST_DEVNET_ARCHIVE}"
