#!/bin/bash

DOWNLOAD_FOLDER="../data"

while true; do
  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getBlockByNumber",
    "params": ["latest", true]
  }' | jq '.result' > $DOWNLOAD_FOLDER/proof_block.json

  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getProof",
    "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", ["0x4de9be9d9a5197eea999984bec8d41aac923403f95449eaf16641fbc3a942711"], "latest"]
  }' | jq '.result' > $DOWNLOAD_FOLDER/storage_proof.json

  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getCode",
    "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "latest"]
  }' | jq '.result' > $DOWNLOAD_FOLDER/code.json

  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_createAccessList",
    "params": [
      {
        "to": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "data": "0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4"
      }, 
      "latest"
    ]
  }' | jq '.result' > $DOWNLOAD_FOLDER/access_list.json

  echo "Account Balance:"
  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getBalance",
    "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "latest"]
  }'

  echo "Account Nonce:"
  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getTransactionCount",
    "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "latest"]
  }'

  echo "Storage Slot:"
  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getStorageAt",
    "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "0x4de9be9d9a5197eea999984bec8d41aac923403f95449eaf16641fbc3a942711", "latest"]
  }'

  echo "ETH Call:"
  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_call",
    "params": [
      {
        "to": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "data": "0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4"
      }, 
      "latest"
    ]
  }'

  echo "Gas Estimate:"
  curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_estimateGas",
    "params": [
      {
        "to": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "data": "0x70a08231000000000000000000000000De5ae63A348C4d63343C8E20Fb6286909418c8A4"
      }, 
      "latest"
    ]
  }'

  # the two outputs should match
  downloadedBlkNum=$(cat $DOWNLOAD_FOLDER/proof_block.json | jq '.number')
  curBlkNum=$(curl --request POST \
    --url https://eth.blockrazor.xyz \
    --header 'Content-Type: application/json' \
    --data '{"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []}' | jq '.result')
  if [[ "$downloadedBlkNum" == "$curBlkNum" ]]; then
    echo "$downloadedBlkNum $curBlkNum"
    break
  fi
done
