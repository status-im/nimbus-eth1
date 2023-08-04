# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[json, os, tables, strutils],
  unittest2,
  stew/byteutils,
  ./test_helpers,
  ../nimbus/core/chain,
  ../nimbus/common/common

# use tracerTestGen.nim to generate additional test data
proc testFixture(node: JsonNode, testStatusIMPL: var TestStatus) =
  var
    blockNumber = UInt256.fromHex(node["blockNumber"].getStr())
    memoryDB    = newCoreDbRef LegacyDbMemory
    config      = chainConfigForNetwork(MainNet)
    com         = CommonRef.new(memoryDB, config, pruneTrie = false)
    state       = node["state"]

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    memoryDB.kvt.put(key, value)

  let
    parentNumber = blockNumber - 1
    parent = com.db.getBlockHeader(parentNumber)
    header = com.db.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = com.db.getBlockBody(headerHash)
    chain = newChain(com)
    headers = @[header]
    bodies = @[blockBody]

  # it's ok if setHead fails here because of missing ancestors
  discard com.db.setHead(parent, true)
  let validationResult = chain.persistBlocks(headers, bodies)
  check validationResult == ValidationResult.OK

proc persistBlockJsonMain*() =
  suite "persist block json tests":
    jsonTest("PersistBlockTests", testFixture)
  #var testStatusIMPL: TestStatus
  #let n = json.parseFile("tests" / "fixtures" / "PersistBlockTests" / "block420301.json")
  #testFixture(n, testStatusIMPL)

when isMainModule:
  persistBlockJsonMain()
