# Nimbus: an Ethereum 2.0 Sharding Client for Resource-Restricted Devices

[![Build Status (Azure Pipelines)](https://dev.azure.com/nimbus-dev/nimbus/_apis/build/status/status-im.nimbus?branchName=master)](https://dev.azure.com/nimbus-dev/nimbus/_build/latest?definitionId=6&branchName=master)
[![Build Status (Travis)](https://img.shields.io/travis/status-im/nimbus/master.svg?label=Linux%20/%20macOS "Linux/macOS build status (Travis)")](https://travis-ci.org/status-im/nimbus)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

[![Discord: Nimbus](https://img.shields.io/badge/discord-nimbus-orange.svg)](https://discord.gg/XRxWahP)
[![Gitter: #status-im/nimbus](https://img.shields.io/badge/gitter-status--im%2Fnimbus-orange.svg)](https://gitter.im/status-im/nimbus)
[![Status: #nimbus-general](https://img.shields.io/badge/status-nimbus--general-orange.svg)](https://get.status.im/chat/public/nimbus-general)

## Rationale

[Nimbus: an Ethereum 2.0 Sharding Client](https://our.status.im/nimbus-for-newbies/). The code in this repository is currently focusing on Ethereum 1.0 feature parity, while all 2.0 research and development is happening in parallel in [nimbus-eth2](https://github.com/status-im/nimbus-eth2).

## Development Updates

To keep up to date with changes and development progress, follow the [Nimbus blog](https://our.status.im/tag/nimbus/).

## Building & Testing

_We currently do not guarantee that Nimbus will work on Windows._

### Prerequisites

* [RocksDB](https://github.com/facebook/rocksdb/)
* PCRE
* GNU Make, Bash and the usual POSIX utilities. Git 2.9.4 or newer.

On Windows, a precompiled DLL collection download is available through the `fetch-dlls` Makefile target: ([Windows instructions](#windows)).

```bash
# MacOS with Homebrew
brew install rocksdb pcre

# Fedora
dnf install rocksdb-devel pcre pcre-devel

# Debian and Ubuntu
sudo apt-get install librocksdb-dev libpcre3-dev

# Arch (AUR)
pakku -S rocksdb pcre-static
```

`rocksdb` can also be installed by following [their instructions](https://github.com/facebook/rocksdb/blob/master/INSTALL.md).

#### Obtaining the prerequisites through the Nix package manager

*Experimental*

Users of the [Nix package manager](https://nixos.org/nix/download.html) can install all prerequisites simply by running:

``` bash
nix-shell default.nix
```

### Build & Develop

#### POSIX-compatible OS

```bash
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull`, in the future, to keep those submodules up to date.
make nimbus

# See available command line options
build/nimbus -- help

# Start syncing with mainnet
build/nimbus

# Update to latest version
git pull
make update

# Run tests
make test
```

To run a command that might use binaries from the Status Nim fork:
```bash
./env.sh bash # start a new interactive shell with the right env vars set
which nim
nim --version

# or without starting a new interactive shell:
./env.sh which nim
./env.sh nim --version
```

Our Wiki provides additional helpful information for [debugging individual test cases][1]
and for [pairing Nimbus with a locally running copy of Geth][2].

#### Windows

_(Experimental support!)_

Install Mingw-w64 for your architecture using the "[MinGW-W64 Online
Installer](https://sourceforge.net/projects/mingw-w64/files/)" (first link
under the directory listing). Run it and select your architecture in the setup
menu ("i686" on 32-bit, "x86\_64" on 64-bit), set the threads to "win32" and
the exceptions to "dwarf" on 32-bit and "seh" on 64-bit. Change the
installation directory to "C:\mingw-w64" and add it to your system PATH in "My
Computer"/"This PC" -> Properties -> Advanced system settings -> Environment
Variables -> Path -> Edit -> New -> C:\mingw-w64\mingw64\bin (it's "C:\mingw-w64\mingw32\bin" on 32-bit)

Install [Git for Windows](https://gitforwindows.org/) and use a "Git Bash" shell to clone and build Nimbus.

If you don't want to compile RocksDB and SQLite separately, you can fetch pre-compiled DLLs with:
```bash
mingw32-make fetch-dlls # this will place the right DLLs for your architecture in the "build/" directory
```

You can now follow those instructions in the previous section by replacing `make` with `mingw32-make` (regardless of your 32-bit or 64-bit architecture):

```bash
mingw32-make nimbus # build the Nimbus binary
mingw32-make test # run the test suite
# etc.
```

#### Raspberry PI

*Experimental* The code can be compiled on a Raspberry PI:

* Raspberry PI 3b+
* 64gb SD Card (less might work too, but the default recommended 4-8GB will probably be too small)
* [Rasbian Buster Lite](https://www.raspberrypi.org/downloads/raspbian/) - Lite version is enough to get going and will save some disk space!

Assuming you're working with a freshly written image:

```bash

# Start by increasing swap size to 2gb:
sudo vi /etc/dphys-swapfile
# Set CONF_SWAPSIZE=2048
# :wq
sudo reboot

# Install prerequisites
sudo apt-get install git libgflags-dev libsnappy-dev

mkdir status
cd status

# Install rocksdb
git clone https://github.com/facebook/rocksdb.git
cd rocksdb
make shared_lib
sudo make install
cd..

# Raspberry pi doesn't include /usr/local/lib in library search path - need to add
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH

git clone https://github.com/status-im/nimbus.git

cd nimbus

# Follow instructions above!
```

#### Android

*Experimental* Code can be compiled and run on Android devices

##### Environment setup

* Install the [Termux](https://termux.com) app from FDroid or the Google Play store
* Install a [PRoot](https://wiki.termux.com/wiki/PRoot) of your choice following the instructions for your preferred distribution. 
Note, the Ubuntu PRoot is known to contain all Nimbus prerequisites compiled on Arm64 architecture (common architecture for Android devices).  Depending on the distribution, it may require effort beyond the scope of this guide to get all prerequisites.

*Assuming Ubuntu PRoot is used*

```bash
# Install prerequisites
apt install librocksdb-dev libpcre3-dev

# Clone repo and build Nimbus just like above
git clone https://github.com/status-im/nimbus.git

cd nimbus

make

make nimbus

build/nimbus
```

### Development tips

Interesting Make variables and targets are documented in the [nimbus-build-system](https://github.com/status-im/nimbus-build-system) repo.

- you can switch the DB backend with a Nim compiler define:
  `-d:nimbus_db_backend=...` where the (case-insensitive) value is one of
  "rocksdb" (the default), "sqlite", "lmdb"

- the Premix debugging tools are [documented separately](premix/readme.md)

- you can control the Makefile's verbosity with the V variable (defaults to 0):

```bash
make V=1 # verbose
make V=2 test # even more verbose
```

- same for the [Chronicles log level](https://github.com/status-im/nim-chronicles#chronicles_log_level):

```bash
make LOG_LEVEL=DEBUG nimbus # this is the default
make LOG_LEVEL=TRACE nimbus # log everything
```

- pass arbitrary parameters to the Nim compiler:

```bash
make NIMFLAGS="-d:release"
```

- if you want to use SSH keys with GitHub (also handles submodules):

```bash
make github-ssh
```

- force a Nim compiler rebuild:

```bash
rm vendor/Nim/bin/nim
make -j8 build-nim
```

#### Git submodule workflow

Working on a dependency:

```bash
cd vendor/nim-chronicles
git checkout -b mybranch
# make some changes
git status
git commit -a
git push origin mybranch
# create a GitHub PR and wait for it to be approved and merged
git checkout master
git pull
git branch -d mybranch
# realise that the merge was done without "--no-ff"
git branch -D mybranch
# update the submodule's commit in the superproject
cd ../..
git status
git add vendor/nim-chronicles
git commit
```

It's important that you only update the submodule commit after it's available upstream.

You might want to do this on a new branch of the superproject, so you can make
a GitHub PR for it and see the CI test results.

Don't update all Git submodules at once, just because you found the relevant
Git command or `make` target. You risk updating submodules to other people's
latest commits when they are not ready to be used in the superproject.

Adding the submodule "https://github.com/status-im/foo" to "vendor/foo":

```bash
vendor/nimbus-build-system/scripts/add_submodule.sh status-im/foo
# or
./env.sh add_submodule status-im/foo
# want to place it in "vendor/bar" instead?
./env.sh add_submodule status-im/foo vendor/bar
```

Removing the submodule "vendor/bar":

```bash
git submodule deinit -f -- vendor/bar
git rm -f vendor/bar
```

Checking out older commits, either to bisect something or to reproduce an older build:

```bash
git checkout <commit hash here>
make clean
make -j8 update
```

Running a dependency's test suite using `nim` instead of `nimble` (which cannot be
convinced not to run a dependency check, thus clashing with our jury-rigged
"vendor/.nimble/pkgs"):

```bash
cd vendor/nim-rocksdb
../nimbus-build-system/scripts/nimble.sh test
# or
../../env.sh nimble test
```

### Metric visualisation

Install Prometheus and Grafana. On Gentoo, it's `emerge prometheus grafana-bin`.

```bash
# build Nimbus with support for the HTTP endpoint
make NIMFLAGS="-d:insecure" nimbus
# the Prometheus daemon will create its data dir in the current dir, so give it its own directory
mkdir ../my_metrics
# copy the basic config file over there
cp -a examples/prometheus.yml ../my_metrics/
# start Prometheus in a separate terminal
cd ../my_metrics
prometheus --config.file=prometheus.yml # loads ./prometheus.yml, writes metric data to ./data
# start a fresh Nimbus sync and export metrics
rm -rf ~/.cache/nimbus/db; ./build/nimbus --prune:archive --metricsServer
```

Start the Grafana server. On Gentoo it's `/etc/init.d/grafana start`. Go to
http://localhost:3000, log in with admin:admin and change the password.

Add Prometheus as a data source. The default address of http://localhost:9090
is OK, but Grafana 6.3.5 will not apply that semitransparent default you see in
the form field, unless you click on it.

Create a new dashboard. Click on its default title in the upper left corner
("New Dashboard"). In the new page, click "Import dashboard" in the right
column and upload "examples/Nimbus-Grafana-dashboard.json".

In the main panel, there's a hidden button used to assign metrics to the left
or right Y-axis - it's the coloured line on the left of the metric name, in the
graph legend.

To see a single metric, click on its name in the legend. Click it again to go back
to the combined view. To edit a panel, click on its title and select "Edit".

[Obligatory screenshot.](https://i.imgur.com/AdtavDA.png)

### Troubleshooting

Report any errors you encounter, please, if not [already documented](https://github.com/status-im/nimbus/issues)!

* Turn it off and on again:

```bash
make clean
make update
```

## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT

or

* Apache License, Version 2.0, ([LICENSE-APACHEv2](LICENSE-APACHEv2) or http://www.apache.org/licenses/LICENSE-2.0)

at your option. These files may not be copied, modified, or distributed except according to those terms.

[1]: https://github.com/status-im/nimbus/wiki/Understanding-and-debugging-Nimbus-EVM-JSON-tests
[2]: https://github.com/status-im/nimbus/wiki/Debugging-state-reconstruction
