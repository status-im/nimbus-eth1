#!/usr/bin/env bash

# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

set -e
SIM_DIR="hive_integration/nodocker"
USE_SYSTEM_NIM=1

ENV_SCRIPT="vendor/nimbus-build-system/scripts/env.sh"

# we only use memory db in simulators
NIM_FLAGS="c -d:release"

echo "## ${1}" > simulators.md

# more suites: engine, graphql, rpc
suites=(consensus pyspec)
for suite in "${suites[@]}"
do
  ${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/${suite}/${suite}_sim
  ${SIM_DIR}/${suite}/${suite}_sim
  cat ${suite}.md >> simulators.md
done
