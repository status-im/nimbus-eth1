# Bridging content into the Portal state network

## Seeding from content bridges

### Seeding state data with the `portal_bridge`


#### Step 1: Run a Portal client

Run a Portal client with the Portal JSON-RPC API enabled (e.g. Fluffy) and enable the `state` subnetwork:

```bash
./build/fluffy --rpc --storage-capacity:0 --portal-subnetworks:state
```

> Note: The `--storage-capacity:0` option is not required, but it is added here
for the use case where the node's only focus is on gossiping content from the
`portal_bridge`.


#### Step 2: Run an EL client (archive node) that supports `trace_replayBlockTransactions`

The `portal_bridge` needs access to the EL JSON-RPC API, either through a local
Ethereum client or via a web3 provider.

Currently the portal state bridge requires access to the following EL JSON-RPC APIs:
- `eth_getBlockByNumber`
- `eth_getUncleByBlockNumberAndIndex`
- `trace_replayBlockTransactions`

The `trace_replayBlockTransactions` is a non-standard endpoint that is only implemented
by some clients, e.g. Erigon, Reth and Besu at the time of writing. The bridge uses the
`stateDiff` trace option parameter to collect the state updates for each block of
transactions as it syncs and builds the state from genesis onwards. Since access to the
state is required in order to build these state diffs, an EL archive node is required
to ensure that the state is available for all the historical blocks being synced.


#### Step 3: Run the Portal bridge in state mode

Build & run the `portal_bridge`:
```bash
make portal_bridge

WEB3_URL="ws://127.0.0.1:8548" # Replace with your provider.
./build/portal_bridge state --web3-url:${WEB3_URL} --start-block=1 --gossip-workers=2
```

> Note: A WebSocket connection to the web3 provider is recommended to improve the
speed of the syncing process.

The `--start-block` parameter can be used to start syncing from a specific block number.
The bridge stores a local copy of the collected state diffs in it's database so that
the bridge can be restarted and continue syncing from a specific block number. The
first time the bridge is started it will/must start syncing from the genesis block
so you should initially set the `--start-block` option to 1.

The `--gossip-workers` parameter can be used to set the number of workers that will
gossip the portal state data into the portal state subnetwork. Each worker handles
gossipping the state for a single block and the workers gossip the data concurrently.
It is recommended to increase the number of workers in order to increase the speed
and throughput of the gossiping process up until the point where Fluffy is unable
keep up.

The optional `--verify-gossip` parameter can be used to verify that the state data has
successfully been gossipped and is available on the portal state network. When this
option is enabled the bridge will lookup every bit of state data and verify that it
is available. If any state data is missing, the bridge will retry gossipping the
data for that block. Using this option will slow down the process but will ensure that
the state data is available for every block.
