# Running a local testnet

To easily start a local testnet you can use the `launch_local_testnet.sh`
script.
This script allows you to start `n` amount of nodes and then run several actions
on them through the JSON-RPC API.

## Run the local testnet script

```bash
# Run the script, default start 3 nodes
./fluffy/scripts/launch_local_testnet.sh
# Run the script with 16 nodes
./fluffy/scripts/launch_local_testnet.sh -n 16

# See the script help
./fluffy/scripts/launch_local_testnet.sh --help
```

The nodes will be started and all nodes will use `node0` as bootstrap node.

The `data-dir`s and logs of each node can be found in `./local_testnet_data/`.

You can manually start extra nodes that connect to the network by providing
any of the running nodes their ENR.

E.g. to manually add a Fluffy node to the local testnet run:

```bash
./build/fluffy --rpc --network:none --udp-port:9010 --nat:extip:127.0.0.1 --bootstrap-node:`cat ./local_testnet_data/node0/fluffy_node.enr`
```
