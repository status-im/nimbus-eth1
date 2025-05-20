# Build from source

Building the Nimbus Portal client from source ensures that all hardware-specific optimizations are
turned on.
The build process itself is simple and fully automated, but may take a few minutes.

!!! note "Nim"
    The Nimbus Portal client is written in the [Nim](https://nim-lang.org) programming language.
    The correct version will automatically be downloaded as part of the build process!

## Prerequisites

Make sure you have all needed [prerequisites](./prerequisites.md).

## Building the Nimbus Portal client

### 1. Clone the `nimbus-eth1` repository

```sh
git clone https://github.com/status-im/nimbus-eth1.git
cd nimbus-eth1
```

### 2. Run the Nimbus Portal client build process

To build the Nimbus Portal client and its dependencies, run:

```sh
make nimbus_portal_client
```

This step can take several minutes.
After it has finished, you can check if the build was successful by running:

```sh
# See available command line options
./build/nimbus_portal_client --help
```

If you see the command-line options, your installation was successful!
Otherwise, don't hesitate to reach out to us in the `#nimbus-portal` channel of
[our discord](https://discord.gg/j3nYBUeEad).


## Keeping the Nimbus Portal client updated

When you decide to upgrade the Nimbus Portal client to a newer version, make sure to follow the
[how to upgrade page](./upgrade.md).
