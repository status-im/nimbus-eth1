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
#  - [ ] HIVE_BOOTNODE                enode URL of the remote bootstrap node
#  - [ ] HIVE_NETWORK_ID              network ID number to use for the eth protocol
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
#
# Clique PoA:
#
#  - [ ] HIVE_CLIQUE_PERIOD           enables clique support. value is block time in seconds.
#  - [ ] HIVE_CLIQUE_PRIVATEKEY       private key for clique mining
#
# Other:
#
#  - [ ] HIVE_MINER                   enable mining. value is coinbase address.
#  - [ ] HIVE_MINER_EXTRA             extra-data field to set for newly minted blocks
#  - [ ] HIVE_SKIP_POW                if set, skip PoW verification during block import
#  - [ ] HIVE_LOGLEVEL		            client loglevel (0-5)
#  - [ ] HIVE_GRAPHQL_ENABLED         enables graphql on port 8545

# Immediately abort the script on any error encountered
set -e

nimbus=/usr/bin/nimbus
FLAGS="--prune:archive"

if [ "$HIVE_LOGLEVEL" != "" ]; then
  FLAGS="$FLAGS --log-level:$HIVE_LOGLEVEL"
fi

# Configure the chain.
mv /genesis.json /genesis-input.json
jq -f /mapper.jq /genesis-input.json > /genesis.json

# Dump genesis
echo "Supplied genesis state:"
cat /genesis.json
F-LAGS="$FLAGS --customgenesis:genesis.json"

# Don't immediately abort, some imports are meant to fail
set +e

# Load the remainder of the test chain
echo "Loading remaining individual blocks..."
if [ -d /blocks ]; then
	(cd /blocks && $nimbus $FLAGS --log-level:$HIVE_LOGLEVEL  --import:`ls | sort -n`)
else
	echo "Warning: blocks folder not found."
fi

set -e

# Configure RPC.
FLAGS="$FLAGS --rpc --rpcapi:eth,debug"

echo "Running nimbus with flags $FLAGS"
$nimbus $FLAGS
