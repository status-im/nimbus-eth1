#!/usr/bin/env bash

hive -cleanup -cleanup.older-than 5m

# for dangling Docker resources
docker image prune -f
docker volume prune -f
docker network prune -f
