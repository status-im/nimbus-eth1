# Bridging content into the Portal beacon network

## Seeding from content bridges

Run a Nimbus Portal client with the JSON-RPC API enabled.

```bash
./build/nimbus_portal_client --rpc
```

Build & run the `nimbus_portal_bridge` for the beacon network:
```bash
make nimbus_portal_bridge

TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace with trusted block root.
# --rest-url = access to beacon node API, default http://127.0.0.1:5052
# --portal-rpc=url = access to the Portal node API, default http://127.0.0.1:8545
./build/nimbus_portal_bridge beacon --trusted-block-root:${TRUSTED_BLOCK_ROOT} --rest-url:http://127.0.0.1:5052 --portal-rpc-url:http://127.0.0.1:8545
```

The `nimbus_portal_bridge` will connect to Nimbus Portal client over the JSON-RPC
interface and start gossiping an `LightClientBootstrap` for
given trusted block root and gossip backfill `LightClientUpdate`s.

Next, it will gossip a new `LightClientOptimisticUpdate`,
`LightClientFinalityUpdate` and `LightClientUpdate` as they become available.
