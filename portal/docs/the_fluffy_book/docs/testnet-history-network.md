# Testing history network on local testnet

There is an automated test for the Portal history network integrated in the
`launch_local_testnet.sh` script.

The `test_portal_testnet` binary can be run from within this script and do a
set of actions on the nodes through the JSON-RPC API. When that is finished, all
nodes will be killed.

## Run the local testnet script with history network test

```bash
# Run the script, default start 64 nodes and run history tests
./fluffy/scripts/launch_local_testnet.sh --run-tests
```

## Details of the `test_portal_testnet` test

### Initial set-up

Following initial steps are done to set up the Discovery v5 network and the
Portal networks:

  1. Nodes join the network by providing them all with one and the same
  bootstrap node at start-up.
  2. Attempt to add the ENRs of all the nodes to each node its routing table:
  This is done in order to quickly simulate a network that has all the nodes
  propagated around. The JSON-RPC `portal_historyAddEnr` is used for this.
  3. Select, at random, a node id of one of the nodes. Let every node do a
  lookup for this node id.
  This is done to validate that every node can successfully lookup a specific
  node in the DHT.

### Data propagation test

How the content gets shared around and tested:

  1. First one node (the bootstrap node) will get triggered by a JSON-RPC call
  to load a data file that contains `n` amount of blocks (
  `[header, [txs, uncles], receipts]`), and to propagate these over the network.
  This is done by doing offer request to `x` (= 8) neighbours to that content
  its id. This is practically the neighborhood gossip at work, but then
  initiated on the read of each block in the provided data file.
  2. Next, the nodes that accepted and received the content will do the same
  neighborhood gossip mechanism with the received content. And so on, until no
  node accepts any offers any more and the gossip dies out. This should
  propagate the content to (all) the neighbours of that content. TODO: This
  depends on the radii set and the amount of nodes in the network. More starter
  nodes are required to propagate with nodes at lower radii.
  3. The test binary will then read the same data file and, for each block hash,
  an `eth_getBlockByHash` JSON-RPC request is done to each node. A node will
  either load the block header or body from its own database or do a content
  lookup and retrieve them from the network, this depends on its own node id and
  radius.
  Following checks are currently done on the response:
     * Check if the block header and body content was found.
     * The hash in returned data of eth_getBlockByHash matches the requested
     one.
     * In case the block has transactions, check the block hash in the
     transaction object.
