# Bridging content into the Portal history network

## Seeding history content with the Nimbus Portal bridge

The Nimbus Portal bridge requires `era1` files as source for the block content from before the merge.
It requires access to a full node with EL JSON-RPC API for seeding the latest (head of the chain) block content.
Any block content between the merge and the latest is currently not implemented, but will be implemented in the future by usage of `era` files as source.

### Step 1: Run a Portal client

Run a Portal client with the Portal JSON-RPC API enabled, e.g. Nimbus Portal client:

```bash
./build/nimbus_portal_client --rpc --storage-capacity:0
```

> Note: The `--storage-capacity:0` option is not required, but it is added here
for the use case where the node's only focus is on gossiping content from the portal bridge.

### Step 2: Run an EL client

The Nimbus Portal bridge needs access to the EL JSON-RPC API, either through a local
Ethereum client or via a web3 provider.

### Step 3: Run the Portal bridge in history mode

Build & run the Nimbus Portal bridge:
```bash
make nimbus_portal_bridge

WEB3_URL="http://127.0.0.1:8548" # Replace with your provider.
./build/nimbus_portal_bridge history --web3-url:${WEB3_URL}
```

By default the Nimbus Portal bridge will run in `--latest` mode, which means that only the
latest block content will be gossiped into the network.

It also has a `--backfill` mode which will gossip pre-merge blocks
from `era1` files into the network. By default the bridge will audit first whether
the content is available on the network and if not it will gossip it into the
network.

E.g. run latest + backfill with audit mode:
```bash
WEB3_URL="http://127.0.0.1:8548" # Replace with your provider.
./build/nimbus_portal_bridge history --latest:true --backfill:true --audit:true --era1-dir:/somedir/era1/ --web3-url:${WEB3_URL}
```
