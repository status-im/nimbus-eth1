#!/usr/bin/env bash
# set -Eeuo pipefail

# https://notes.ethereum.org/@9AeMAlpyQYaAAyuj47BzRw/rkwW3ceVY

# To increase verbosity: debug.verbosity(4)
# MetaMask seed phrase for address with balance is:
# lecture manual soon title cloth uncle gesture cereal common fruit tooth crater

set -eu

SCRIPT_DIR=$(cd $(dirname "$0") && pwd)

DATA_DIR=$(mktemp -d)
echo Using data dir ${DATA_DIR}

$SCRIPT_DIR/../../build/nimbus \
  --data-dir:"${DATA_DIR}" \
  --custom-network:"$SCRIPT_DIR/amphora-interop-genesis-m1.json" \
  --engine-api \
  --rpc \
  --discovery:none \
  --import-key:"$SCRIPT_DIR/signer-key.txt" \
  --engine-signer:0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b

