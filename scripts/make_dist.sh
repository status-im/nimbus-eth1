#!/usr/bin/env bash

# Copyright (c) 2020-2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Build release binaries fit for public distribution, using Docker.
# Should be used from "dist-*" Make targets, passing the target architecture's name as a parameter.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/..
REPO_DIR="${PWD}"

ARCH="${1:-linux-amd64}"
DOCKER_TAG="nimbus-eth1-dist-${ARCH}"

docker rm ${DOCKER_TAG} &>/dev/null || true

cd docker/dist

# The dist base images are published for amd64 only. An arm64 host must ask for
# amd64 explicitly, or BuildKit targets the host platform and the build dies on
# the first RUN, unable to exec /bin/sh from the amd64 rootfs. On an amd64 host
# this is what Docker picks anyway, so leave the command line untouched there.
PLATFORM_ARGS=()
if [[ "$(uname -m)" != "x86_64" ]]; then
  PLATFORM_ARGS=(--platform linux/amd64)
fi

DOCKER_BUILDKIT=1 \
  docker build \
  "${PLATFORM_ARGS[@]}" \
  -t ${DOCKER_TAG} \
  --progress=plain \
  --build-arg USER_ID=$(id -u) \
  --build-arg GROUP_ID=$(id -g) \
  -f Dockerfile.${ARCH} .

# seccomp can have some serious overhead, so we disable it with "--privileged" - https://pythonspeed.com/articles/docker-performance-overhead/
docker run --privileged --rm --name ${DOCKER_TAG} -v ${REPO_DIR}:/home/user/nimbus-eth1 ${DOCKER_TAG}

cd - &>/dev/null

ls -l dist

# We rebuild everything inside the container, so we need to clean up afterwards.
${MAKE} --no-print-directory clean
./scripts/clean_foreign_nim.sh
