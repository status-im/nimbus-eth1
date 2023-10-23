# Quick start - Windows

This page takes you through the steps of getting the Fluffy Portal node running
on the public network.

The guide assumes Windows is being used. For Linux/macOS users follow this
[tutorial](./quick-start.md).

!!! notice
    Running Fluffy on Windows is more experimental and less tested!

## Steps

### Prerequisites
- Install & setup Mingw-w64:
    - Download Mingw-w64 for your architecture using the "[MinGW-W64 Online
    Installer](https://sourceforge.net/projects/mingw-w64/files/)" (first link
    under the directory listing).
    - Run it and select your architecture in the setup
    menu ("i686" on 32-bit, "x86\_64" on 64-bit), set the threads to "win32" and
    the exceptions to "dwarf" on 32-bit and "seh" on 64-bit. Change the
    installation directory to "C:\mingw-w64".
    - Add it to your system PATH in "My Computer"/"This PC" -> Properties ->
    Advanced system settings -> Environment Variables -> Path -> Edit -> New -> C:\mingw-w64\mingw64\bin (it's "C:\mingw-w64\mingw32\bin" on 32-bit)

- Install [cmake](https://cmake.org/).

- Install [Git for Windows](https://gitforwindows.org/) and use a "Git Bash"
shell to clone and build Fluffy in the next steps.

### Build the Fluffy client
```bash
git clone git@github.com:status-im/nimbus-eth1.git
cd nimbus-eth1
mingw32-make fluffy

# Test if binary was successfully build by running the help command.
./build/fluffy --help
```

### Run a Fluffy client on the public testnet

```bash
# Connect to the Portal testnet bootstrap nodes and enable the JSON-RPC APIs
./build/fluffy --rpc
```

### Try requesting a execution layer block from the network

The Portal testnet is slowly being filled up with historical data through bridge
nodes. Because of this, more recent history data is more likely to be available.
This can be tested by using the `eth_getBlockByHash` JSON-RPC from the
[execution JSON-RPC API](https://ethereum.github.io/execution-apis/api-documentation/).

```bash
# Get the hash of a block from your favorite block explorer, e.g.:
BLOCKHASH=0x34eea44911b19f9aa8c72f69bdcbda3ed933b11a940511b6f3f58a87427231fb # Replace this to the block hash of your choice
# Run this command to get the block:
curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"1","method":"eth_getBlockByHash","params":["'${BLOCKHASH}'", true]}' http://localhost:8545 | jq
```

### Update and rebuild the Fluffy client
In order to stay up to date you can pull the latest version from our master
branch. There are currently released versions tagged.

```bash
# From the nimbus-eth1 repository
git pull
# To bring the git submodules up to date
mingw32-make update

mingw32-make fluffy
```
