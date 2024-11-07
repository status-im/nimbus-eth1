# The Nimbus Fluffy Guide

Fluffy is the Nimbus client implementation of the
[Portal network specifications](https://github.com/ethereum/portal-network-specs).

The Portal Network aims to deliver a reliable, sync-free, and decentralized
access to the Ethereum blockchain. The network can be used by a light client to
get access to Ethereum data and as such become a drop-in replacement for full
nodes by providing that data through the existing
[Ethereum JSON RPC Execution API](https://github.com/ethereum/execution-apis).

This book describes how to build, run and monitor the Fluffy client, and how to
use and test its currently implemented functionality.

To quickly get your Fluffy node up and running, follow the quickstart page:

  - [Quickstart for Linux / macOS users](./quick-start.md)
  - [Quickstart for Windows users](./quick-start-windows.md)
  - [Quickstart for Docker users](./quick-start-docker.md)

# Development status
The Portal Network is a project still in research phase. This client is thus still experimental.

The development of this client is on par with the latest Portal specifications and will continue to evolve according to the Portal specifications.

The Portal history, beacon and state sub-networks are already operational on the public Portal mainnet.

Fluffy is default ran on the [Portal mainnet](https://github.com/ethereum/portal-network-specs/blob/master/bootnodes.md#bootnodes-mainnet) but can also be run on a (local) testnet.

Supported sub-networks and content:
- [History network](https://github.com/ethereum/portal-network-specs/blob/e8e428c55f34893becfe936fe323608e9937956e/history/history-network.md): headers, blocks, and receipts.
  - Note: Canonical verification only enabled for pre-merge blocks
- [State network](https://github.com/ethereum/portal-network-specs/blob/e8e428c55f34893becfe936fe323608e9937956e/state/state-network.md): accounts and contract storage.
  - Note: The current network does not hold all nor recent state
- [Beacon network](https://github.com/ethereum/portal-network-specs/blob/e8e428c55f34893becfe936fe323608e9937956e/beacon-chain/beacon-network.md): consensus light client data and historical summaries.

Supported functionality:
- [Portal JSON-RPC API](https://github.com/ethereum/portal-network-specs/tree/e8e428c55f34893becfe936fe323608e9937956e/jsonrpc)
- [Consensus light client sync](https://github.com/ethereum/consensus-specs/blob/a09d0c321550c5411557674a981e2b444a1178c0/specs/altair/light-client/light-client.md) through content available on the Portal beacon network.
- Partial support of [Execution JSON-RPC API](https://github.com/ethereum/execution-apis):
  - web3_clientVersion
  - eth_chainId
  - eth_getBalance
  - eth_getBlockByHash
  - eth_getBlockByNumber
  - eth_getBlockTransactionCountByHash
  - eth_getCode
  - eth_getLogs (partial support: queries by blockhash)
  - eth_getProof
  - eth_getStorageAt
  - eth_getTransactionCount

## Get in touch

Need help with anything?
Join us on [Status](https://join.status.im/nimbus-general) and [Discord](https://discord.gg/9dWwPnG).

## Donate

If you'd like to contribute to Nimbus development:

* Our donation address is [`0xDeb4A0e8d9a8dB30a9f53AF2dCc9Eb27060c6557`](https://etherscan.io/address/0xDeb4A0e8d9a8dB30a9f53AF2dCc9Eb27060c6557)
* We're also listed on [GitCoin](https://gitcoin.co/grants/137/nimbus-2)

## Disclaimer

This documentation assumes Nimbus Fluffy is in its ideal state.
The project is still under heavy development.
Please submit a [Github issue](https://github.com/status-im/nimbus-eth1/issues) if you come across a problem.