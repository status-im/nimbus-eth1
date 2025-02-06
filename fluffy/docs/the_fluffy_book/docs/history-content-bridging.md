# Bridging content into the Portal history network

## Seeding history content with the `portal_bridge`

The `portal_bridge` requires `era1` files as source for the block content from before the merge.
It requires access to a full node with EL JSON-RPC API for seeding the latest (head of the chain) block content.
Any block content between the merge and the latest is currently not implemented, but will be implemented in the future by usage of `era` files as source.

### Step 1: Run a Portal client

Run a Portal client with the Portal JSON-RPC API enabled, e.g. Fluffy:

```bash
./build/fluffy --rpc --storage-capacity:0
```

> Note: The `--storage-capacity:0` option is not required, but it is added here
for the use case where the node's only focus is on gossiping content from the
`portal_bridge`.

### Step 2: Run an EL client

The `portal_bridge` needs access to the EL JSON-RPC API, either through a local
Ethereum client or via a web3 provider.

### Step 3: Run the Portal bridge in history mode

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

## Seeding directly from the fluffy client

This method currently only supports seeding block content from before the merge.
It uses `era1` files as source for the content.

1. Run Fluffy and enable `portal_debug` JSON-RPC API:
```bash
./build/fluffy --rpc --rpc-api:portal,portal_debug
```

2. Trigger the seeding of the content with the `portal_debug_historyGossipHeaders` and `portal_debug_historyGossipBlockContent` JSON-RPC methods.
The first method will gossip in the block headers, the second method will gossip the block bodies and receipts. It is important to first trigger the gossip of the headers because these are required for the validation of the bodies and the receipts.

```bash
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1",
"method":"portal_debug_historyGossipHeaders","params":["/somedir/era1/"]}' http://localhost:8545 | jq

curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_debug_historyGossipBlockContent","params":["/somedir/era1/"]}' http://localhost:8545 | jq
```
