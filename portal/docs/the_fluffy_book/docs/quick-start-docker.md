# Quick start - Docker

This page takes you through the steps of getting the Fluffy Portal node running
on the public network by use of the [public Docker image](https://hub.docker.com/r/statusim/nimbus-fluffy/tags).

The Docker image gets rebuild from latest master every night and only `amd64` is supported currently.

## Steps

### Prerequisites
- [Docker](https://www.docker.com/)

### Use the Docker image to run a Fluffy client on the Portal network

```bash
# Connect to the Portal bootstrap nodes and enable the JSON-RPC APIs.
docker container run -p 8545:8545 statusim/nimbus-fluffy:amd64-master-latest --rpc --rpc-address:0.0.0.0
```
!!! note
    Port 8545 is published and `rpc-address` is set to the `ANY` address in this command to allow access to the JSON-RPC API from outside the Docker image. You might want to adjust that depending on the use case & security model.
    It is also recommended to use a mounted volume for Fluffy's `--data-dir` in case of a long-running container.

### Try requesting an execution layer block from the network

Requesting history content on the Portal network can be easily tested by using the `eth_getBlockByHash` JSON-RPC from the [execution JSON-RPC API](https://ethereum.github.io/execution-apis/api-documentation/).

```bash
# Get the hash of a block from your favorite block explorer, e.g.:
BLOCKHASH=0x55b11b918355b1ef9c5db810302ebad0bf2544255b530cdce90674d5887bb286 # Replace this to the block hash of your choice
# Run this command to get the block:
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"eth_getBlockByHash","params":["'${BLOCKHASH}'", true]}' http://localhost:8545
```
