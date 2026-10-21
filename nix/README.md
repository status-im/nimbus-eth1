# Usage

## Shell

A development shell can be started using:
```sh
nix develop
```

## Building

To build the execution client you can use:
```sh
nix build '.#nimbus_execution_client'
```
It can be also done without even cloning the repo:
```sh
nix build 'git+https://github.com/status-im/nimbus-eth1#nimbus_execution_client'
```
The default package is combined `nimbus` exec and consensus layer.
Use trailing `#` argument to select just `nimbus_execution_client` package.

## Running

```sh
nix run 'git+https://github.com/status-im/nimbus-eth1#nimbus_execution_client'
```
