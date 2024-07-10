# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified,
# or distributed except according to those terms.

import
  std/[json, os, sets, tables, strutils],
  stew/byteutils,
  chronicles,
  unittest2,
  results,
  ./test_helpers,
  ../nimbus/sync/protocol/snap/snap_types,
  ../nimbus/db/aristo/aristo_merge,
  ../nimbus/db/kvt/kvt_utils,
  ../nimbus/db/aristo,
  ../nimbus/[tracer, evm/types],
  ../nimbus/common/common

proc setErrorLevel {.used.} =
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

proc preLoadAristoDb(cdb: CoreDbRef; jKvp: JsonNode; num: BlockNumber) =
  ## Hack for `Aristo` pre-lading using the `snap` protocol proof-loader
  var
    proof: seq[SnapProof] # for pre-loading MPT
    predRoot: Hash256     # from predecessor header
    txRoot: Hash256       # header with block number `num`
    rcptRoot: Hash256     # ditto
  let
    adb = cdb.mpt
    kdb = cdb.kvt

  # Fill KVT and collect `proof` data
  for (k,v) in jKvp.pairs:
    let
      key = hexToSeqByte(k)
      val = hexToSeqByte(v.getStr())
    if key.len == 32:
      doAssert key == val.keccakHash.data
      if val != @[0x80u8]: # Exclude empty item
        proof.add SnapProof(val)
    else:
      if key[0] == 0:
        try:
          # Pull our particular header fields (if possible)
          let header = rlp.decode(val, BlockHeader)
          if header.number == num:
            txRoot = header.txRoot
            rcptRoot = header.receiptsRoot
          elif header.number == num-1:
            predRoot = header.stateRoot
        except RlpError:
          discard
      check kdb.put(key, val).isOk

  # TODO: `getColumn(CtXyy)` does not exists anymore. There is only the generic
  #       `MPT` left that can be retrieved with `getGeneric()`, optionally with
  #       argument `clearData=true`

  # Install sub-trie roots onto production db
  if txRoot.isValid:
    doAssert adb.mergeProof(txRoot, VertexID(CtTxs)).isOk
  if rcptRoot.isValid:
    doAssert adb.mergeProof(rcptRoot, VertexID(CtReceipts)).isOk
  doAssert adb.mergeProof(predRoot, VertexID(CtAccounts)).isOk

  # Set up production MPT
  doAssert adb.mergeProof(proof).isOk

# use tracerTestGen.nim to generate additional test data
proc testFixtureImpl(node: JsonNode, testStatusIMPL: var TestStatus, memoryDB: CoreDbRef) =
  setErrorLevel()

  var
    blockNumberHex = node["blockNumber"].getStr()
    blockNumber = parseHexInt(blockNumberHex).uint64
    com = CommonRef.new(memoryDB, chainConfigForNetwork(MainNet))
    state = node["state"]
    receipts = node["receipts"]

  # disable POS/post Merge feature
  com.setTTD Opt.none(DifficultyInt)

  # Import raw data into database
  # Some hack for `Aristo` using the `snap` protocol proof-loader
  memoryDB.preLoadAristoDb(state, blockNumber)

  var blk = com.db.getEthBlock(blockNumber)

  let txTraces = traceTransactions(com, blk.header, blk.transactions)
  let stateDump = dumpBlockState(com, blk)
  let blockTrace = traceBlock(com, blk, {DisableState})

  check node["txTraces"] == txTraces
  check node["stateDump"] == stateDump
  check node["blockTrace"] == blockTrace
  for i in 0 ..< receipts.len:
    let receipt = receipts[i]
    let stateDiff = txTraces[i]["stateDiff"]
    check receipt["root"].getStr().toLowerAscii() == stateDiff["afterRoot"].getStr().toLowerAscii()


proc testFixtureAristo(node: JsonNode, testStatusIMPL: var TestStatus) =
  node.testFixtureImpl(testStatusIMPL, newCoreDbRef AristoDbMemory)

proc tracerJsonMain*() =
  suite "tracer json tests for Aristo DB":
    jsonTest("TracerTests", testFixtureAristo)

when isMainModule:
  tracerJsonMain()
