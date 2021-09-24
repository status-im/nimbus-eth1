# Fluffy: The Nimbus Portal Network Client

[![fluffy CI](https://github.com/status-im/nimbus-eth1/actions/workflows/fluffy.yml/badge.svg)](https://github.com/status-im/nimbus-eth1/actions/workflows/fluffy.yml)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)
[![License: Apache](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

[![Discord: Nimbus](https://img.shields.io/badge/Discord-Nimbus-blue.svg)](https://discord.gg/XRxWahP)
[![Status: #nimbus-general](https://img.shields.io/badge/Status-nimbus--general-blue.svg)](https://join.status.im/nimbus-general)

## Introduction
This folder holds the development of the Nimbus client implementation supporting
the Portal Network: fluffy. The Portal Network is a project still heavily in
research phase and fully in flux. This client is thus still highly experimental.

Current status of specifications can be found in the
[portal-network-specs repository](https://github.com/ethereum/portal-network-specs/blob/master/portal-network.md).


## Development Updates

To keep up to date with changes and development progress, follow the
[Nimbus blog](https://our.status.im/tag/nimbus/).

## How to Build & Run

### Prerequisites
- GNU Make, Bash and the usual POSIX utilities. Git 2.9.4 or newer.

### Build fluffy client
```bash
git clone git@github.com:status-im/nimbus-eth1.git
cd nimbus-eth1
make fluffy

# See available command line options
./build/fluffy --help

# Example command: Run the client and connect to a bootnode.
./build/fluffy --log-level:debug --bootnode:enr:<base64 encoding of ENR>
```

### Update and rebuild fluffy client
```bash
# From the nimbus-eth1 repository
git pull
# To bring the git submodules up to date
make update

make fluffy
```

### Run fluffy test suite
```bash
# From the nimbus-eth1 repository
make fluffy-test
```

### Windows support

Follow the steps outlined [here](../README.md#windows) to build fluffy on Windows.


## For Developers

When working on this repository, you can run the `env.sh` script to run a
command with the right environment variables set. This means the vendored
Nim and Nim modules will be used, just as when you use `make`.

E.g.:

```bash
# start a new interactive shell with the right env vars set
./env.sh bash
```

More [development tips](../README.md#devel-tips)
can be found on the general nimbus-eth1 readme.

The code follows the
[Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](../LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](../LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.
