
# Nimbus EL - Stateless Features & Support for zkEVMs

The Nimbus EL supports generating execution witnesses (in hexary trie/MPT format)
during block execution. These witnesses are stored in the database for each block
executed and can be fetched on demand via the `debug_executionWitness` and
`debug_executionWitnessByBlockHash` RPC endpoints.

Stateless execution is also supported in the code which enables a block to be
statelessly executed and validated using only the block, the witness and the chain
config.

Nimbus stores only a single state in the database (state at the latest finalized
block) so in order to support fetching historical witnesses we need to generate
and store them while the node syncs and executes each block. Witnesses can be built
for any block as long as we have the state of the parent block. This means it is
possible to fully sync a Nimbus node without generating any witnesses and then enable
witness generation for only recent blocks going forward if this is desired.

Note that enabling witness generation does slow down the block execution due to the
extra overhead of collecting the state accesses, building and encoding the witnesses
so it should only be enabled when required. This design of storing the generated
witnesses in the database means that the witness RPC endpoints are very fast since
we don't generate the witnesses on demand but rather just return them from the database.


## Building Nimbus

Build the Nimbus binary using either:
```bash
make nimbus_execution_client
```
or
```bash
make nimbus
```
`nimbus` is the combined EL and CL binary while `nimbus_execution_client` is just
the standalone EL binary.

Most of the commands below use the standalone EL binary but they should also work
using the combined binary when using the `nimbus executionClient` sub-command instead
of `nimbus_execution_client`.


## Stateless CLI Flags

Enable the stateless features using:
```bash
--stateless-provider=true
```
This flag is disabled by default so it must be manually enabled.


## Witness Generation

There are two ways to generate witnesses during block execution:
1. via the regular full sync or
2. via a block import using era1 and/or era files

To generate witnesses using full sync run:
```bash
build/nimbus_execution_client --debug-beacon-sync-target=<target-block-hash> --debug-beacon-sync-target-is-final=true --stateless-provider=true
```
The `debug-beacon-sync-target` parameter is the hash of the block to synced up to. It should be a valid finalized block.

To generate witnesses using full sync using the combined EL and CL binary:
```bash
build/nimbus --stateless-provider=true
```

To generate witnesses using the block import run:
```bash
build/nimbus_execution_client import --era1-dir=<era1-dir> --era-dir=<era-dir> --stateless-provider=true --chunk-size=1000
```

The era1 files can be downloaded by following the instructions here: https://ethpandaops.io/data/history/?history-network=quickstart

The era files can be downloaded using the script here: https://github.com/status-im/nimbus-eth1/blob/master/scripts/era_downloader.sh

Note that generating historical witnesses is much faster using the block import than when using the regular full sync.

## Fetching Witnesses

After the witnesses have been generated and stored in the database they
can be fetched via the `debug_executionWitness` and
`debug_executionWitnessByBlockHash` RPC endpoints.

First start Nimbus with the debug RPC API enabled:
```bash
build/nimbus_execution_client --rpc --rpc-api=debug --http-port=8545
```

Fetch a witness by block number:
```
curl -s -X POST -H 'Content-Type: application/json' -d '{
    "jsonrpc": "2.0",
    "method": "debug_executionWitness",
    "id": 1,
    "params": [
        "0xCAD1"
    ]
}' http://localhost:8545
```

Fetch a witness by block hash:
```
curl -s -X POST -H 'Content-Type: application/json' -d '{
    "jsonrpc": "2.0",
    "method": "debug_executionWitnessByBlockHash",
    "id": 1,
    "params": [
        "0x4d7ee90088305e35fac481b8b8b1729bad343d5e54a37d0e64583d4bcd171987"
    ]
}' http://localhost:8545
```

## Stateless Execution

Stateless execution of blocks is supported here: https://github.com/status-im/nimbus-eth1/blob/c7d5ccf06d88c1a00e9b7decfffb65023e03ed15/execution_chain/stateless/stateless_execution.nim#L25

Here is the interface of the stateless execution function:
```
proc statelessProcessBlock*(
    witness: ExecutionWitness,
    com: CommonRef,
    blk: Block): Result[void, string]
```
It takes as input the `ExecutionWitness` object, a `CommonRef` which is basically the chain config
and the `Block`. It returns an `ok` result if the verification passes and an `err` string containing the
reason for the failure otherwise.

In the future we will likely support a CLI sub-command that can pass in a block
and a witness in json format and verify the block using the stateless execution function.

## Running EEST Tests using Stateless Execution

To run the EEST tests with stateless execution enabled:
```bash
make eest_stateless_execution_test
```

Each of the tests in this suite generate the witness using the regular stateful
execution and then afterwards use the generated witness to execute and verify
the block using the stateless execution function `statelessProcessBlock`.
