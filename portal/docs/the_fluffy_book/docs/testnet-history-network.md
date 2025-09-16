# Testing history network on local testnet

There is an automated test for the Portal history network integrated in the
`launch_local_testnet.sh` script.

The `test_portal_testnet` binary can be run from within this script and do a
set of actions on the nodes through the JSON-RPC API. When that is finished, all
nodes will be killed.

## Run the local testnet script with history network test

```bash
# Run the script, default start 64 nodes and run history tests
./portal/scripts/launch_local_testnet.sh --run-tests -n64
```

## Details of the `test_portal_testnet` test

Following steps are done:

  1. Nodes join the network by providing them all with one and the same
  bootstrap node at start-up.
  2. Attempt to add the ENRs of all the nodes to each node its routing table:
  This is done in order to quickly simulate a network that has all the nodes
  propagated around. The JSON-RPC `portal_historyAddEnr` is used for this.
  3. Select, at random, a node id of one of the nodes. Let every node do a
  lookup for this node id.
  This is done to validate that every node can successfully lookup a specific
  node in the DHT.
