# Integration between nimbus-eth1 and Ethereum [Hive](https://github.com/ethereum/hive) test environment

This is a short manual to help you quickly setup and run
Hive.  For more detailed information please read the
[hive documentation](https://github.com/ethereum/hive/blob/master/docs/overview.md).

## Prerequisities

- A Linux machine. Trust me, it does not work on Windows or MacOS.
- Or Linux inside a VM (e.g. VirtualBox) on Windows or MacOS.
- Docker installed and working in your Linux.
- Go compiler installed in your Linux.
- Go must be version 1.16 or later.

## Practicalities

Practically, if using an Ubuntu Linux and you want to use the version of Go
shipped with Ubuntu, you will need Ubuntu 21.04 or later.  It's enough to run
`apt-get install golang`.

If using Ubuntu 20.04 LTS (likely because it's the long-term stable version),
the shipped Go isn't recent enough, and there will be build errors.  You can
either install a non-Ubuntu packaged version of Go (maybe from
[`golang.org`](https://golang.org/), or use a more recent Ubuntu.

If you want to run Hive in a Linux container, you will need Docker to work in
the container because Hive calls Docker (a lot!).  This is sometimes called
"Docker in Docker".  Inside LXD containers, Docker doesn't work by default, but
usually this is remedied by setting the container flag `lxc config set
$CONTAINER_NAME security.nesting true`, which takes effect immediately.

## Building hive

First you will need a working Go installation, Go 1.16 or later.  Then:

```bash
git clone https://github.com/ethereum/hive
cd ./hive
go build .
```

# How to run hive

First copy the `nimbus-eth1/hive_intgration/nimbus` folder (from this repo)
into the `hive/clients` folder (in the `hive` repo).

Then run this command:

```
./hive --sim <simulation> --client <client(s) you want to test against>
```

Examples:

```bash
./hive --sim ethereum/consensus --client nimbus
```

or

```bash
./hive --sim devp2p/discv4 --client go-ethereum,openethereum,nimbus
```

## Available test suites / simulators

- `devp2p/eth`
- `devp2p/discv4`
- `ethereum/sync`
- `ethereum/consensus`
- `ethereum/rpc`
- `ethereum/graphql`

# Current state of the tests

These Hive suites/simulators can be run:

- `ethereum/consensus`
- `ethereum/graphql`

These Hive suites/simulators don't work with `nimbus-eth1` currently:

- `devp2p/discv4`
- `devp2p/eth`
- `ethereum/rpc`
- `ethereum/sync`

The number of passes and fails output at the time of writing (2021-04-26) is:

    ethereum/consensus:  27353 pass,   892 fail, 28245 total
    ethereum/graphql:       36 pass,    10 fail,    46 total
    devp2p/discv4:           0 pass,    14 fail,    14 total
    devp2p/eth:              0 pass,     1 fail,     1 total
    ethereum/rpc:            3 pass,    35 fail,    38 total
    ethereum/sync:           0 pass,     1 fail,     1 total
