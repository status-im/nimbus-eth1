# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  json, stint, stew/byteutils,
  results,
  ../nimbus/db/[core_db, storage_types], eth/[rlp, common],
  ../nimbus/tracer

proc generatePrestate*(nimbus, geth: JsonNode, blockNumber: UInt256, parent, header: BlockHeader, body: BlockBody) =
  let
    state = nimbus["state"]
    headerHash = rlpHash(header)
    chainDB = newCoreDbRef(DefaultDbMemory)
    kvt = chainDB.newKvt()

  discard chainDB.setHead(parent, true)
  discard chainDB.persistTransactions(blockNumber, body.transactions)
  discard chainDB.persistUncles(body.uncles)

  kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header)).isOkOr:
    raiseAssert "generatePrestate(): put() failed " & $$error
  chainDB.addBlockNumberToHashLookup(header)

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    kvt.put(key, value).isOkOr:
      raiseAssert "generatePrestate(): put() (loop) failed " & $$error

  var metaData = %{
    "blockNumber": %blockNumber.toHex,
    "geth": geth
  }

  metaData.dumpMemoryDB(chainDB)
  writeFile("block" & $blockNumber & ".json", metaData.pretty())
