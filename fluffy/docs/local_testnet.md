# Using the local testnet script
There is a local testnet script in `./fluffy/scripts/` folder that allows you
to start `n` amount of nodes and then run several actions on them through
the JSON-RPC API.

## Run the local testnet script

```bash
# Run the script
./fluffy/scripts/launch_local_testnet.sh
# Run the script with 128 nodes
./fluffy/scripts/launch_local_testnet.sh -n 128

# See the script help
./fluffy/scripts/launch_local_testnet.sh --help
```

The nodes will be started and all use node 0 as bootstrap node.
Default, the `test_portal_testnet` binary will be run and do a set of actions
on the nodes through the JSON-RPC API. When that is finished, all nodes will be
killed.

To run the nodes without testing and keep them alive for manual testing:
```bash
./fluffy/scripts/launch_local_testnet.sh --enable-htop
```

## Test flow of the local testnet

Following testing steps are done for the Discovery v5 network and for the Portal
networks:
  1. Attempt to add the ENRs of all the nodes to each node its routing table:
  This is to quickly simulate a network that has all the nodes propagated
  around.
  2. Select at random a node id of one of the nodes. Let every node do a lookup
  for this node id.

For the Portal history network a content lookup test is done:
  1. Node 0 stores `n` amount of block headers. Each block header is offered
  as content to `x` amount of nodes. The content should get propagated through
  the network via neighborhood gossip.
  2. For each block header hash, an `eth_getBlockByHash` JSON-RPC request is done
  to each node. A node will either load this from its own database or do a
  content lookup and retrieve it from the network.
