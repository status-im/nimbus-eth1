# Integration between nimbus-eth1 and Ethereum [Hive](https://github.com/ethereum/hive) test environment

This is a short manual to help you quickly setup and run
Hive.  For more detailed information please read the
[hive documentation](https://github.com/ethereum/hive/blob/master/docs/overview.md).

## Prerequisites

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

- `devp2p/eth` -> require at least 2 clients
- `devp2p/discv4`
- `devp2p/snap`
- `ethereum/sync`
- `ethereum/consensus`
- `ethereum/rpc`
- `ethereum/engine`
- `smoke/network`
- `smoke/genesis`
- `smoke/clique`

The number of passes and fails output at the time of writing (2022-11-18) is:

    ethereum/consensus:  48682 pass,     0 fail, 48682 total London
    devp2p/discv4:          14 pass,     0 fail,    14 total
    devp2p/eth:             16 pass,     0 fail,    16 total
    devp2p/snap              0 pass,     5 fail,     5 total
    ethereum/rpc:           15 pass,    26 fail,    41 total
    ethereum/sync:           3 pass,     3 fail,     6 total
    ethereum/engine:        73 pass,   111 fail,   184 total
    smoke/genesis:           3 pass,     0 fail,     3 total
    smoke/network:           1 pass,     0 fail,     1 total
    smoke/clique:            1 pass,     0 fail,     1 total

## Nim simulators without docker

We have rewrite some of the hive simulators in Nim to aid debugging.
It is assumed you already install nimbus dependencies via nimble.
In the future, we will provide more instructions how to run these
simulators using local dependencies.

On Windows you might need to add `-d:disable_libbacktrace` compiler switch.
Working directory is nimbus-eth1 root directory. And you can see the result
in a markdown file with the same name with the simulator.

- ethereum/consensus
  ```nim
  nim c -r -d:release hive_integration/nodocker/consensus/consensus_sim
  ```
  Note that this program expects the _./tests_ directory accessible. So if
  you compile from the _hive_integration/nodocker_ directory on a Posix
  system, the _./tests_ directory would be a symlink to _../../tests_.

- ethereum/engine
  ```nim
  nim c -r -d:release hive_integration/nodocker/engine/engine_sim
  ```

- ethereum/rpc
  ```nim
  nim c -r -d:release hive_integration/nodocker/rpc/rpc_sim
  ```

## Observations when working with hive/docker

### DNS problems with hive simulation container running alpine OS

* Problem:<br>
  _hive_ bails out with error when compiling docker compile because
  it cannot resolve some domain name like _github.com_. It occured with
  a locally running DNS resolver (as opposed to a proxy type resolver.)

* Solution:<br>
     + First solution (may be undesirable):
       Change local nameserver entry in /etc/resolv.conf to something like

	          nameserver 8.8.8.8

         Note that docker always copies the host's /etc/resolv.conf to the
		 container one before it executes a _RUN_ directive.

     + Second solution (tedious):
       In the _Dockerfile_, prefix all affected _RUN_ directives with the text:

              echo nameserver 8.8.8.8 > /etc/resolv.conf;

### Peek into nimbus container before it finalises

* In the nimbus _Dockerfile_ before _ENTRYPOINT_, add the directive

           RUN mknod /tmp/wait-for-stop p;cat /tmp/wait-for-stop

* (Re-)Build the container with the command:

           ./hive --docker.output ...

* When the building process hangs at the

            RUN mknod ...

     directive, then use the _./docker-shell_ script to enter the running top
	 docker container

* Useful commands after entering the nimbus container<br>

           apt update
           apt install iproute2 procps vim openssh-client strace

* Resume hive installation & processing:<br>
  In the nimbus container run

           echo > /tmp/wait-for-stop
