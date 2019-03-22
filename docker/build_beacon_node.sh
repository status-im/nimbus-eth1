#!/bin/bash

set -euv

DOCKERHUB_REPO_NAME=statusteam/nimbus_beacon_node

buildAndPush() {
  export NETWORK=$1
  export NETWORK_BACKEND=$2

  (cd $(dirname "$0")/beacon_node && make push)
}

buildAndPush testnet0 rlpx
buildAndPush testnet1 rlpx

#buildAndPush testnet0 libp2p
#buildAndPush testnet1 libp2p
