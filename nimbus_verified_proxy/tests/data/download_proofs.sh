curl --request POST \
  --url https://eth.blockrazor.xyz \
  --header 'Content-Type: application/json' \
  --data '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_getBlockByNumber",
  "params": ["latest", true]
}' | jq '.result' > proof_block.json

curl --request POST \
  --url https://eth.blockrazor.xyz \
  --header 'Content-Type: application/json' \
  --data '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_getProof",
  "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", ["0x4de9be9d9a5197eea999984bec8d41aac923403f95449eaf16641fbc3a942711"], "latest"]
}' | jq '.result' > storage_proof.json

curl --request POST \
  --url https://eth.blockrazor.xyz \
  --header 'Content-Type: application/json' \
  --data '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_getCode",
  "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "latest"]
}' | jq '.result' > code.json

echo "Account Balance:\n"
curl --request POST \
  --url https://eth.blockrazor.xyz \
  --header 'Content-Type: application/json' \
  --data '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_getBalance",
  "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "latest"]
}'
echo "\n\n"

echo "Account Nonce:\n"
curl --request POST \
  --url https://eth.blockrazor.xyz \
  --header 'Content-Type: application/json' \
  --data '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_getTransactionCount",
  "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "latest"]
}'
echo "\n\n"

echo "Storage Slot:\n"
curl --request POST \
  --url https://eth.blockrazor.xyz \
  --header 'Content-Type: application/json' \
  --data '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_getStorageAt",
  "params": ["0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", "0x4de9be9d9a5197eea999984bec8d41aac923403f95449eaf16641fbc3a942711", "latest"]
}'
echo "\n\n"

echo "ETH Call:\n"
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
echo "\n\n"

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
}' | jq '.result' > access_list.json

echo "estimate:\n"
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
echo "\n\n"


# the two outputs should match
cat proof_block.json | grep blockNumber | head -n1
curl --request POST \
  --url https://eth.blockrazor.xyz \
  --header 'Content-Type: application/json' \
  --data '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_blockNumber",
  "params": []
}'


