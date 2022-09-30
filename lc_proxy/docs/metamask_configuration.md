# MetaMask configuration with Alchemy provider

This documents shows how to build and start light client proxy on Goerli
network and pair it with the MetaMask browser extension.

### 1. Build light client proxy

First build light client proxy as explained [here](../README.md#Build-light-client-proxy).

### 2. Configuring and running light client proxy

To run the binary built in previous step with Goerli config and using Alchemy data
provider, run:


```bash
# From the nimbus-eth1 repository
./build/lc_proxy --trusted-block-root:TrustedBlockRoot --web3-url="wss://eth-goerli.g.alchemy.com/v2/ApiKey" --network=goerli
```

`ApiKey`: personal API key assigned by Alchemy

`TrustedBlockRoot`: Trusted block root, from which the consensus light client will
start synchronization

This command also starts an HTTP server with address `http://127.0.0.1:8545` to listen
for incoming JSON RPC requests.

After startup, light client will start looking for suitable peers in the network,
i.e peers which serve light client data, and will then start syncing.
During syncing most of the RPC endpoints will be inactive
and will fail to respond to queries. This happens because the light client proxy can't verify responses
from the data provider until the consensus light client is in sync with the consensus chain.

When the light client is in sync, the following line should be visible in the logs:

```bash
NOT 2022-09-29 10:06:15.974+02:00 New LC optimistic block                    opt=81de61ec:3994230 wallSlot=3994231
```

After receiving the first optimistic block, the proxy is ready to be used with MetaMask.

### 3. Configuring MetaMask extension to use custom network

To add custom network in MetaMask browser extension:
1. Go to `settings`
2. In `settings`, go to `networks` tab
3. Click on the `Add a network` button.
4. The most important fields when adding a new network are `New RPC URL` and `Chain ID`.
`New RPC URL` should be configured to point to the HTTP server started with proxy. In this
example it will be `http://127.0.0.1:8545`. `Chain ID` should be set to the chain id of
the network used by proxy. The chain id for Goerli is `5`.

If everyting went smooth there should be new network in `Networks` drop down menu.

After switching to this network it should be possible to create new accounts, and
perform transfers between them.

NOTE: Currently when adding a custom network with a chain id which already exists in the MetaMask
configuration, MetaMask will highlight this as an error. This should be ignored
as this is really a warning, and it is a known [bug](https://github.com/MetaMask/metamask-extension/issues/13249)
in MetaMask.
