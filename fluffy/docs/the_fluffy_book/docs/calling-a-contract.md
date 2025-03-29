# Calling a contract on the Portal network

Once you have a Fluffy node running and [connected to the network](./connect-to-portal.md) with
the JSON-RPC interface enabled, then you can call contracts using the `eth_call` JSON-RPC method
which should be enabled by default.

Note that `eth_call` in Fluffy requires both the history network, state network and the `eth`
rpc api to be enabled. These should be enabled by default already but you can also manually
enable these by running:

```bash
./build/fluffy --rpc --portal-subnetworks=history,state --rpc-api=eth
```

Here is an example which calls one of the earliest contracts deployed on Ethereum, which allows
you to write "graffiti" on the chain:

```bash
curl -s -X POST -H 'Content-Type: application/json' -d '{
    "jsonrpc": "2.0",
    "method": "eth_call",
    "id": 1,
    "params": [
        {
            "to": "0x6e38A457C722C6011B2dfa06d49240e797844d66",
            "input": "0xa888c2cd0000000000000000000000000000000000000000000000000000000000000007"
        },
        "0xF4240"
    ]
}' http://localhost:8545
```

Fluffy is able to call mainnet smart contracts without having to run a full execution client and
without even having the state data stored locally.

It does this by first fetching the bytecode of the contract being called from the portal state network
and then fetching the required accounts and storage slots from the network on demand while the
transaction is executing. We use the Nimbus in memory EVM for this which is configured to fetch the data
from the portal network instead of from a local database as is usually the case for a full node.

We also make use of certain optimizations to speed up the call such as caching of recently fetched
content, and concurrent state downloads (where possible) but even with these improvements the response
time may be slower compared to when using a regular full node or RPC provider due to the network
latency of fetching the state from the portal network.

!!! note
    The portal state network is still in active development and the historical state data is not yet
    available for the full Ethereum history. For this reason some JSON-RPC calls may fail if the data
    is not yet seeded into the network.
