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

# nimbus_db_backend:none -> we only use memory db in simulators
NIM_FLAGS="c -d:release"

${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/engine/engine_sim
${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/consensus/consensus_sim
${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/graphql/graphql_sim
${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/rpc/rpc_sim
${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/pyspec/pyspec_sim

${SIM_DIR}/engine/engine_sim
${SIM_DIR}/consensus/consensus_sim
${SIM_DIR}/graphql/graphql_sim
${SIM_DIR}/rpc/rpc_sim
${SIM_DIR}/pyspec/pyspec_sim

echo "## ${1}" > simulators.md
cat engine.md consensus.md graphql.md rpc.md pyspec.md >> simulators.md
