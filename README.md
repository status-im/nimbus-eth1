# Nimbus: an Ethereum 2.0 Sharding Client for Resource-Restricted Devices

[![Build Status (Travis)](https://img.shields.io/travis/status-im/nimbus/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/status-im/nimbus)
[![Windows build status (Appveyor)](https://img.shields.io/appveyor/ci/jarradh/nimbus/master.svg?label=Windows "Windows build status (Appveyor)")](https://ci.appveyor.com/project/jarradh/nimbus)[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

Join the Status community chats:
[![Riot: #dev-status](https://img.shields.io/badge/riot-%23dev--status%3Astatus.im-orange.svg)](https://chat.status.im/#/room/#dev-status:status.im)
[![Riot: #nimbus](https://img.shields.io/badge/riot-%23nimbus%3Astatus.im-orange.svg)](https://chat.status.im/#/room/#nimbus:status.im)


## Rationale
[Nimbus: an Ethereum 2.0 Sharding Client](https://github.com/status-im/nimbus/blob/master/doc/Nimbus%20-%20An%20Ethereum%202.0%20Sharding%20Client_xt.md)

## Building & Testing

### Prerequisites

Please install a recent version of Facebook's RocksDB following the instructions here:

https://github.com/facebook/rocksdb/blob/master/INSTALL.md

Currently Nimbus requires the latest development version of the Nim programming language. Follow the [installation steps](https://github.com/nim-lang/Nim) or use [choosenim](https://github.com/dom96/choosenim).

### Obtaining the prerequisites through the Nix package manager

Users of the [Nix package manager](https://nixos.org/nix/download.html) can install all prerequisites simply by running:

``` bash
nix-shell nimbus.nix
```

### Build

You can build the package and run the tests using `nimble test`. You can run the example using `nim compile --run examples/decompile_smart_contract.nim`.

You can run the official Ethereum JSON tests for the EVM this way:

create a `./build` directory with `mkdir build` in your cloned repository.

Run

```
nim c -r --nimcache:nimcache -o:build/test tests/test_vm_json.nim
```

The executable will be put in `build`, and nim compilation cache will use `nimcache`.

## License

Licensed under one of the following:

 * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
 * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
