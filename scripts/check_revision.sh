#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option.

# prevent issue https://github.com/status-im/nimbus-eth1/issues/3661

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/..

REPO_DIR="${PWD}"
EL=execution_chain/nimbus_execution_client

$EL --help
REPO_REVISION=$(git -C $REPO_DIR rev-parse --short=8 HEAD)

# nimbus-eth1/v0.2.0-f10349dc/windows-amd64/Nim-2.2.4
# Copyright (c) 2019-2025 Status Research & Development GmbH

# From `EL --version` output above,
# Get first line and then second field after split by '/'
VERSION=$(echo "$($EL --version | head -n 1)" | cut -d '/' -f 2)

# Get second field after split by '-'
BINARY_REVISION=$(echo $VERSION | cut -d '-' -f 2)

if [[ $REPO_REVISION -ne $BINARY_REVISION ]]; then
  echo "Binary revision differ from repository revision. Expect $REPO_REVISION, get $BINARY_REVISION."
  exit 1 # Exit the script with an error code
fi

# TODO: check copyright year start from 2018, the current 2019 is from nimbus-eth2
