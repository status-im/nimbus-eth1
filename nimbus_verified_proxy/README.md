# Nimbus Verified Proxy

[![Nimbus Verified Proxy CI](https://github.com/status-im/nimbus-eth1/actions/workflows/nimbus_verified_proxy.yml/badge.svg)](https://github.com/status-im/nimbus-eth1/actions/workflows/nimbus_verified_proxy.yml)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)
[![License: Apache](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

[![Discord: Nimbus](https://img.shields.io/badge/Discord-Nimbus-blue.svg)](https://discord.gg/XRxWahP)
[![Status: #nimbus-general](https://img.shields.io/badge/Status-nimbus--general-blue.svg)](https://join.status.im/nimbus-general)

The Nimbus Verified Proxy is a very efficient light client for the Ethereum
PoS network.

It exposes the standard [Ethereum JSON RPC Execution API](https://github.com/ethereum/execution-apis)
and proxies the API calls to a configured, untrusted, web3 data provider.
Responses from the web3 data provider are verified by requesting Merkle proofs
and checking them against the state hash.

The [consensus p2p light client](https://github.com/ethereum/consensus-specs/tree/dev/specs/altair/light-client)
is used to efficiently follow the tip of the consensus chain and
have access to the latest state hash.

As such the Nimbus Verified Proxy turns the untrusted web3 data provider
into a verified data source, and it can be directly used by any wallet that
relies on the Ethereum JSON RPC Execution API.


### Build the Nimbus Verified Proxy from source
```bash
# Clone the nimbus-eth1 repository
git clone https://github.com/status-im/nimbus-eth1.git
cd nimbus-eth1

# Run the build process
make nimbus_verified_proxy

# See available command line options
./build/nimbus_verified_proxy --help
```


### Run the Nimbus Verified Proxy

Three options need to be explicitly configured by the user:

* `--trusted-block-root`: The consensus light client starts syncing from a trusted block. This trusted block should be somewhat recent ([~1-2 weeks](https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/weak-subjectivity.md)) and needs to be configured each time when starting the Nimbus Verified Proxy.

* `--execution-api-url` - As the proxy does not use any storage, it needs access to an Ethereum JSON RPC endpoint to provide the requested data. This can be a regular full node, or an external web3 data provider like
[Alchemy](https://www.alchemy.com/).

    A first requirement for the web3 data provider is that it must support the standard Ethereum JSON RPC Execution API, including the [eth_getProof](https://eips.ethereum.org/EIPS/eip-1186) call.
    The latter is necessary to validate the provided data against the light client.

    A second requirement is that data served from provider needs to match with
the ```--network``` option configured for the Nimbus Verified Proxy. By default the proxy is configured to work on mainnet. Thus, the configured provider needs to serve mainnet data.
This is verified on start-up by querying the provider its `eth_chainId` endpoint, and comparing the
received chain id with the one configured locally. If this validation fails, the Nimbus Verified Proxy will quit.

> Note: Infura currently does not support the `eth_getProof` call.

* `--beacon-api-url` - URL of the consensus light client data provider (beacon node REST API). This is used to bootstrap and follow the tip of the consensus chain. Multiple URLs can be provided by repeating the option.

#### Obtaining a trusted block root

A block root may be obtained from a trusted beacon node or from a trusted provider.

* Trusted beacon node:

    The REST interface must be enabled on the trusted beacon node (`--rest --rest-port=5052` for Nimbus).

    ```sh
    curl -s "http://localhost:5052/eth/v1/beacon/headers/finalized" | \
        jq -r '.data.root'
    ```

* Trusted provider, e.g. Beaconcha.in:

    On [beaconcha.in](https://beaconcha.in), navigate to the `Epochs` section and select a recent `Finalized` epoch. Then, scroll down to the bottom of the page. If the bottom-most slot has a `Proposed` status, copy its `Root Hash`. Otherwise, for example if the bottom-most slot was `Missed`, go back and pick a different epoch.

#### Start the process
To start the proxy for Mainnet, run the following command (inserting your own trusted block root and replacing the URLs to your providers of choice):

```bash
# From the nimbus-eth1 repository
TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 # Replace this
./build/nimbus_verified_proxy \
    --network=mainnet \
    --trusted-block-root=${TRUSTED_BLOCK_ROOT} \
    --execution-api-url="wss://eth-mainnet.g.alchemy.com/v2/<ApiKey>" \
    --beacon-api-url="https://beaconstate.info" \
    --listen-url="http://127.0.0.1:8545" \
    --listen-url="ws://127.0.0.1:8546"
```

### Run with Docker

Multi-arch images are published to Docker Hub as [`statusim/nimbus-verified-proxy`](https://hub.docker.com/r/statusim/nimbus-verified-proxy).

The container's entrypoint reads its configuration from a TOML file mounted at
`/config/proxy.toml`, so you must provide one. Any option accepted on the command
line can be set in this file using its long name as the key (repeatable options
become TOML arrays).

Create a `proxy.toml`, for example:

```toml
network = "mainnet"
execution-api-url = ["wss://eth-mainnet.g.alchemy.com/v2/<ApiKey>"]
beacon-api-url = ["https://beaconstate.info"]

# Bind to 0.0.0.0 (not 127.0.0.1) so the ports are reachable from outside the container
listen-url = ["http://0.0.0.0:8545", "ws://0.0.0.0:8546"]
```

The trusted block root needs to be refreshed for every start, so it is more
convenient to pass it as an environment variable than to edit the config file
each time. Every option can also be supplied through an environment variable
named `NIMBUS_VERIFIED_PROXY_<OPTION>`, where `<OPTION>` is the upper-cased long
name with dashes replaced by underscores.

Start the container, mounting the config and passing the trusted block root via
the environment:

```bash
docker run --rm \
    -p 8545:8545 -p 8546:8546 \
    -v "$(pwd)/proxy.toml:/config/proxy.toml:ro" \
    -e NIMBUS_VERIFIED_PROXY_TRUSTED_BLOCK_ROOT=0x1234567890123456789012345678901234567890123456789012345678901234 \
    statusim/nimbus-verified-proxy
```

Configuration is resolved with the following precedence (highest first):
command-line arguments > environment variables > config file > built-in defaults.
So values passed with `-e` (or extra flags appended after the image name)
override the ones in `proxy.toml`.

### Using the Nimbus Verified Proxy with existing Wallets
The Nimbus Verified Proxy exposes the standard Ethereum JSON RPC Execution API and can thus be used
as drop-in replacement for any Wallet that relies on this API.

By doing so, it turns an untrusted web3 data provider into a verified data source.

The Nimbus Verified Proxy has been tested in combination with MetaMask.

The [MetaMask configuration page](./docs/metamask_configuration.md) explains how to configure the proxy, and how to configure MetaMask to make use of the proxy.


### Update and rebuild the Nimbus Verified Proxy
```bash
# From the nimbus-eth1 repository
git pull
# To bring the git submodules up to date
make update

make nimbus_verified_proxy
```

### Run the Nimbus Verified Proxy test suite
```bash
# From the nimbus-eth1 repository
make nimbus-verified-proxy-test
```

### Windows support

Follow the steps outlined [here](../README.md#windows) to build Nimbus Verified Proxy on Windows.


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
