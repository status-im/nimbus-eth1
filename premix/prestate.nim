import
  json, stint, stew/byteutils,
  ../nimbus/db/[core_db, storage_types], eth/[rlp, common],
  ../nimbus/tracer

proc generatePrestate*(nimbus, geth: JsonNode, blockNumber: UInt256, parent, header: BlockHeader, body: BlockBody) =
  let
    state = nimbus["state"]
    headerHash = rlpHash(header)

  var
    chainDB = newCoreDbRef(LegacyDbMemory)

  discard chainDB.setHead(parent, true)
  discard chainDB.persistTransactions(blockNumber, body.transactions)
  discard chainDB.persistUncles(body.uncles)

  chainDB.kvt.put(genericHashKey(headerHash).toOpenArray, rlp.encode(header))
  chainDB.addBlockNumberToHashLookup(header)

  for k, v in state:
    let key = hexToSeqByte(k)
    let value = hexToSeqByte(v.getStr())
    chainDB.kvt.put(key, value)

  var metaData = %{
    "blockNumber": %blockNumber.toHex,
    "geth": geth
  }

  metaData.dumpMemoryDB(chainDB)
  writeFile("block" & $blockNumber & ".json", metaData.pretty())
