# MetaMask configuration with Alchemy provider

This document explains how to configure the proxy, and how to configure MetaMask
to make use of the proxy.

### 1. Building the Nimbus Verified Proxy

First build the Nimbus Verified Proxy as explained [here](../README.md#build-the-nimbus-verified-proxy-from-source).

### 2. Configuring and running the Nimbus Verified Proxy

To start the proxy for Mainnet, run the following command (inserting your own `TRUSTED_BLOCK_ROOT` and Alchemy `API_KEY`):


```bash
# From the nimbus-eth1 repository
TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace this
API_KEY=abcd # Replace this
./build/nimbus_verified_proxy \
    --network=mainnet \
    --trusted-block-root=${TRUSTED_BLOCK_ROOT} \
    --execution-api-url="wss://eth-mainnet.g.alchemy.com/v2/${API_KEY}" \
    --beacon-api-url="https://beaconstate.info"
```


After startup, the Nimbus Verified Proxy will start looking for suitable peers in the network,
i.e peers which serve consensus light client data, and will then start syncing.
During syncing most of the RPC endpoints will be inactive
and will fail to respond to queries. This happens because the proxy cannot verify responses
from the data provider until the consensus light client is in sync with the consensus chain.

When the consensus light client is in sync, the following line should be visible in the logs:

```bash
NOT 2022-09-29 10:06:15.974+02:00 New LC optimistic block                    opt=81de61ec:3994230 wallSlot=3994231
```

After receiving the first optimistic block, the proxy is ready to be used with MetaMask.

### 3. Configuring MetaMask extension to use a custom network

To add custom network in MetaMask browser extension:
1. Go to MetaMask `settings`.
2. In `settings`, go to `networks` tab.
3. Click on the `Add a network` button.
4. Click on `Add a network manually`.
5. Type a Network name of choice, e.g. "Trusted Mainnet".
The `New RPC URL` field must be configured to point to the HTTP server of the proxy. In this
example it will be `http://127.0.0.1:8545`. The `Chain ID` field must be set to the chain id of
the network used by the proxy. The chain id for Mainnet is `1`.

If everything went smooth there should be a new network in `Networks` drop down menu.

After switching to this network it should be possible to create new accounts, and
perform transfers between them.

> Note: Currently, adding a custom network with a chain id which already exists in the MetaMask
configuration will be highlighted as an error. This should be ignored
as this should be rather a warning, and is a known [bug](https://github.com/MetaMask/metamask-extension/issues/13249) in MetaMask.
