# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  unittest2, json, os, tables, strutils,
  eth/[common, rlp], stew/byteutils, eth/trie/db,
  ./test_helpers, ../nimbus/db/db_chain,
  ../nimbus/p2p/chain

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

  let
    parentNumber = blockNumber - 1
    parent = chainDB.getBlockHeader(parentNumber)
    header = chainDB.getBlockHeader(blockNumber)
    headerHash = header.blockHash
    blockBody = chainDB.getBlockBody(headerHash)
    chain = newChain(chainDB)
    headers = @[header]
    bodies = @[blockBody]

  chainDB.setHead(parent, true)
  let validationResult = chain.persistBlocks(headers, bodies)
  check validationResult == ValidationResult.OK

proc persistBlockJsonMain*() =
  suite "persist block json tests":
    jsonTest("PersistBlockTests", testFixture)
