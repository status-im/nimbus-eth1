nimbus-eth1 hive integration
-----

This is a short manual to help you quickly setup and run
hive, for more detailed information please read
[hive documentation](https://github.com/ethereum/hive/blob/master/docs/overview.md)

## Prerequisities

* A linux machine. Trust me, it does not work on Windows/MacOS
* Or run a linux inside a VM(e.g. virtualbox) on Windows/MacOS
* docker installed on your linux
* go compiler installed on your linux

## Building hive

```bash
git clone https://github.com/ethereum/hive
cd ./hive
go build .
```

## Available simulations

* devp2p/eth, devp2p/discv4
* ethereum/sync
* ethereum/consensus
* ethereum/rpc
* ethereum/graphql

## How to run hive

First you need to copy the `hive_intgration/nimbus` into `hive/clients` folder.
Then run this command:

```
./hive --sim <simulation> --client <client(s) you want to test against>
```

Example:

```bash
./hive --sim devp2p/discv4 --client go-ethereum,openethereum,nimbus
```
