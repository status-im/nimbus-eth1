# Usage

## Shell

A development shell can be started using:
```sh
nix develop
```

## Building

To build the execution client you can use:
```sh
nix build '.?submodules=1#nimbus_execution_client'
```
The `?submodules=1` part should eventually not be necessary.
For more details see:
https://github.com/NixOS/nix/issues/4423

It can be also done without even cloning the repo:
```sh
nix build 'github:status-im/nimbus-eth1?submodules=1#nimbus_execution_client'
```
The trailing `#nimbus_execution_client` selects the execution-client package from `flake.nix`.

## Running

```sh
nix run 'github:status-im/nimbus-eth1?submodules=1#nimbus_execution_client'
```