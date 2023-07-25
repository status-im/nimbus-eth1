# Seeding data into the Portal history network

## Seeding from locally stored history data

### Building and seeding epoch accumulators into the Portal history network

#### Step 1: Building the epoch accumulators
1. Set-up access to an Ethereum JSON-RPC endpoint (e.g. local geth instance)
that can serve the data.

2. Use the `eth_data_exporter` tool to download and store all block headers into
*.e2s files arranged per epoch (8192 blocks):

```bash
make fluffy-tools

./build/eth_data_exporter history exportEpochHeaders --data-dir:"./user_data_dir/"
```

This will store all block headers up till the merge block into *.e2s files in
the assigned `--data-dir`.

3. Build the master accumulator and the epoch accumulators:

```bash
./build/eth_data_exporter history exportAccumulatorData --writeEpochAccumulators --data-dir:"./user_data_dir/"
```

#### Step 2: Seed the epoch accumulators into the Portal network
Run Fluffy and trigger the propagation of data with the
`portal_history_propagateEpochAccumulators` JSON-RPC API call:

```bash
./build/fluffy --rpc --table-ip-limit:1024 --bucket-ip-limit:24

# From another terminal
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_history_propagateEpochAccumulators","params":["./user_data_dir/"]}' http://localhost:8545 | jq
```


#### Step 3 (Optional): Verify that all epoch accumulators are available
Run Fluffy and run the `content_verifier` tool to verify that all epoch
accumulators are available on the history network:

Make sure you still have a fluffy instance running, if not run:
```bash
./build/fluffy --rpc --table-ip-limit:1024 --bucket-ip-limit:24
```

Run the `content_verifier` tool and see if all epoch accumulators are found:
```bash
./build/content_verifier
```

### Downloading & seeding block data into the Portal network

1. Set-up access to an Ethereum JSON-RPC endpoint (e.g. local geth instance)
that can serve the data.
2. Use the `eth_data_exporter` tool to download history data through the
JSON-RPC endpoint into the format which is suitable for reading data into
Fluffy client and propagating into the network:

```bash
make fluffy-tools

./build/eth_data_exporter history exportBlockData--initial-block:1 --end-block:10 --data-dir:"/user_data_dir/"
```

This will store blocks 1 to 10 into a json file located at
`./user_data_dir/eth-history-data.json`.

3. Run Fluffy and trigger the propagation of data with the
`portal_history_propagate` JSON-RPC API call:

```bash
./build/fluffy --table-ip-limit:1024 --bucket-ip-limit:24 --log-level:info --rpc

# From another shell
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_history_propagate","params":["./user_data_dir/eth-history-data.json"]}' http://localhost:8545 | jq
```

## Seeding from content bridges

### Seeding post-merge block headers and bodies through the beacon chain bridge

Run a Fluffy node with the JSON-RPC API enabled.

```bash
./build/fluffy --rpc --table-ip-limit:1024 --bucket-ip-limit:24
```

Build & run the `beacon_lc_bridge`:
```bash
make beacon_lc_bridge

TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace this
./build/beacon_lc_bridge --trusted-block-root=${TRUSTED_BLOCK_ROOT}
```

The `beacon_lc_bridge` will start with the consensus light client sync follow
beacon block gossip. Once it is synced, the execution payload of new beacon
blocks will be extracted and injected in the Portal network as execution headers
and blocks.

> Note: The execution headers will come without a proof for now.

The injection into the Portal network is done via the
`portal_historyGossip` JSON-RPC endpoint of the running Fluffy node.

> Note: Backfilling of block bodies and headers is not yet supported.
