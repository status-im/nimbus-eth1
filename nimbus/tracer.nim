# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# TODO: CoreDb module needs to be updated

import
  std/[strutils, json],
  ./common/common,
  ./db/[core_db, ledger],
  ./utils/utils,
  ./evm/tracer/legacy_tracer,
  ./constants,
  ./transaction,
  ./core/executor,
  ./evm/[state, types],
  nimcrypto/utils as ncrutils,
  web3/conversions, ./launcher,
  results,
  ./beacon/web3_eth_conv

proc getParentHeader(self: CoreDbRef, header: BlockHeader): BlockHeader =
  self.getBlockHeader(header.parentHash)

type
  SaveCtxEnv = object
    db: CoreDbRef
    ctx: CoreDbCtxRef

proc newCtx(com: CommonRef; root: eth_types.Hash256): SaveCtxEnv =
  let ctx = com.db.ctxFromTx(root).valueOr:
    raiseAssert "setParentCtx: " & $$error
  SaveCtxEnv(db: com.db, ctx: ctx)

proc setCtx(saveCtx: SaveCtxEnv): SaveCtxEnv =
  SaveCtxEnv(db: saveCtx.db, ctx: saveCtx.db.swapCtx saveCtx.ctx)


proc `%`(x: openArray[byte]): JsonNode =
  result = %toHex(x, false)

proc toJson(receipt: Receipt): JsonNode =
  result = newJObject()

  result["cumulativeGasUsed"] = %receipt.cumulativeGasUsed
  result["bloom"] = %receipt.logsBloom
  result["logs"] = %receipt.logs

  if receipt.hasStateRoot:
    result["root"] = %($receipt.stateRoot)
  else:
    result["status"] = %receipt.status

proc dumpReceipts*(chainDB: CoreDbRef, header: BlockHeader): JsonNode =
  result = newJArray()
  for receipt in chainDB.getReceipts(header.receiptsRoot):
    result.add receipt.toJson

proc toJson*(receipts: seq[Receipt]): JsonNode =
  result = newJArray()
  for receipt in receipts:
    result.add receipt.toJson

proc captureAccount(n: JsonNode, db: LedgerRef, address: EthAddress, name: string) =
  var jaccount = newJObject()
  jaccount["name"] = %name
  jaccount["address"] = %("0x" & $address)

  let nonce = db.getNonce(address)
  let balance = db.getBalance(address)
  let codeHash = db.getCodeHash(address)
  let storageRoot = db.getStorageRoot(address)

  jaccount["nonce"] = %(conversions.`$`(nonce.Web3Quantity))
  jaccount["balance"] = %("0x" & balance.toHex)

  let code = db.getCode(address)
  jaccount["codeHash"] = %("0x" & ($codeHash).toLowerAscii)
  jaccount["code"] = %("0x" & toHex(code, true))
  jaccount["storageRoot"] = %("0x" & ($storageRoot).toLowerAscii)

  var storage = newJObject()
  for key, value in db.storage(address):
    storage["0x" & key.dumpHex] = %("0x" & value.dumpHex)
  jaccount["storage"] = storage

  n.add jaccount

proc dumpMemoryDB*(node: JsonNode, db: CoreDbRef) =
  var n = newJObject()
  for k, v in db.ctx.getKvt():
    n[k.toHex(false)] = %v
  node["state"] = n

proc dumpMemoryDB*(node: JsonNode, kvt: TableRef[common.Blob, common.Blob]) =
  var n = newJObject()
  for k, v in kvt:
    n[k.toHex(false)] = %v
  node["state"] = n

proc dumpMemoryDB*(node: JsonNode, capture: CoreDbCaptRef) =
  node.dumpMemoryDB capture.logDb

const
  senderName = "sender"
  recipientName = "recipient"
  minerName = "miner"
  uncleName = "uncle"
  internalTxName = "internalTx"

proc traceTransaction*(com: CommonRef, header: BlockHeader,
                       transactions: openArray[Transaction], txIndex: uint64,
                       tracerFlags: set[TracerFlags] = {}): JsonNode =
  let
    # we add a memory layer between backend/lower layer db
    # and capture state db snapshot during transaction execution
    capture = com.db.newCapture.value
    tracerInst = newLegacyTracer(tracerFlags)
    captureCom = com.clone(capture.recorder)

    saveCtx = setCtx com.newCtx(com.db.getParentHeader(header).stateRoot)
    vmState = BaseVMState.new(header, captureCom).valueOr:
                return newJNull()
    stateDb = vmState.stateDB

  defer:
    saveCtx.setCtx().ctx.forget()
    capture.forget()

  if header.txRoot == EMPTY_ROOT_HASH: return newJNull()
  doAssert(transactions.calcTxRoot == header.txRoot)
  doAssert(transactions.len != 0)

  var
    gasUsed: GasInt
    before = newJArray()
    after = newJArray()
    stateDiff = %{"before": before, "after": after}
    beforeRoot: common.Hash256
    beforeCtx: SaveCtxEnv

  let
    miner = vmState.coinbase()

  for idx, tx in transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient(sender)

    if idx.uint64 == txIndex:
      vmState.tracer = tracerInst # only enable tracer on target tx
      before.captureAccount(stateDb, sender, senderName)
      before.captureAccount(stateDb, recipient, recipientName)
      before.captureAccount(stateDb, miner, minerName)
      stateDb.persist()
      stateDiff["beforeRoot"] = %($stateDb.rootHash)
      beforeRoot = stateDb.rootHash
      beforeCtx = com.newCtx beforeRoot

    let rc = vmState.processTransaction(tx, sender, header)
    gasUsed = if rc.isOk: rc.value else: 0

    if idx.uint64 == txIndex:
      after.captureAccount(stateDb, sender, senderName)
      after.captureAccount(stateDb, recipient, recipientName)
      after.captureAccount(stateDb, miner, minerName)
      tracerInst.removeTracedAccounts(sender, recipient, miner)
      stateDb.persist()
      stateDiff["afterRoot"] = %($stateDb.rootHash)
      break

  # internal transactions:
  let
    saveCtxBefore = setCtx beforeCtx
    stateBefore = LedgerRef.init(capture.recorder, beforeRoot)
  defer:
    saveCtxBefore.setCtx().ctx.forget()

  for idx, acc in tracedAccountsPairs(tracerInst):
    before.captureAccount(stateBefore, acc, internalTxName & $idx)

  for idx, acc in tracedAccountsPairs(tracerInst):
    after.captureAccount(stateDb, acc, internalTxName & $idx)

  result = tracerInst.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableStateDiff notin tracerFlags:
    result["stateDiff"] = stateDiff

  # now we dump captured state db
  if TracerFlags.DisableState notin tracerFlags:
    result.dumpMemoryDB(capture)

