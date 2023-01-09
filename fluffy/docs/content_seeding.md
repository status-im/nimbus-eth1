# Seeding data into the Portal history network

## Building and seeding epoch accumulators into the Portal history network

### Step 1: Building the epoch accumulators
1. Set-up access to an Ethereum JSON-RPC endpoint (e.g. local geth instance)
that can serve the data.

2. Use the `eth-data-exporter` tool to download and store all block headers into
*.e2s files arranged per epoch (8192 blocks):

```bash
make fluffy-tools

./build/eth_data_exporter exportEpochHeaders --data-dir:"./user_data_dir/"
```

This will store all block headers up till the merge block into *.e2s files in
the assigned `--data-dir`.

> Note: Currently only hardcoded address `ws://127.0.0.1:8546` works for the
Ethereum JSON-RPC endpoint.

3. Build the master accumulator and the epoch accumulators:

```bash
./build/eth_data_exporter exportAccumulatorData --writeEpochAccumulators --data-dir:"./user_data_dir/"
```

### Step 2: Seed the epoch accumulators into the Portal network
Run Fluffy and trigger the propagation of data with the
`portal_history_propagateEpochAccumulators` JSON-RPC API call:

```bash
./build/fluffy --network:testnet0 --rpc --table-ip-limit:1024 --bucket-ip-limit:24

# From another terminal
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_history_propagateEpochAccumulators","params":["./user_data_dir/"]}' http://localhost:8545 | jq
```


### Step 3 (Optional): Verify that all epoch accumulators are available
Run Fluffy and run the `content_verifier` tool to verify that all epoch
accumulators are available on the history network:

Make sure you still have a fluffy instance running, if not run:
```bash
./build/fluffy --network:testnet0 --rpc --table-ip-limit:1024 --bucket-ip-limit:24
```

Run the `content_verifier` tool and see if all epoch accumulators are found:
```bash
./build/content_verifier
```

## Seeding block data into the Portal network

1. Set-up access to an Ethereum JSON-RPC endpoint (e.g. local geth instance)
that can serve the data.
2. Use the `eth-data-exporter` tool to download history data through the
JSON-RPC endpoint into the format which is suitable for reading data into
Fluffy client and propagating into the network:

```bash
make fluffy-tools

./build/eth_data_exporter --initial-block:1 --end-block:10 --data-dir:"/user_data_dir/"
```

This will store blocks 1 to 10 into a json file located at
`./user_data_dir/eth-history-data.json`.

> Note: Currently only hardcoded address `ws://127.0.0.1:8546` works for the
Ethereum JSON-RPC endpoint.

3. Run Fluffy and trigger the propagation of data with the
`portal_history_propagate` JSON-RPC API call:

```bash
./build/fluffy --network:testnet0 --table-ip-limit:1024 --bucket-ip-limit:24 --log-level:info --rpc

# From another shell
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_history_propagate","params":["./user_data_dir/eth-history-data.json"]}' http://localhost:8545 | jq
```
