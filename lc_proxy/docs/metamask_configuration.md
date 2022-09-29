# Metamask configuration with Alchemy provider

This documents shows how to bulild and start light client proxy on goerli
network and pair it with metamask browser extension

### 1. Build light client proxy

First build light client proxy as explained [here](../README.md#Build-light-client-proxy).

### 2. Configuring and running light client proxy

To run binary built in prvious step with goerli config and using alchemy data
provider run:


```bash
# From the nimbus-eth1 repository
./build/lc_proxy --trusted-block-root:TrustedBloockRoot --web3-url="wss://eth-goerli.g.alchemy.com/v2/ApiKey" --network=goerli
```

`ApiKey` - needs to be personal key assigned by alchemy

`TrustedBloockRoot` - need to be trusted block root, from which light client will
start synchronization.

This command also starts http server with address `http://127.0.0.1:8545` to listen
for incoming json rpc request.

After startup, light client will start looking for suitable peers in the network
i.e peers which serves light client data and then start syncing with the network.
Until light client syncs with the network, most of the rpc endpoints will be inactive
and will fail to respond to queries. This happens because until light client syncs up
with the network, light client proxy can't verify responses from data provider.

When light client sync up with the network following line should be visible in the
logs:

```bash
NOT 2022-09-29 10:06:15.974+02:00 New LC optimistic block                    opt=81de61ec:3994230 wallSlot=3994231
```

After receiving first optimistic block, proxy is ready to be used with metamask

### 3. Configuring metamask extension to use custom network

To add custom network in metamask browser extension:
1. Go to `settings`
2. In `settings`, go to `networks` tab
3. There should be `Add a network` button.
4. Most important fields when adding new network are `New RPC URL` and `Chain ID`
`New RPC URL` should be configured to point to http server started with proxy, in this
example it will be `http://127.0.0.1:8545`. `Chain ID` should be set to chain if of
the network used by proxy, so for goerli it will be equal to `5`

If everyting went smooth there should be new network in `Networks` drop down menu.

After switching to this network it should be possible to create new accounts, and
perform transfers between them

NOTE: Currently when adding custom network with the chain id which is already existis in metamask
configuration, metamask will highlight this as an error. This should be ignored
as this is really a warning, and it is known bug in metamask.
