# Connect to the Portal network

Connecting to the current Portal network is as easy as running following command:

```sh
./build/nimbus_portal_client --rpc
```

This will connect to the public Portal mainnet which contains nodes of the different clients.

!!! note
    By default the Portal node will connect to the
    [bootstrap nodes](https://github.com/ethereum/portal-network-specs/blob/master/bootnodes.md#bootnodes-mainnet) of the public mainnet.

    When testing locally the `--network:none` option can be provided to avoid
    connecting to any of the default bootstrap nodes.

The `--rpc` option will also enable the different JSON-RPC interfaces through
which you can access the Portal Network.

The Nimbus Portal client fully supports the [Portal Network JSON-RPC Specification](https://playground.open-rpc.org/?schemaUrl=https://raw.githubusercontent.com/ethereum/portal-network-specs/assembled-spec/jsonrpc/openrpc.json&uiSchema%5BappBar%5D%5Bui:splitView%5D=false&uiSchema%5BappBar%5D%5Bui:input%5D=false&uiSchema%5BappBar%5D%5Bui:examplesDropdown%5D=false).

The Nimbus Portal client also supports a small subset of the [Execution JSON-RPC API](https://ethereum.github.io/execution-apis/api-documentation/).


!!! note
    The end goal is to be able to fully support the Execution JSON-RPC API,
    however currently not all Portal networks are specified, implemented or
    rolled out to be able to provide this.


<!-- TODO: Explain some of the more important cli options here? Or in a separate
page? -->
