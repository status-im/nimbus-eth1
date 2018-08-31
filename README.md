# Nimbus: an Ethereum 2.0 Sharding Client for Resource-Restricted Devices

[![Build Status (Travis)](https://img.shields.io/travis/status-im/nimbus/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/status-im/nimbus)
[![Windows build status (Appveyor)](https://img.shields.io/appveyor/ci/jarradh/nimbus/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/jarradh/nimbus)[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

Join the Status community chats:
[![Gitter: #status-im/nimbus](https://img.shields.io/badge/gitter-status--im%2Fnimbus-orange.svg)](https://gitter.im/status-im/nimbus)
[![Riot: #dev-status](https://img.shields.io/badge/riot-%23dev--status%3Astatus.im-orange.svg)](https://chat.status.im/#/room/#dev-status:status.im)
[![Riot: #nimbus](https://img.shields.io/badge/riot-%23nimbus%3Astatus.im-orange.svg)](https://chat.status.im/#/room/#nimbus:status.im)


## Rationale
[Nimbus: an Ethereum 2.0 Sharding Client](https://github.com/status-im/nimbus/blob/master/doc/Nimbus%20-%20An%20Ethereum%202.0%20Sharding%20Client_xt.md)

## Building & Testing

### Prerequisites

* A recent version of Nim
  * We use the version in the [Status fork](https://github.com/status-im/Nim)
  * Normally, this is the latest released version of Nim but it may also include custom patches
  * Follow the Nim installation instructions or use [choosenim](https://github.com/dom96/choosenim) to manage your Nim versions
* A recent version of Facebook's [RocksDB](https://github.com/facebook/rocksdb/)
  * Compile [from source](https://github.com/facebook/rocksdb/blob/master/INSTALL.md) or use the package manager of your OS

### Obtaining the prerequisites through the Nix package manager

Users of the [Nix package manager](https://nixos.org/nix/download.html) can install all prerequisites simply by running:

``` bash
nix-shell nimbus.nix
```

### Build

We use [Nimble](https://github.com/nim-lang/nimble) to manage dependencies and run tests.

To build and run test suite:
```bash
nimble test
```

Based on our config, Nimble will write binaries to `build/` - you can do this manually also, as in the following examples:

Run example:
```bash
mkdir -p build
nim c -o:build/decompile_smart_contract -r examples/decompile_smart_contract.nim
```

Run Ethereum [JSON-based VM tests](https://github.com/ethereum/tests/):
```
mkdir -p build
nim c -o:build/test_vm_json -r tests/test_vm_json.nim
```

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

Licensed under one of the following:

 * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
