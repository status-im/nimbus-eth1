# The Nimbus Portal Client Guide

The Nimbus Portal client is the Nimbus client implementation of the
[Portal network specifications](https://github.com/ethereum/portal-network-specs).

The Portal Network aims to deliver a reliable and decentralized
access to the Ethereum historical block data.

This book describes how to build, run and monitor the Nimbus Portal client, and how to
use and test its currently implemented functionality.

To quickly get your Nimbus Portal client up and running, follow the quickstart page:

  - [Quickstart for Linux / macOS users](./quick-start.md)
  - [Quickstart for Windows users](./quick-start-windows.md)
  - [Quickstart for Docker users](./quick-start-docker.md)

## Development status

The development of this client is on par with the latest Portal specifications and will continue to evolve according to the Portal specifications.

The Portal history sub-network is already operational on the Portal mainnet.

The Nimbus Portal client is default ran on the [Portal mainnet](https://github.com/ethereum/portal-network-specs/blob/master/bootnodes.md#bootnodes-mainnet) but can also be run on a (local) testnet.

### Supported sub-networks and content

- [History network](https://github.com/ethereum/portal-network-specs/blob/master/history/history-network.md): block bodies and receipts

- [Beacon network](https://github.com/ethereum/portal-network-specs/blob/e8e428c55f34893becfe936fe323608e9937956e/beacon-chain/beacon-network.md): consensus light client data and historical summaries. This network is experimental and default disabled.

### Supported functionality

- [Portal JSON-RPC API](https://github.com/ethereum/portal-network-specs/tree/e8e428c55f34893becfe936fe323608e9937956e/jsonrpc)
- [Consensus light client sync](https://github.com/ethereum/consensus-specs/blob/a09d0c321550c5411557674a981e2b444a1178c0/specs/altair/light-client/light-client.md) through content available on the Portal beacon network.

## Get in touch

Need help with anything?
Join us on [Status](https://join.status.im/nimbus-general) and [Discord](https://discord.gg/9dWwPnG).

## Donate

If you'd like to contribute to Nimbus development:

* Our donation address is [`0xDeb4A0e8d9a8dB30a9f53AF2dCc9Eb27060c6557`](https://etherscan.io/address/0xDeb4A0e8d9a8dB30a9f53AF2dCc9Eb27060c6557)
* We're also listed on [GitCoin](https://gitcoin.co/grants/137/nimbus-2)

## Disclaimer

This documentation assumes Nimbus Portal client is in its ideal state.
The project is still under heavy development.
Please submit a [Github issue](https://github.com/status-im/nimbus-eth1/issues) if you come across a problem.
