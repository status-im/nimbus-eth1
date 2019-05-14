#!/bin/bash

set -euv

cd $(dirname "$0")

export GIT_REVISION=$(git rev-parse HEAD)

NETWORK=testnet0

if [[ $(git rev-parse --abbrev-ref HEAD) == "devel" ]]; then
  NETWORK=testnet1
fi

buildAndPush() {
  export NETWORK=$1
  export NETWORK_BACKEND=$2

  (cd beacon_node && make push)
}

buildAndPush $NETWORK rlpx
#buildAndPush testnet0 libp2p
