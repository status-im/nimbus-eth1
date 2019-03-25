#!/bin/bash

set -euv

cd $(dirname "$0")

export GIT_REVISION=$(git rev-parse HEAD)

buildAndPush() {
  export NETWORK=$1
  export NETWORK_BACKEND=$2

  (cd beacon_node && make push)
}

buildAndPush testnet0 rlpx
buildAndPush testnet1 rlpx

#buildAndPush testnet0 libp2p
#buildAndPush testnet1 libp2p
