# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## Replays the trace_* conformance fixtures from the execution-apis test
## suite (.io request/response files) against the in-process RPC router.
## Fixture provenance: tests/trace_compat/SOURCE.txt

import
  std/[json, os, strutils],
  unittest2,
  chronos,
  json_rpc/rpcserver,
  ../execution_chain/conf,
  ../execution_chain/common/common,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/core/[tx_pool, chain, block_import],
  ../execution_chain/rpc,
  ../execution_chain/rpc/trace

const
  baseDir = "tests" / "trace_compat"

type
  IoExchange = object
    request:  string
    expected: string

proc parseIoFile(path: string): seq[IoExchange] =
  var pending = ""
  for line in lines(path):
    if line.startsWith(">> "):
      pending = line[3..^1]
    elif line.startsWith("<< "):
      result.add IoExchange(request: pending, expected: line[3..^1])

proc setupEnv(): (CommonRef, RpcHttpServer) =
  let
    conf = makeConfig(@["--network:" & baseDir / "genesis.json"])
    com  = CommonRef.new(newCoreDbRef DefaultDbMemory, conf.computeNetworkParams())
    chain = ForkedChainRef.init(com)
    txPool = TxPoolRef.new(chain)

  let res = waitFor importRlpBlocks(baseDir / "chain.rlp", chain, finalize = true)
  doAssert res.isOk, "chain.rlp import failed: " & res.error

  let server = newRpcHttpServerWithParams("127.0.0.1:0").valueOr:
    raiseAssert "Failed to create RPC server: " & error
  setupTraceRpc(com, txPool, server)
  (com, server)

suite "trace_* .io conformance fixtures":
  let (com, server) = setupEnv()
  discard com

  for dir in walkDirs(baseDir / "trace_*"):
    for path in walkFiles(dir / "*.io"):
      test path.splitPath.tail:
        for exchange in parseIoFile(path):
          let response = waitFor server.router.route(exchange.request)
          check parseJson(response) == parseJson(exchange.expected)
