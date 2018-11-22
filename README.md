# Nimbus: an Ethereum 2.0 Sharding Client for Resource-Restricted Devices

[![Build Status (Travis)](https://img.shields.io/travis/status-im/nimbus/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/status-im/nimbus)
[![Windows build status (Appveyor)](https://img.shields.io/appveyor/ci/nimbus/nimbus/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/nimbus/nimbus)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

Join the Status community chats:
[![Gitter: #status-im/nimbus](https://img.shields.io/badge/gitter-status--im%2Fnimbus-orange.svg)](https://gitter.im/status-im/nimbus)
[![Riot: #nimbus](https://img.shields.io/badge/riot-%23nimbus%3Astatus.im-orange.svg)](https://chat.status.im/#/room/#nimbus:status.im)
[![Riot: #dev-status](https://img.shields.io/badge/riot-%23dev--status%3Astatus.im-orange.svg)](https://chat.status.im/#/room/#dev-status:status.im)


## Rationale
[Nimbus: an Ethereum 2.0 Sharding Client](https://our.status.im/nimbus-for-newbies/). The code in this repository is currently focusing on Ethereum 1.0 feature parity, while all 2.0 research and development is happening in parallel in [nim-beacon-chain](https://github.com/status-im/nim-beacon-chain). The two repositories are expected to merge in Q1 2019.

## Building & Testing

### Prerequisites

* A recent version of Nim
  * We use the version in the [Status fork](https://github.com/status-im/Nim)
  * Follow the Nim installation instructions or use [choosenim](https://github.com/dom96/choosenim) to manage your Nim versions
* A recent version of Facebook's [RocksDB](https://github.com/facebook/rocksdb/)
  * Compile [from source](https://github.com/facebook/rocksdb/blob/master/INSTALL.md) or use the package manager of your OS; for example, [Debian](https://packages.debian.org/search?keywords=librocksdb-dev&searchon=names&exact=1&suite=all&section=all), [Ubuntu](https://packages.ubuntu.com/search?keywords=librocksdb-dev&searchon=names&exact=1&suite=all&section=all), and [Fedora](https://apps.fedoraproject.org/packages/rocksdb) have working RocksDB packages

#### Obtaining the prerequisites through the Nix package manager

Users of the [Nix package manager](https://nixos.org/nix/download.html) can install all prerequisites simply by running:

``` bash
nix-shell nimbus.nix
```

### Build & Install

We use [Nimble](https://github.com/nim-lang/nimble) to manage dependencies and run tests.

To build and install Nimbus in your home folder, just execute:

```bash
nimble install
```

After a succesful installation, running `nimbus --help` will provide you with a list of
the available command-line options. To start syncing with mainnet, just execute `nimbus`
without any parameters.

To execute all tests:
```bash
nimble test
```

Our Wiki provides additional helpful information for [debugging individual test cases][1]
and for [pairing Nimbus with a locally running copy of Geth][2].

[1]: https://github.com/status-im/nimbus/wiki/Understanding-and-debugging-Nimbus-EVM-JSON-tests
[2]: https://github.com/status-im/nimbus/wiki/Debugging-state-reconstruction

#### Troubleshooting

Sometimes, the build will fail even though the latest CI is green - here are a few tips to handle this:

* Wrong Nim version
  * We depend on many bleeding-edge features - Nim regressions often happen
  * Use the [Status fork](https://github.com/status-im/Nim) of Nim
* Wrong versions of dependencies
  * nimble dependency tracking often breaks due to its global registry
  * wipe the nimble folder and try again
* C compile or link fails
  * Nim compile cache is pretty buggy and sometimes will fail to recompile
  * wipe your nimcache folder

## License

Licensed under both of the following:

 * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
