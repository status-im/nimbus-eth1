# Protocol Interoperability Testing
This document shows a set of commands that can be used to test the individual
protocol messages per network (Discovery v5 and Portal networks), e.g. to test
client protocol interoperability.

Two ways are explained, the first, by keeping a node running and interacting
with it through the JSON-RPC service. The second, by running cli applications
that attempt to send 1 specific message and then shutdown.

The first is more powerful and complete, the second one might be easier to do
some quick testing.

## Run Fluffy and test protocol messages via JSON-RPC API

First build Fluffy as explained [here](./quick-start.md#build-the-fluffy-client).

Next run it with the JSON-RPC server enabled:
```bash
./build/fluffy --rpc --bootstrap-node:enr:<base64 encoding of ENR>
```

### Testing Discovery v5 Layer
Testing the Discovery v5 protocol messages:

```bash
# Ping / Pong
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"discv5_ping","params":["enr:<base64 encoding of ENR>"]}' http://localhost:8545 | jq

# FindNode / Nodes
# Extra parameter is an array of requested logarithmic distances
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"discv5_findNode","params":["enr:<base64 encoding of ENR>", [254, 255, 256]]}' http://localhost:8545 | jq

# TalkReq / TalkResp
# Extra parameters are the protocol id and the request byte string, hex encoded.
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"discv5_talkReq","params":["enr:<base64 encoding of ENR>", "", ""]}' http://localhost:8545 | jq

# Read out the discover v5 routing table contents
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"discv5_routingTableInfo","params":[]}' http://localhost:8545 | jq
```

### Testing Portal Networks Layer
Testing the Portal wire protocol messages:

```bash
# Ping / Pong
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_state_ping","params":["enr:<base64 encoding of ENR>"]}' http://localhost:8545 | jq

# FindNode / Nodes
# Extra parameter is an array of requested logarithmic distances
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_state_findNodes","params":["enr:<base64 encoding of ENR>", [254, 255, 256]]}' http://localhost:8545 | jq

# FindContent / Content
# A request with an invalid content key will not receive a response
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_state_findContent","params":["enr:<base64 encoding of ENR>", "02829bd824b016326a401d083b33d092293333a830d1c390624d3bd4e409a61a858e5dcc5517729a9170d014a6c96530d64dd8621d"]}' http://localhost:8545 | jq

# Read out the Portal state network routing table contents
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_state_routingTableInfo","params":[]}' http://localhost:8545 | jq
```

> The `portal_state_` prefix can be replaced for testing other networks such as
`portal_history_`.

## Test Discovery and Portal Wire protocol messages with cli tools

### Testing Discovery v5 Layer: dcli

```bash
# Build dcli from nim-eth vendor module
(cd vendor/nim-eth/; ../../env.sh nimble build_dcli)
```

With the `dcli` tool you can test the individual Discovery v5 protocol messages,
e.g.:

```bash
# Test Discovery Ping, should print the content of ping message
./vendor/nim-eth/eth/p2p/discoveryv5/dcli ping enr:<base64 encoding of ENR>

# Test Discovery FindNode, should print the content of the returned ENRs
# Default a distance of 256 is requested, change this with --distance argument
./vendor/nim-eth/eth/p2p/discoveryv5/dcli findnode enr:<base64 encoding of ENR>

# Test Discovery TalkReq, should print the TalkResp content
./vendor/nim-eth/eth/p2p/discoveryv5/dcli talkreq enr:<base64 encoding of ENR>
```

> Each `dcli` run will default generate a new network key and thus a new node id
and ENR.

### Testing Portal Networks Layer: portalcli

```bash
# Build portalcli
make portalcli
```

With the `portalcli` tool you can test the individual Portal wire protocol
messages, e.g.:

```bash
# Test Portal wire Ping, should print the content of ping message
./build/portalcli ping enr:<base64 encoding of ENR>

# Test Portal wire FindNode, should print the content of the returned ENRs
# Default a distance of 256 is requested, change this with --distance argument
./build/portalcli findnodes enr:<base64 encoding of ENR>

# Test Portal wire FindContent, should print the returned content
./build/portalcli findcontent enr:<base64 encoding of ENR>

# Default the history network is tested, but you can provide another protocol id
./build/portalcli ping enr:<base64 encoding of ENR> --protocol-id:0x500B
```

> Each `portalcli` run will default generate a new network key and thus a new
node id and ENR.
