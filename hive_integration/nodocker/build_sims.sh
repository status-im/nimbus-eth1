#!/usr/bin/env bash

set -e
SIM_DIR="hive_integration/nodocker"
USE_SYSTEM_NIM=1

ENV_SCRIPT="vendor/nimbus-build-system/scripts/env.sh"

# nimbus_db_backend:none -> we only use memory db in simulators
NIM_FLAGS="c -r -d:release -d:disable_libbacktrace -d:nimbus_db_backend:none"

${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/consensus/consensus_sim
${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/graphql/graphql_sim
${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/engine/engine_sim
${ENV_SCRIPT} nim ${NIM_FLAGS} ${SIM_DIR}/rpc/rpc_sim

echo "## ${1}" > simulators.md
cat consensus.md graphql.md engine.md rpc.md >> simulators.md
