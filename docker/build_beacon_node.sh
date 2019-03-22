#!/bin/bash

set -euv

DOCKERHUB_REPO_NAME=statusteam/nimbus_beacon_node

buildAndPush() {
  NETWORK=$1
  BACKEND=$2

  CONTAINER_NAME=${DOCKERHUB_REPO_NAME}:${NETWORK}_${BACKEND}

  docker build -t $CONTAINER_NAME beacon_node \
    --build-arg network=$NETWORK \
    --build-arg network_backend=$BACKEND

  docker push $CONTAINER_NAME
}

buildAndPush testnet0 rlpx
buildAndPush testnet1 rlpx

buildAndPush testnet0 libp2p
buildAndPush testnet1 libp2p

