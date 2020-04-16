# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, json, os, tables, strutils,
  eth/common, stew/byteutils, eth/trie/db,
  ./test_helpers, ../nimbus/db/db_chain, ../nimbus/[tracer, vm_types]

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus)

proc tracerJsonMain*() =
  suite "tracer json tests":
    jsonTest("TracerTests", testFixture)

# use tracerTestGen.nim to generate additional test data
proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus) =
  var
    blockNumber = UInt256.fromHex(node["blockNumber"].getStr())
    memoryDB = newMemoryDB()
    chainDB = newBaseChainDB(memoryDB, false)
    state = node["state"]
    receipts = node["receipts"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.put(key, value)

  var header = chainDB.getBlockHeader(blockNumber)
  var headerHash = header.blockHash
  var blockBody = chainDB.getBlockBody(headerHash)

  let txTraces = traceTransactions(chainDB, header, blockBody)
  let stateDump = dumpBlockState(chainDB, header, blockBody)
  let blockTrace = traceBlock(chainDB, header, blockBody, {DisableState})

  check node["txTraces"] == txTraces
  check node["stateDump"] == stateDump
  check node["blockTrace"] == blockTrace
  for i in 0 ..< receipts.len:
    let receipt = receipts[i]
    let stateDiff = txTraces[i]["stateDiff"]
    check receipt["root"].getStr().toLowerAscii() == stateDiff["afterRoot"].getStr().toLowerAscii()

when isMainModule:
  tracerJsonMain()
