# Quick start - Windows

This page takes you through the steps of getting the Nimbus Portal node running
on the public network.

The guide assumes Windows is being used. For Linux/macOS users follow this
[tutorial](./quick-start.md).

## Steps

### Prerequisites
- Developer tools (C compiler, Make, Bash, CMake, Git 2.9.4 or newer)

If you need help installing these tools, you can consult our
[prerequisites page](./prerequisites.md).

!!! note
    To build the Nimbus Portal client on Windows, the MinGW-w64 build environment is recommended.
    The build commands in the rest of this page assume the MinGW build
    environment is used.

### Build the Nimbus Portal client
```bash
git clone https://github.com/status-im/nimbus-eth1.git
cd nimbus-eth1
mingw32-make nimbus_portal_client

# Test if binary was successfully build by running the help command.
./build/nimbus_portal_client --help
```

### Run a Nimbus Portal client on the Portal network

To accept offered block bodies and receipts, the Portal node requires access to a web3 interface. Currently, it uses a non-standard method to retrieve headers from the execution layer (EL), which is only supported by Nimbus.

```bash
# Connect to the Portal bootstrap nodes and enable the JSON-RPC APIs
# nimbus_execution_client running with rpc interface at http://127.0.0.1:8545
./build/nimbus_portal_client --rpc --web3-url:http://127.0.0.1:8545
```

The node can also operate in standalone mode (without an execution layer). In this mode, data retrieval from the network is possible, but storing new data is not supported.

```bash
# Connect to the Portal bootstrap nodes and enable the JSON-RPC APIs
./build/nimbus_portal_client --rpc
```

### Try requesting an execution layer block from the network

Requesting history content on the Portal network can be easily tested by using the `portal_historyGetContent` JSON-RPC from the [Portal JSON-RPC API](https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc).

```bash
CONTENTKEY=0x004e61bc0000000000 # Serialized content key for block body of block 12345678
# Run this command to get this block body (unverified):
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_historyGetContent","params":["'${CONTENTKEY}'"]}' http://localhost:8545
```

### Update and rebuild the Nimbus Portal client
In order to stay up to date you can pull the latest version from our master
branch. There are currently released versions tagged.

```bash
# From the nimbus-eth1 repository
git pull
# To bring the git submodules up to date
mingw32-make update

mingw32-make nimbus_portal_client
```
