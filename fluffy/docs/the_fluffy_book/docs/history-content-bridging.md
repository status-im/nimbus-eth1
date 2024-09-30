# Bridging content into the Portal history network

## Seeding from content bridges

### Seeding history data with the `portal_bridge`

#### Step 1: Run a Portal client

Run a Portal client with the Portal JSON-RPC API enabled, e.g. Fluffy:

```bash
./build/fluffy --rpc --storage-capacity:0
```

> Note: The `--storage-capacity:0` option is not required, but it is added here
for the use case where the node's only focus is on gossiping content from the
`portal_bridge`.

#### Step 2: Run an EL client

The `portal_bridge` needs access to the EL JSON-RPC API, either through a local
Ethereum client or via a web3 provider.

#### Step 3: Run the Portal bridge in history mode

Build & run the `portal_bridge`:
```bash
make portal_bridge

WEB3_URL="http://127.0.0.1:8548" # Replace with your provider.
./build/portal_bridge history --web3-url:${WEB3_URL}
```

Default the portal_bridge will run in `--latest` mode, which means that only the
latest block content will be gossiped into the network.

The portal_bridge also has a `--backfill` mode which will gossip pre-merge blocks
from `era1` files into the network. Default the bridge will audit first whether
the content is available on the network and if not it will gossip it into the
network.

E.g. run latest + backfill with audit mode:
```bash
WEB3_URL="http://127.0.0.1:8548" # Replace with your provider.
./build/portal_bridge history --latest:true --backfill:true --audit:true --era1-dir:/somedir/era1/ --web3-url:${WEB3_URL}
```

### Seeding post-merge history data with the `beacon_lc_bridge`

The `beacon_lc_bridge` is more of a standalone bridge that does not require access to a full node with its EL JSON-RPC API. However it is also more limited in the functions it provides.
It will start with the consensus light client sync and follow beacon block gossip. Once it is synced, the execution payload of new beacon blocks will be extracted and injected in the Portal network as execution headers
and blocks.

> Note: The execution headers will come without a proof.

The injection into the Portal network is done via the
`portal_historyGossip` JSON-RPC endpoint of the running Fluffy node.

> Note: Backfilling of block bodies and headers is not yet supported.

Run a Fluffy node with the JSON-RPC API enabled.

```bash
./build/fluffy --rpc
```

Build & run the `beacon_lc_bridge`:
```bash
make beacon_lc_bridge

TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace with trusted block root.
./build/beacon_lc_bridge --trusted-block-root=${TRUSTED_BLOCK_ROOT}
```

## From locally stored block data

### Building and seeding epoch accumulators

#### Step 1: Building the epoch accumulators
1. Set-up access to an Ethereum JSON-RPC endpoint (e.g. local geth instance)
that can serve the data.

2. Use the `eth_data_exporter` tool to download and store all block headers into
*.e2s files arranged per epoch (8192 blocks):

```bash
make eth_data_exporter

./build/eth_data_exporter history exportEpochHeaders --data-dir:"./user_data_dir/"
```

This will store all block headers up till the merge block into *.e2s files in
the assigned `--data-dir`.

3. Build the master accumulator and the epoch accumulators:

```bash
./build/eth_data_exporter history exportAccumulatorData --write-epoch-records --data-dir:"./user_data_dir/"
```

#### Step 2: Seed the epoch accumulators into the Portal network
Run Fluffy and trigger the propagation of data with the
`portal_history_propagateEpochRecords` JSON-RPC API call:

```bash
./build/fluffy --rpc --rpc-api:portal,portal_debug

# From another terminal
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_history_propagateEpochRecords","params":["./user_data_dir/"]}' http://localhost:8545 | jq
```


#### Step 3 (Optional): Verify that all epoch accumulators are available
Run Fluffy and run the `content_verifier` tool to verify that all epoch
accumulators are available on the history network:

Make sure you still have a fluffy instance running, if not run:
```bash
./build/fluffy --rpc --rpc-api:portal,portal_debug
```

Run the `content_verifier` tool and see if all epoch accumulators are found:
```bash
make content_verifier
./build/content_verifier
```

### Downloading & seeding block data

1. Set-up access to an Ethereum JSON-RPC endpoint (e.g. local geth instance)
that can serve the data.
2. Use the `eth_data_exporter` tool to download history data through the
JSON-RPC endpoint into the format which is suitable for reading data into
Fluffy client and propagating into the network:

```bash
make eth_data_exporter

./build/eth_data_exporter history exportBlockData--initial-block:1 --end-block:10 --data-dir:"/user_data_dir/"
```

This will store blocks 1 to 10 into a json file located at
`./user_data_dir/eth-history-data.json`.

3. Run Fluffy and trigger the propagation of data with the
`portal_history_propagate` JSON-RPC API call:

```bash
./build/fluffy --rpc --rpc-api:portal,portal_debug

# From another shell
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_history_propagate","params":["./user_data_dir/eth-history-data.json"]}' http://localhost:8545 | jq
```
