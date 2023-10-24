# Build from source

Building Fluffy from source ensures that all hardware-specific optimizations are
turned on.
The build process itself is simple and fully automated, but may take a few minutes.

!!! note "Nim"
    Fluffy is written in the [Nim](https://nim-lang.org) programming language.
    The correct version will automatically be downloaded as part of the build process!

## Prerequisites

Make sure you have all needed [prerequisites](./prerequisites.md).

## Building the Fluffy client

### 1. Clone the `nimbus-eth1` repository

```sh
git clone git@github.com:status-im/nimbus-eth1.git
cd nimbus-eth1
```

### 2. Run the Fluffy build process

To build Fluffy and its dependencies, run:

```sh
make fluffy
```

This step can take several minutes.
After it has finished, you can check if the build was successful by running:

```sh
# See available command line options
./build/fluffy --help
```

If you see the command-line options, your installation was successful!
Otherwise, don't hesitate to reach out to us in the `#nimbus-fluffy` channel of
[our discord](https://discord.gg/j3nYBUeEad).


## Keeping Fluffy updated

When you decide to upgrade Fluffy to a newer version, make sure to follow the
[how to upgrade page](./upgrade.md).