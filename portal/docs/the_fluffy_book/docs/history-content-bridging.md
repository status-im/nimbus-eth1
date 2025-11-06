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

### Step 2: Run an EL client (Optional)

To seed the latest blocks, the Nimbus Portal bridge needs access to the EL JSON-RPC API, either through a local Ethereum client or via a web3 provider.

### Step 3: Run the Portal bridge in history mode

Build & run the Nimbus Portal bridge:
```bash
make nimbus_portal_bridge

WEB3_URL="http://127.0.0.1:8548" # Replace with your provider.
./build/nimbus_portal_bridge history --era1-dir:/somedir/era1/ --web3-url:${WEB3_URL}
```

By default the Nimbus Portal bridge runs in `--backfill-mode:regular`. This means the bridge will access era1 files to gossip block bodies and receipts into the network. There are other backfill modes available which first try to download the data from the network before gossiping it into the network, e.g. sync and audit mode.

Example: regular backfill (gossip everything):
```bash
./build/nimbus_portal_bridge history --backfill-mode:regular --era1-dir:/somedir/era1/
```

Example: audit-mode backfill (random sample & gossip missing):
```bash
./build/nimbus_portal_bridge history --backfill-mode:audit --era1-dir:/somedir/era1/
```

It is also possible to enable `--latest` mode, which means that the latest block content will be gossiped into the network.

```bash
WEB3_URL="http://127.0.0.1:8548" # Replace with your provider.
./build/nimbus_portal_bridge history --latest:true --backfill-mode:none --era1-dir:/somedir/era1/ --web3-url:${WEB3_URL}
```
