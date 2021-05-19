#!/bin/bash

# Script to retrieve the enode
#
# This is copied into the validator container by Hive
# and used to provide a client-specific enode id retriever
#

# Immediately abort the script on any error encountered
set -e

TARGET_RESPONSE=$(curl -s -X POST  -H "Content-Type: application/json"  --data '{"jsonrpc":"2.0","method":"net_nodeInfo","params":[],"id":1}' "localhost:8545" )

TARGET_ENODE=$(echo ${TARGET_RESPONSE}| jq -r '.result.enode')
echo "$TARGET_ENODE"
