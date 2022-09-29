# Light Client Proxy

[![Light client proxy CI](https://github.com/status-im/nimbus-eth1/actions/workflows/lc_proxy.yml/badge.svg)](https://github.com/status-im/nimbus-eth1/actions/workflows/lc_proxy.yml)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)
[![License: Apache](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

[![Discord: Nimbus](https://img.shields.io/badge/Discord-Nimbus-blue.svg)](https://discord.gg/XRxWahP)
[![Status: #nimbus-general](https://img.shields.io/badge/Status-nimbus--general-blue.svg)](https://join.status.im/nimbus-general)

## Introduction
This folder holds the development of light client proxy. Light client proxy
uses [consensus light client](https://github.com/ethereum/consensus-specs/tree/dev/specs/altair/light-client)
to follow the tip of consensus chain and exposes typical ethereum json rpc api.
Rpc calls are proxied to configured web3 data provider, then responses are verified
against recent known consensus data provided by light client before returning
result to the caller.

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

`--trusted-block-root` - option necessary to initialize light client.
The trusted block should be within the weak subjectivity period,
and its root should be from a finalized Checkpoint.

`--web3-url` - as proxy does not have any storage, it does need to know endpoint which
will provide all requested data. It can be either some known full node, or
external provider like [alchemy](https://www.alchemy.com/).

First requirement for external provider is that not only it must support standard ethereum json rpc api,
it also must support [eth_getProof](https://eips.ethereum.org/EIPS/eip-1186) endpoint
which is necessary to validate provided data against light client.

Second requirement is that data served from provider need to be consistent with
configured light client network. By default light client proxy is configured
to work on mainnet. In this case, configured provider needs to serve mainnet data.
This is verified on start up by querying provider `eth_chainId` endpoint, and comparing
received chain id with the one configured locally. If this validation fails, light
client proxy process will quit.

Detailed document showing how to configure proxy and pair it with metamask
[metamask](./docs/metamask_configuration.md).

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


