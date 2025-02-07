#!/usr/bin/env bash

# Copyright (c) 2018-2021 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Requires having cmake installed
# sudo apt install cmake -y

PWD=$(pwd)

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
EVMONE_DIR="${SCRIPT_DIR}/../vendor/evmone"
cd "${EVMONE_DIR}"

git submodule update --init

cmake -S . -B build -DEVMONE_TESTING=ON

# For windows (not yet supported)
#cmake -S . -B build -DEVMONE_TESTING=ON -G "Visual Studio 16 2019" -A x64

cmake --build build --parallel

cp "${EVMONE_DIR}/build/lib/libevmone.so.0.13.0" "${SCRIPT_DIR}/../build/libevmone.so"

cd ${PWD}
