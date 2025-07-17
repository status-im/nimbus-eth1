# Portal Network Wire Protocol
## Introduction
The `portal/network/wire` directory holds a Nim implementation of the
[Portal Network Wire Protocol](https://github.com/ethereum/portal-network-specs/blob/31bc7e58e2e8acfba895d5a12a9ae3472894d398/history/history-network.md#wire-protocol).

The wire protocol builds on top of the Node Discovery v5.1 protocol its
`talkreq` and `talkresp` messages.

For further information on the Nim implementation of the Node Discovery v5.1
protocol check out the
[discv5](https://github.com/status-im/nim-eth/blob/master/doc/discv5.md) page.

## portalcli
This is a small command line application that allows you to run a node running
Discovery v5.1 + Portal wire protocol.

*Note:* Its objective is only to test the protocol wire component, not to actually
serve content. This means it will always return empty lists on content requests
currently. Perhaps in the future some hardcoded data could added and/or maybe
some test vectors can be created in such form.

The `portalcli` application allows you to either run a node, or to specifically
send one of the Portal message types, wait for the response, and then shut down.

### Example usage
```sh
git clone https://github.com/status-im/nimbus-eth1.git
cd nimbus-eth1

# Build portalcli
make portalcli

# See all options
./build/portalcli --help
# Example command: Ping another node
./build/portalcli ping enr:<base64 encoding of ENR>
# Example command: Run a discovery + portal node
./build/portalcli --log-level:debug --bootstrap-node:enr:<base64 encoding of ENR>
```
