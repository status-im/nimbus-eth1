# Quick start - Linux/macOS

This page takes you through the steps of getting the Fluffy Portal node running
on the public network.

The guide assumes Linux or macOS is being used. For Windows users follow this
[tutorial](./quick-start-windows.md).

## Steps

### Prerequisites
- Developer tools (C compiler, Make, Bash, CMake, Git 2.9.4 or newer)

If you need help installing these tools, you can consult our
[prerequisites page](./prerequisites.md).

### Build the Fluffy client
```bash
git clone https://github.com/status-im/nimbus-eth1.git
cd nimbus-eth1
make fluffy

# Test if binary was successfully build by running the help command.
./build/fluffy --help
```

### Run a Fluffy client on the Portal network

```bash
# Connect to the Portal bootstrap nodes and enable the JSON-RPC APIs
./build/fluffy --rpc
```

### Try requesting an execution layer block from the network

Requesting history content on the Portal network can be easily tested by using the `eth_getBlockByHash` JSON-RPC from the [execution JSON-RPC API](https://ethereum.github.io/execution-apis/api-documentation/).

```bash
# Get the hash of a block from your favorite block explorer, e.g.:
BLOCKHASH=0x55b11b918355b1ef9c5db810302ebad0bf2544255b530cdce90674d5887bb286 # Replace this to the block hash of your choice
# Run this command to get the block:
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"eth_getBlockByHash","params":["'${BLOCKHASH}'", true]}' http://localhost:8545
```

### Update and rebuild the Fluffy client
In order to stay up to date you can pull the latest version from our master
branch. There are currently released versions tagged.

```bash
# From the nimbus-eth1 repository
git pull
# To bring the git submodules up to date
make update

make fluffy
```
