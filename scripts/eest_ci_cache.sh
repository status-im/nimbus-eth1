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

# --- Mainnet Release ---
EEST_MAINNET_NAME="mainnet"
EEST_MAINNET_VERSION="v20.0.1"
EEST_MAINNET_DIR="${FIXTURES_DIR}/eest_mainnet"
EEST_MAINNET_ARCHIVE="fixtures.tar.gz"
EEST_MAINNET_URL="https://github.com/ethereum/execution-specs/releases/download/tests%40${EEST_MAINNET_VERSION}/${EEST_MAINNET_ARCHIVE}"

# --- Devnet Release ---
EEST_DEVNET_NAME="tests-glamsterdam-devnet"
EEST_DEVNET_VERSION="v8.1.2"
EEST_DEVNET_DIR="${FIXTURES_DIR}/eest_devnet"
EEST_DEVNET_ARCHIVE="fixtures_glamsterdam-devnet.tar.gz"
EEST_DEVNET_URL="https://github.com/ethereum/execution-specs/releases/download/${EEST_DEVNET_NAME}%40${EEST_DEVNET_VERSION}/${EEST_DEVNET_ARCHIVE}"

# --- zkevm Release ---
EEST_ZKEVM_NAME="tests-zkevm"
EEST_ZKEVM_VERSION="v0.8.2"
EEST_ZKEVM_DIR="${FIXTURES_DIR}/eest_zkevm"
EEST_ZKEVM_ARCHIVE="fixtures_zkevm.tar.gz"
EEST_ZKEVM_URL="https://github.com/ethereum/execution-specs/releases/download/${EEST_ZKEVM_NAME}%40${EEST_ZKEVM_VERSION}/${EEST_ZKEVM_ARCHIVE}"

# --- Benchmark Release ---
EEST_BENCHMARK_NAME="tests-benchmark"
EEST_BENCHMARK_VERSION="v0.0.9"
EEST_BENCHMARK_DIR="${FIXTURES_DIR}/eest_benchmark"
EEST_BENCHMARK_ARCHIVE="fixtures_benchmark.tar.gz"
EEST_BENCHMARK_URL="https://github.com/ethereum/execution-specs/releases/download/${EEST_BENCHMARK_NAME}%40${EEST_BENCHMARK_VERSION}/${EEST_BENCHMARK_ARCHIVE}"

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

DEFAULT_RELEASES=(mainnet devnet zkevm)

RELEASES=("$@")
if [[ ${#RELEASES[@]} -eq 0 ]]; then
  RELEASES=("${DEFAULT_RELEASES[@]}")
fi

for release in "${RELEASES[@]}"; do
  case "${release}" in
    mainnet)
      download_and_extract "${EEST_MAINNET_URL}" "${EEST_MAINNET_DIR}" "${EEST_MAINNET_NAME}" "${EEST_MAINNET_VERSION}" "${EEST_MAINNET_ARCHIVE}"
      ;;
    devnet)
      download_and_extract "${EEST_DEVNET_URL}" "${EEST_DEVNET_DIR}" "${EEST_DEVNET_NAME}" "${EEST_DEVNET_VERSION}" "${EEST_DEVNET_ARCHIVE}"
      ;;
    zkevm)
      download_and_extract "${EEST_ZKEVM_URL}" "${EEST_ZKEVM_DIR}" "${EEST_ZKEVM_NAME}" "${EEST_ZKEVM_VERSION}" "${EEST_ZKEVM_ARCHIVE}"
      ;;
    benchmark)
      download_and_extract "${EEST_BENCHMARK_URL}" "${EEST_BENCHMARK_DIR}" "${EEST_BENCHMARK_NAME}" "${EEST_BENCHMARK_VERSION}" "${EEST_BENCHMARK_ARCHIVE}"
      ;;
    *)
      echo "Unknown EEST release: ${release}" >&2
      echo "Known releases: ${DEFAULT_RELEASES[*]} benchmark" >&2
      exit 1
      ;;
  esac
done
