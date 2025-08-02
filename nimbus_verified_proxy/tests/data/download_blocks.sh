#!/bin/bash

# download blocks for fork testing

blocks=(200000 1150000 1920000 2463000 2675000 4370000 7280000 9069000 9200000 11052984 12244000 12965000 13773000 15050000 15537394 17034870 19426587 22431084)
forks=("Frontier" "Homestead" "DAO" "TangerineWhistle" "SpuriousDragon" "Byzantium" "Constantinople" "Istanbul" "MuirGlacier" "StakingDeposit" "Berlin" "London" "ArrowGlacier" "GrayGlacier" "Paris" "Shanghai" "Cancun" "Prague")

for i in {1..18}; do
	filename="${forks[$i]}.json"
	printf -v blknum '0x%x' ${blocks[i]}
	curl -X POST https://mainnet.gateway.tenderly.co -H "Content-Type: application/json" -d '{"jsonrpc": "2.0","method": "eth_getBlockByNumber","params": ["'${blknum}'", true],"id": 1}' | jq '.result' > $filename;
	echo "downloaded block $blknum as $filename";
done

# download blocks for block walk testing
start=22431090
num=10 # vp will walk through fork, good for testing
end=$((start - num))

for (( i=end; i<=start; i++ )); do
	filename="${i}.json"
	printf -v blknum '0x%x' $i
	curl -X POST https://mainnet.gateway.tenderly.co -H "Content-Type: application/json" -d '{"jsonrpc": "2.0","method": "eth_getBlockByNumber","params": ["'${blknum}'", true],"id": 1}' | jq '.result' > $filename;
	echo "downloaded block $blknum as $filename";
done



