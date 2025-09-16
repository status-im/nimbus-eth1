# Quick start - Docker

This page takes you through the steps of getting the Nimbus Portal client running
on the public network by use of the [public Docker image](https://hub.docker.com/r/statusim/nimbus-portal-client/tags).

The Docker image gets rebuild from latest master every night and only `amd64` is supported currently.

## Steps

### Prerequisites
- [Docker](https://www.docker.com/)

### Use the Docker image to run the Nimbus Portal client on the Portal network

```bash
# Connect to the Portal bootstrap nodes and enable the JSON-RPC APIs.
docker container run -p 8545:8545 statusim/nimbus-portal-client:amd64-master-latest --rpc --rpc-address:0.0.0.0
```
!!! note
    Port 8545 is published and `rpc-address` is set to the `ANY` address in this command to allow access to the JSON-RPC API from outside the Docker image. You might want to adjust that depending on the use case & security model.
    It is also recommended to use a mounted volume for `nimbus_portal_client`'s `--data-dir` in case of a long-running container.

### Try requesting an execution layer block from the network

Requesting history content on the Portal network can be easily tested by using the `portal_historyGetContent` JSON-RPC from the [Portal JSON-RPC API](https://github.com/ethereum/portal-network-specs/tree/master/jsonrpc).

```bash
CONTENTKEY=0x004e61bc0000000000 # Serialized content key for block body of block 12345678
# Run this command to get this block body (unverified):
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"portal_historyGetContent","params":["'${CONTENTKEY}'"]}' http://localhost:8545
```
