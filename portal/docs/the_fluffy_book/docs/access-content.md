# Access content on the Portal network

Once you have a Portal node [connected to the network](./connect-to-portal.md) with
the JSON-RPC interface enabled, then you can access the content available on
the Portal network.

You can for example access execution layer blocks through the standardized
Portal JSON-RPC call `portal_historyGetContent`:

```bash
CONTENTKEY=0x004e61bc0000000000 # Serialized content key for block body of block 12345678
# Run this command to get this block body (unverified):
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_historyGetContent","params":["'${CONTENTKEY}'"]}' http://localhost:8545
```
