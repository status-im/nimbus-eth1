# Testing beacon network on local testnet

This section explains how one can set up a local testnet together with a beacon
network bridge in order to test if all nodes can do the beacon light client sync
and stay up to date with the latest head of the chain.

To accomodate this, the `launch_local_testnet.sh` script has the option to
launch the `nimbus_portal_bridge` automatically and connect it to `node0`
of the local tesnet.

## Run the local testnet script with bridge

The `launch_local_testnet.sh` script must be launched with the
`--trusted-block-root` cli option.
The individual nodes will be started with this `trusted-block-root` and each
node will try to start sync from this block root.

Run the following command to launch the network with the `nimbus_portal_bridge`
activated for the beacon network.

```bash
TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace with trusted block root.

# Run the script, start 8 nodes + nimbus_portal_bridge
./portal/scripts/launch_local_testnet.sh -n8 --trusted-block-root ${TRUSTED_BLOCK_ROOT} --portal-bridge
```

## Run the local testnet script and launch the bridge manually

To have control over when to start or restart the `nimbus_portal_bridge` on can
also control the bridge manually, e.g. start the testnet:

```bash
TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace with trusted block root.

# Run the script, start 8 nodes
./portal/scripts/launch_local_testnet.sh -n8 --trusted-block-root ${TRUSTED_BLOCK_ROOT}
```

Next, build and run the `nimbus_portal_bridge` for the beacon network:

```bash
make nimbus_portal_bridge

# --rpc-port 10000 = default node0
# --rest-url = access to beacon node API, default http://127.0.0.1:5052
./build/nimbus_portal_bridge beacon --trusted-block-root:${TRUSTED_BLOCK_ROOT} --rest-url:http://127.0.0.1:5052 --backfill-amount:128 --portal-rpc-url:http://127.0.0.1:10000
```