proc dumpBlockState*(com: CommonRef, blk: EthBlock, dumpState = false): JsonNode =
  template header: BlockHeader = blk.header
  let
    parent = com.db.getParentHeader(header)
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)
    # we only need a stack dump when scanning for internal transaction address
    captureFlags = {DisableMemory, DisableStorage, EnableAccount}
    tracerInst = newLegacyTracer(captureFlags)

    saveCtx = setCtx com.newCtx(parent.stateRoot)
    vmState = BaseVMState.new(header, captureCom, tracerInst).valueOr:
                return newJNull()
    miner = vmState.coinbase()
  defer:
    saveCtx.setCtx().ctx.forget()
    capture.forget()

  var
    before = newJArray()
    after = newJArray()
    stateBefore = LedgerRef.init(capture.recorder, parent.stateRoot)

  for idx, tx in blk.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient(sender)
    before.captureAccount(stateBefore, sender, senderName & $idx)
    before.captureAccount(stateBefore, recipient, recipientName & $idx)

  before.captureAccount(stateBefore, miner, minerName)

  for idx, uncle in blk.uncles:
    before.captureAccount(stateBefore, uncle.coinbase, uncleName & $idx)

  discard vmState.processBlock(blk)

  var stateAfter = vmState.stateDB

  for idx, tx in blk.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient(sender)
    after.captureAccount(stateAfter, sender, senderName & $idx)
    after.captureAccount(stateAfter, recipient, recipientName & $idx)
    tracerInst.removeTracedAccounts(sender, recipient)

  after.captureAccount(stateAfter, miner, minerName)
  tracerInst.removeTracedAccounts(miner)

  for idx, uncle in blk.uncles:
    after.captureAccount(stateAfter, uncle.coinbase, uncleName & $idx)
    tracerInst.removeTracedAccounts(uncle.coinbase)

  # internal transactions:
  for idx, acc in tracedAccountsPairs(tracerInst):
    before.captureAccount(stateBefore, acc, internalTxName & $idx)

  for idx, acc in tracedAccountsPairs(tracerInst):
    after.captureAccount(stateAfter, acc, internalTxName & $idx)

  result = %{"before": before, "after": after}

  if dumpState:
    result.dumpMemoryDB(capture)

proc traceBlock*(com: CommonRef, blk: EthBlock, tracerFlags: set[TracerFlags] = {}): JsonNode =
  template header: BlockHeader = blk.header
  let
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)
    tracerInst = newLegacyTracer(tracerFlags)

    saveCtx = setCtx com.newCtx(com.db.getParentHeader(header).stateRoot)
    vmState = BaseVMState.new(header, captureCom, tracerInst).valueOr:
                return newJNull()

  defer:
    saveCtx.setCtx().ctx.forget()
    capture.forget()

  if header.txRoot == EMPTY_ROOT_HASH: return newJNull()
  doAssert(blk.transactions.calcTxRoot == header.txRoot)
  doAssert(blk.transactions.len != 0)

  var gasUsed = GasInt(0)

  for tx in blk.transactions:
    let
      sender = tx.getSender
      rc = vmState.processTransaction(tx, sender, header)
    if rc.isOk:
      gasUsed = gasUsed + rc.value

  result = tracerInst.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableState notin tracerFlags:
    result.dumpMemoryDB(capture)

proc traceTransactions*(com: CommonRef, header: BlockHeader, transactions: openArray[Transaction]): JsonNode =
  result = newJArray()
  for i in 0 ..< transactions.len:
    result.add traceTransaction(com, header, transactions, i.uint64, {DisableState})


proc dumpDebuggingMetaData*(vmState: BaseVMState, blk: EthBlock, launchDebugger = true) =
  template header: BlockHeader = blk.header
  let
    com = vmState.com
    blockNumber = header.number
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)
    bloom = createBloom(vmState.receipts)
  defer:
    capture.forget()

  let blockSummary = %{
    "receiptsRoot": %("0x" & toHex(calcReceiptsRoot(vmState.receipts).data)),
    "stateRoot": %("0x" & toHex(vmState.stateDB.rootHash.data)),
    "logsBloom": %("0x" & toHex(bloom))
  }

  var metaData = %{
    "blockNumber": %blockNumber.toHex,
    "txTraces": traceTransactions(captureCom, header, blk.transactions),
    "stateDump": dumpBlockState(captureCom, blk),
    "blockTrace": traceBlock(captureCom, blk, {DisableState}),
    "receipts": toJson(vmState.receipts),
    "block": blockSummary
  }

  metaData.dumpMemoryDB(capture)

  let jsonFileName = "debug" & $blockNumber & ".json"
  if launchDebugger:
    launchPremix(jsonFileName, metaData)
  else:
    writeFile(jsonFileName, metaData.pretty())
