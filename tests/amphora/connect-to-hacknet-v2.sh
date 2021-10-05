#!/usr/bin/env bash

set -eu

SCRIPT_DIR=$(cd $(dirname "$0") && pwd)

cd "$SCRIPT_DIR"

if [[ ! -d hacknet ]]; then
  git clone https://github.com/karalabe/hacknet/
fi

DATA_DIR=hacknet/data/nimbus-eth1
mkdir -p $DATA_DIR

BOOT_NODE=enode://e95870e55cf62fd3d7091d7e0254d10ead007a1ac64ea071296a603d94694b8d92b49f9a3d3851d9aa95ee1452de8b854e0d5e095ef58cc25e7291e7588f4dfc@35.178.114.73:30303

$SCRIPT_DIR/../../build/nimbus \
  --log-level:DEBUG \
  --data-dir:"$SCRIPT_DIR/$DATA_DIR" \
  --custom-network:"$SCRIPT_DIR/hacknet/v2/genesis.json" \
  --bootstrap-node:$BOOT_NODE \
  --network:1337002 \
  --engine-api \
  --rpc

