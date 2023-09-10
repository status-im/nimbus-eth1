#!/usr/bin/env bash

set -e
SIM_DIR="hive_integration/nodocker"
USE_SYSTEM_NIM=1

ENV_SCRIPT="vendor/nimbus-build-system/scripts/env.sh"

# nimbus_db_backend:none -> we only use memory db in simulators
NIM_FLAGS="c -d:release -d:nimbus_db_backend:none"

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
