# Light Client Proxy

[![Light client proxy CI](https://github.com/status-im/nimbus-eth1/actions/workflows/lc_proxy.yml/badge.svg)](https://github.com/status-im/nimbus-eth1/actions/workflows/lc_proxy.yml)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)
[![License: Apache](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

[![Discord: Nimbus](https://img.shields.io/badge/Discord-Nimbus-blue.svg)](https://discord.gg/XRxWahP)
[![Status: #nimbus-general](https://img.shields.io/badge/Status-nimbus--general-blue.svg)](https://join.status.im/nimbus-general)

## Introduction
This folder holds the development of light client proxy. Light client proxy
uses the [consensus light client](https://github.com/ethereum/consensus-specs/tree/dev/specs/altair/light-client)
to follow the tip of the consensus chain and exposes the standard Ethereum [JSON RPC Execution API](https://github.com/ethereum/execution-apis).
The API calls are proxied to a configured web3 data provider and the provider its responses are verified
against recent consensus data provided by the light client before returning
the result to the caller.

### Build light client proxy
```bash
git clone git@github.com:status-im/nimbus-eth1.git
cd nimbus-eth1
make lc-proxy

# See available command line options
./build/lc_proxy --help
```


### Important command line options
Most of command line options have reasonable defaults. There are two options which
needs to be explicitly configured by user.

`--trusted-block-root` - option necessary to initialize the consensus light client.
The trusted block should be within the weak subjectivity period,
and its root should be from a finalized Checkpoint.

`--web3-url` - as the proxy does not have any storage, it needs to know an endpoint which
will provide all the requested data. This can either be a known full node, or
an external provider like [Alchemy](https://www.alchemy.com/).

First requirement for the external provider is that it must support the standard Ethereum JSON RPC Execution API, and specifically
it MUST also support the [eth_getProof](https://eips.ethereum.org/EIPS/eip-1186) call.
The latter is necessary to validate the provided data against the light client.

The second requirement is that data served from provider needs to be consistent with
the configured light client network. By default the light client proxy is configured
to work on mainnet. In this case, the configured provider needs to serve mainnet data.
This is verified on start-up by querying the provider its `eth_chainId` endpoint, and comparing the
received chain id with the one configured locally. If this validation fails, the light
client proxy process will quit.

[Detailed document](./docs/metamask_configuration.md) showing how to configure the proxy and pair it with
MetaMask.

### Update and rebuild light client proxy
```bash
# From the nimbus-eth1 repository
git pull
# To bring the git submodules up to date
make update

make lc-proxy
```

### Run light client proxy test suite
```bash
# From the nimbus-eth1 repository
make lc-proxy-test
```

### Windows support

Follow the steps outlined [here](../README.md#windows) to build light client proxy on Windows.


## For Developers

When working on this repository, you can run the `env.sh` script to run a
command with the right environment variables set. This means the vendored
Nim and Nim modules will be used, just as when you use `make`.

E.g.:

```bash
# start a new interactive shell with the right env vars set
./env.sh bash
```


## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](../LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](../LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.


