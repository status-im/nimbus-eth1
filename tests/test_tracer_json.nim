# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest, json, os, tables, strutils, times, strformat,
  eth_common, byteutils, nimcrypto, rlp,
  eth_trie/[hexary, db, defs]

import
  ./test_helpers,
  ../nimbus/db/[storage_types, db_chain, state_db, capturedb],
  ../nimbus/[transaction, rpc/hexstrings],
  ../nimbus/[tracer, vm_types, utils]

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus)

suite "tracer json tests":
  jsonTest("TracerTests", testFixture)

proc getBlockBody(chainDB: BaseChainDB, hash: Hash256): BlockBody =
  if not chainDB.getBlockBody(hash, result):
    raise newException(ValueError, "Error when retrieving block body")

# use tracerTestGen.nim to generate additional test data

proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus) =
  var
    blockNumber = UInt256.fromHex(node["blockNumber"].getStr())
    memoryDB = newMemoryDB()
    chainDB = newBaseChainDB(memoryDB, false)
    state = node["state"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.put(key, value)

  var header = chainDB.getBlockHeader(blockNumber)
  var headerHash = header.blockHash
  var blockBody = chainDB.getBlockBody(headerHash)

  let txTrace = traceTransaction(chainDB, header, blockBody, 0, {DisableState})
  let stateDump = dumpBlockState(chainDB, header, blockBody)
  let blockTrace = traceBlock(chainDB, header, blockBody, {DisableState})

  check node["txTrace"] == txTrace
  check node["stateDump"] == stateDump
  check node["blockTrace"] == blockTrace
