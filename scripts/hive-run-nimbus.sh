#!/bin/bash

# Startup script to initialize and boot a nimbus EL instance.
#
# This script is a slightly adapted version of the script located at:
# https://github.com/ethereum/hive/blob/77d3c1262ec36ec93527655cd33a77f2f49d8626/clients/nimbus-el/nimbus.sh
# It is adapted to run locally from the nimbus-eth1 repository.
#
# This script assumes the following files:
#  - `nimbus` binary is located in the ./build/ directory (mandatory)
#  - `genesis.json` file is located in the $DATADIR (mandatory)
#  - `chain.rlp` file is located in the $DATADIR (optional)
#  - `blocks` folder is located in the $DATADIR (optional)
#  - `keys` folder is located in the $DATADIR (optional)
#  - `forkenv.json` file is located in the $DATADIR (optional)
#
# This script also requires the `jq` tool and the hive-mapper.jq file
# to be present in the same directory as this script.
#

# Immediately abort the script on any error encountered
set -e

# Directory of this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Optional data directory argument (defaults to execution-apis tests dir, as is used for
# Hive rpc-compat tests)
DATADIR="${1:-./vendor/nim-web3/tests/execution-apis/tests/}"

# Load Hive fork/test environment variables from JSON if present
if [ -f "${DATADIR}/forkenv.json" ]; then
  export $(jq -r 'to_entries|map("\(.key)=\(.value)")|.[]' "${DATADIR}/forkenv.json")
fi

nimbus=./build/nimbus_execution_client
FLAGS="--nat:extip:0.0.0.0 --debug-dynamic-batch-size:true"

loglevel=DEBUG
case "$HIVE_LOGLEVEL" in
    0|1) loglevel=ERROR ;;
    2)   loglevel=WARN  ;;
    3)   loglevel=INFO  ;;
    4)   loglevel=DEBUG ;;
    5)   loglevel=TRACE ;;
esac
FLAGS="$FLAGS --log-level:$loglevel"

# It doesn't make sense to dial out, use only a pre-set bootnode.
if [ "$HIVE_BOOTNODE" != "" ]; then
  FLAGS="$FLAGS --bootstrap-node:$HIVE_BOOTNODE"
fi

if [ "$HIVE_NETWORK_ID" != "" ]; then
  FLAGS="$FLAGS --network:$HIVE_NETWORK_ID"
fi

# Configure the chain.
jq -f "${SCRIPT_DIR}/hive-mapper.jq" "${DATADIR}/genesis.json" > ./genesis-start.json
FLAGS="$FLAGS --network:./genesis-start.json"

# Dump genesis.
if [ "$HIVE_LOGLEVEL" -lt 4 ]; then
  echo "Supplied genesis state (trimmed, use --sim.loglevel 4 or 5 for full output):"
  jq 'del(.genesis.alloc[] | select(.balance == "0x123450000000000000000"))' ./genesis-start.json
else
  echo "Supplied genesis state:"
  cat ./genesis-start.json
fi

# Don't immediately abort, some imports are meant to fail
set +e

# Load the test chain if present
if [ -f "${DATADIR}/chain.rlp" ]; then
  FLAGS="$FLAGS --debug-bootstrap-blocks-file:${DATADIR}/chain.rlp"
else
  echo "Warning: chain.rlp not found."
fi

# Load the remainder of the test chain
echo "Loading remaining individual blocks..."
if [ -d "${DATADIR}/blocks" ]; then
  for f in $(ls "${DATADIR}/blocks" | sort -n); do
    FLAGS="$FLAGS --debug-bootstrap-blocks-file:${DATADIR}/blocks/$f"
  done
else
  echo "Warning: blocks folder not found."
fi

set -e

# Configure RPC
FLAGS="$FLAGS --http-address:0.0.0.0 --http-port:8545"
FLAGS="$FLAGS --rpc --rpc-api:eth,debug,admin"
FLAGS="$FLAGS --ws --ws-api:eth,debug,admin"

# Configure graphql
if [ "$HIVE_GRAPHQL_ENABLED" != "" ]; then
  FLAGS="$FLAGS --graphql"
fi

# Configure engine api
if [ "$HIVE_TERMINAL_TOTAL_DIFFICULTY" != "" ]; then
  echo "0x7365637265747365637265747365637265747365637265747365637265747365" > ./jwtsecret
  FLAGS="$FLAGS --engine-api:true --engine-api-address:0.0.0.0 --engine-api-port:8551 --jwt-secret:./jwtsecret"
fi

echo "Running nimbus with flags $FLAGS"
$nimbus $FLAGS
