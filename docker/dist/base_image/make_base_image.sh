#!/bin/bash

# Copyright (c) 2020-2021 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Build base Docker images for making distributable binaries.
# Should be used from "build-*" Make targets, passing the target architecture's
# name and Docker image tag as parameters.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ -z "${2}" ]]; then
  echo "Usage: $(basename ${0}) ARCH DOCKER_TAG"
  exit 1
fi
ARCH="${1}"
DOCKER_TAG="${2}"

ROCKSDB_DIR=rocksdb

if [[ ! -d "$ROCKSDB_DIR" ]]; then
  # rocksdb folder not exists
  mkdir -p ${ROCKSDB_DIR}
  ROCKSDB_DIR_CREATED=1
fi

DOCKER_BUILDKIT=1 \
  docker build \
  -t ${DOCKER_TAG} \
  --progress=plain \
  -f Dockerfile.${ARCH} .

if [[ -n "$ROCKSDB_DIR_CREATED" ]]; then
  # ROCKSDB_DIR created by this script, remove it.
  # but keep it if it's not created by this script.
  rm -rf ${ROCKSDB_DIR}
fi
