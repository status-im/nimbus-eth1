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
  std/[json, os, tables, strutils],
  stew/byteutils,
  chronicles,
  unittest2,
  results,
  ./test_helpers,
  ../nimbus/db/aristo,
  ../nimbus/db/aristo/[aristo_desc, aristo_layers, aristo_part],
  ../nimbus/db/aristo/aristo_part/part_debug,
  ../nimbus/db/kvt/kvt_utils,
  ../nimbus/[tracer, evm/types],
  ../nimbus/common/common

proc setErrorLevel {.used.} =
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

proc preLoadAristoDb(cdb: CoreDbRef; jKvp: JsonNode; num: BlockNumber) =
  ## Hack for `Aristo` pre-lading using the `snap` protocol proof-loader
  const
    info = "preLoadAristoDb"
  var
    proof: seq[seq[byte]]      # for pre-loading MPT
    predRoot: Hash32           # from predecessor header
    txRoot: Hash32             # header with block number `num`
    rcptRoot: Hash32           # ditto
  let
    adb = cdb.ctx.mpt           # `Aristo` db
    kdb = cdb.ctx.kvt           # `Kvt` db
    ps = PartStateRef.init adb  # Partial DB descriptor

  # Fill KVT and collect `proof` data
  for (k,v) in jKvp.pairs:
    let
      key = hexToSeqByte(k)
      val = hexToSeqByte(v.getStr())
    if key.len == 32:
      doAssert key == val.keccak256.data
      if val != @[0x80u8]: # Exclude empty item
        proof.add val
    else:
      if key[0] == 0:
        try:
          # Pull our particular header fields (if possible)
          let header = rlp.decode(val, Header)
          if header.number == num:
            txRoot = header.txRoot
            rcptRoot = header.receiptsRoot
          elif header.number == num-1:
            predRoot = header.stateRoot
        except RlpError:
          discard
      check kdb.put(key, val).isOk

  # Set up production MPT
  ps.partPut(proof, AutomaticPayload).isOkOr:
    raiseAssert info & ": partPut => " & $error

  # TODO code needs updating after removal of generic payloads
  # # Handle transaction sub-tree
  # if txRoot.isValid:
  #   var txs: seq[Transaction]
  #   for (key,pyl) in adb.rightPairs LeafTie(root: ps.partGetSubTree txRoot):
  #     let
  #       inx = key.path.to(UInt256).truncate(uint)
  #       tx = rlp.decode(pyl.rawBlob, Transaction)
  #     #
  #     # FIXME: Is this might be a bug in the test data?
  #     #
  #     #        The single item test key is always `128`. For non-single test
  #     #        lists, the keys are `1`,`2`, ..,`N`, `128` (some single digit
  #     #        number `N`.)
  #     #
  #     #        Unless the `128` item value is put at the start of the argument
  #     #        list `txs[]` for `persistTransactions()`, the `tracer` module
  #     #        will throw an exception at
  #     #        `doAssert(transactions.calcTxRoot == header.txRoot)` in the
  #     #        function `traceTransactionImpl()`.
  #     #
  #     if (inx and 0x80) != 0:
  #       txs = @[tx] & txs
  #     else:
  #       txs.add tx
  #   cdb.persistTransactions(num, txRoot, txs)

  # # Handle receipts sub-tree
  # if rcptRoot.isValid:
  #   var rcpts: seq[Receipt]
  #   for (key,pyl) in adb.rightPairs LeafTie(root: ps.partGetSubTree rcptRoot):
  #     let
  #       inx = key.path.to(UInt256).truncate(uint)
  #       rcpt = rlp.decode(pyl.rawBlob, Receipt)
  #     # FIXME: See comment at `txRoot` section.
  #     if (inx and 0x80) != 0:
  #       rcpts = @[rcpt] & rcpts
  #     else:
  #       rcpts.add rcpt
  #   cdb.persistReceipts(rcptRoot, rcpts)

  # Save keys to database
  for (rvid,key) in ps.vkPairs:
    adb.layersPutKey(rvid, key)

  ps.check().isOkOr:
    raiseAssert info & ": check => " & $error

  #echo ">>> preLoadAristoDb (9)",
  #  "\n    ps\n    ", ps.pp(byKeyOk=false,byVidOk=false),
  #  ""
  # -----------
  #if true: quit()

# use tracerTestGen.nim to generate additional test data
proc testFixtureImpl(node: JsonNode, testStatusIMPL: var TestStatus, memoryDB: CoreDbRef) {.deprecated: "needs fixing for non-generic payloads".} =
  block:
    return
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

  var blk = com.db.getEthBlock(blockNumber).expect("eth block exists")

  let txTraces = traceTransactions(com, blk.header, blk.transactions)
  let stateDump = dumpBlockState(com, blk)
  let blockTrace = traceBlock(com, blk, {DisableState})

  # Fix hex representation
  for inx in 0 ..< node["txTraces"].len:
    for key in ["beforeRoot", "afterRoot"]:
      # Here, `node["txTraces"]` stores a string while `txTraces` uses a
      # `Hash32` which might expand to a didfferent upper/lower case.
      var strHash = txTraces[inx]["stateDiff"][key].getStr.toUpperAscii
      if strHash.len < 64:
        strHash = '0'.repeat(64 - strHash.len) & strHash
      txTraces[inx]["stateDiff"][key] = %(strHash)

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
