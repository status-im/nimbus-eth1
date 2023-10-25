# Testing beacon network on local testnet

This section explains how one can set up a local testnet together with a beacon
network bridge in order to test if all nodes can do the beacon light client sync
and stay up to date with the latest head of the chain.

To accomodate this, the `launch_local_testnet.sh` script has the option to
launch the Fluffy `beacon_chain_bridge` automatically and connect it to `node0`
of the local tesnet.

## Run the local testnet script with bridge

The `launch_local_testnet.sh` script must be launched with the
`--trusted-block-root` cli option.
The individual nodes will be started with this `trusted-block-root` and each
node will try to start sync from this block root.

Run the following command to launch the network with the `beacon_chain_bridge`
activated.

```bash
TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace with trusted block root.

# Run the script, start 8 nodes + beacon_chain_bridge
./fluffy/scripts/launch_local_testnet.sh -n8 --trusted-block-root ${TRUSTED_BLOCK_ROOT} --beacon-chain-bridge
```

## Run the local testnet script and launch the bridge manually

To have control over when to start or restart the `beacon_chain_bridge` on can
also control the bridge manually, e.g. start the testnet:

```bash
TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace with trusted block root.

# Run the script, start 8 nodes
./fluffy/scripts/launch_local_testnet.sh -n8 --trusted-block-root ${TRUSTED_BLOCK_ROOT}
```

Next, build and run the `beacon_chain_bridge`

```bash
make beacon_chain_bridge

# --rpc-port 10000 = default node0
# --rest-url = access to beacon node API, default http://127.0.0.1:5052
./build/beacon_chain_bridge --trusted-block-root:${TRUSTED_BLOCK_ROOT} --rest-url:http://127.0.0.1:5052 --backfill-amount:128 --rpc-port:10000
```
