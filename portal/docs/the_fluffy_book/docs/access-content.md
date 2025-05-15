# Access content on the Portal network

Once you have a Fluffy node [connected to network](./connect-to-portal.md) with
the JSON-RPC interface enabled, then you can access the content available on
the Portal network.

You can for example access execution layer blocks through the standardized
JSON-RPC call `eth_getBlockByHash`:

```bash
# Get the hash of a block from your favorite block explorer, e.g.:
BLOCKHASH=0x55b11b918355b1ef9c5db810302ebad0bf2544255b530cdce90674d5887bb286 # Replace this to the block hash of your choice
# Run this command to get this block:
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"eth_getBlockByHash","params":["'${BLOCKHASH}'", true]}' http://localhost:8545
```

You can also use our `blockwalk` tool to walk down the blocks one by one:
```bash
make blockwalk

BLOCKHASH=0x55b11b918355b1ef9c5db810302ebad0bf2544255b530cdce90674d5887bb286 # Replace this to the block hash of your choice
./build/blockwalk --block-hash:${BLOCKHASH}
```


<!-- TODO: Give some examples of direct portal content access with the Portal API
and about recently audited data at http://glados.ethportal.net/content/ -->