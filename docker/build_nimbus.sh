#!/bin/bash

set -euv

CONTAINER_NAME=statusteam/nimbus

docker build -t $CONTAINER_NAME nimbus
docker push $CONTAINER_NAME

