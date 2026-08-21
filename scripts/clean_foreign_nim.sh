#!/usr/bin/env bash

# Copyright (c) 2026 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# "make dist" bind-mounts the working tree into a Linux container, so host and
# container share one vendored Nim directory. "make clean" drops bin/nim but
# keeps bin/nim_csources_<hash>, and the Nim build system reuses that without
# checking that it runs - fatal whenever the two sides disagree on OS or CPU.
# That happens in both directions: a macOS or arm64 host feeding an amd64 Linux
# build, and the same host afterwards, once the container has written its own
# binaries back into the mount.
#
# Call this wherever the compiler is about to be used, so "runnable" is decided
# there. A host that matches the container keeps its cached bootstrap compiler.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/..

for BOOTSTRAP in vendor/nimbus-build-system/vendor/Nim/bin/nim_csources_*; do
  if [[ -x "${BOOTSTRAP}" ]] && ! "${BOOTSTRAP}" -v &>/dev/null; then
    echo "Removing ${BOOTSTRAP}: built for another platform."
    rm -f "${BOOTSTRAP}"
  fi
done
