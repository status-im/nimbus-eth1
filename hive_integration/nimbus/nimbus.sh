#!/bin/bash

# Startup script to initialize and boot a nimbus instance.
#
# This script assumes the following files:
#  - `nimbus` binary is located in the filesystem root
#  - `genesis.json` file is located in the filesystem root (mandatory)
#  - `chain.rlp` file is located in the filesystem root (optional)
#  - `blocks` folder is located in the filesystem root (optional)
#  - `keys` folder is located in the filesystem root (optional)
#
# This script assumes the following environment variables:
#
#  - [x] HIVE_BOOTNODE                enode URL of the remote bootstrap node
#  - [x] HIVE_NETWORK_ID              network ID number to use for the eth protocol
#  - [x] HIVE_CHAIN_ID                chain ID is used in transaction signature process
#  - [ ] HIVE_TESTNET                 whether testnet nonces (2^20) are needed
#  - [ ] HIVE_NODETYPE                sync and pruning selector (archive, full, light)
#
# Forks:
#
#  - [x] HIVE_FORK_HOMESTEAD          block number of the homestead hard-fork transition
#  - [x] HIVE_FORK_DAO_BLOCK          block number of the DAO hard-fork transition
#  - [x] HIVE_FORK_DAO_VOTE           whether the node support (or opposes) the DAO fork
#  - [x] HIVE_FORK_TANGERINE          block number of Tangerine Whistle transition
#  - [x] HIVE_FORK_SPURIOUS           block number of Spurious Dragon transition
#  - [x] HIVE_FORK_BYZANTIUM          block number for Byzantium transition
#  - [x] HIVE_FORK_CONSTANTINOPLE     block number for Constantinople transition
#  - [x] HIVE_FORK_PETERSBURG         block number for ConstantinopleFix/PetersBurg transition
#  - [x] HIVE_FORK_ISTANBUL           block number for Istanbul transition
#  - [x] HIVE_FORK_MUIRGLACIER        block number for Muir Glacier transition
#  - [x] HIVE_FORK_BERLIN             block number for Berlin transition
#  - [x] HIVE_FORK_LONDON             block number for London transition
#
# Clique PoA:
#
#  - [x] HIVE_CLIQUE_PERIOD           enables clique support. value is block time in seconds.
#  - [x] HIVE_CLIQUE_PRIVATEKEY       private key for clique mining
#
# Other:
#
#  - [x] HIVE_MINER                   enable mining. value is coinbase address.
#  - [ ] HIVE_MINER_EXTRA             extra-data field to set for newly minted blocks
#  - [ ] HIVE_SKIP_POW                if set, skip PoW verification during block import
#  - [x] HIVE_LOGLEVEL                client loglevel (0-5)
#  - [x] HIVE_GRAPHQL_ENABLED         enables graphql on port 8545

# Immediately abort the script on any error encountered
set -e

nimbus=/usr/bin/nimbus
FLAGS="--prune-mode:archive --nat:extip:0.0.0.0"

if [ "$HIVE_LOGLEVEL" != "" ]; then
  FLAGS="$FLAGS --log-level:DEBUG"
fi

# It doesn't make sense to dial out, use only a pre-set bootnode.
if [ "$HIVE_BOOTNODE" != "" ]; then
  FLAGS="$FLAGS --bootstrap-node:$HIVE_BOOTNODE"
fi

if [ "$HIVE_NETWORK_ID" != "" ]; then
  FLAGS="$FLAGS --network:$HIVE_NETWORK_ID"
fi

if [ "$HIVE_CLIQUE_PRIVATEKEY" != "" ]; then
# -n will prevent newline when echoing something
  echo -n "$HIVE_CLIQUE_PRIVATEKEY" > private.key
  FLAGS="$FLAGS --import-key:private.key"

  if [ "$HIVE_MINER" != "" ]; then
    FLAGS="$FLAGS --engine-signer:$HIVE_MINER"
  fi
fi

# Configure the genesis chain and use it as start block and dump it to stdout
echo "Supplied genesis state:"
jq -f /mapper.jq /genesis.json | tee /genesis-start.json
FLAGS="$FLAGS --custom-network:/genesis-start.json"

# Don't immediately abort, some imports are meant to fail
set +e

# Load the test chain if present
echo "Loading initial blockchain..."
if [ -f /chain.rlp ]; then
  CMD="import /chain.rlp"
  echo "Running nimbus: $nimbus $CMD $FLAGS"
  $nimbus $CMD $FLAGS
else
  echo "Warning: chain.rlp not found."
fi

# Load the remainder of the test chain
echo "Loading remaining individual blocks..."
if [ -d /blocks ]; then
  (cd /blocks && cat `ls | sort -n` > blocks.rlp && $nimbus import blocks.rlp $FLAGS)
else
  echo "Warning: blocks folder not found."
fi

set -e

# Configure RPC.
if [ "$HIVE_GRAPHQL_ENABLED" != "" ]; then
  FLAGS="$FLAGS --graphql --graphql-address:0.0.0.0 --graphql-port:8545"
else
  FLAGS="$FLAGS --rpc --rpc-api:eth,debug --rpc-address:0.0.0.0 --rpc-port:8545"
  FLAGS="$FLAGS --ws --ws-api:eth,debug --ws-address:0.0.0.0 --ws-port:8546"
  FLAGS="$FLAGS --engine-api:true --engine-api-address:0.0.0.0 --engine-api-port:8551"
fi

echo "Running nimbus with flags $FLAGS"
$nimbus $FLAGS
