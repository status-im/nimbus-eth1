# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[strutils, json],
  ./common/common,
  ./db/[core_db, ledger],
  ./utils/utils,
  ./evm/tracer/legacy_tracer,
  "."/[constants, vm_state, vm_types, transaction, core/executor],
  nimcrypto/utils as ncrutils,
  web3/conversions, ./launcher,
  results,
  ./beacon/web3_eth_conv

when defined(geth):
  import db/geth_db

  proc getParentHeader(db: CoreDbRef, header: BlockHeader): BlockHeader =
    db.blockHeader(header.blockNumber.truncate(uint64) - 1)

else:
  proc getParentHeader(self: CoreDbRef, header: BlockHeader): BlockHeader =
    self.getBlockHeader(header.parentHash)

proc setParentCtx(com: CommonRef, header: BlockHeader): CoreDbCtxRef =
  ## Adjust state root (mainly for `Aristo`)
  let
    parent = com.db.getParentHeader(header)
    ctx = com.db.ctxFromTx(parent.stateRoot).valueOr:
      raiseAssert "setParentCtx: " & $$error
  com.db.swapCtx ctx

proc reset(com: CommonRef, saveCtx: CoreDbCtxRef) =
  ## Reset context
  com.db.swapCtx(saveCtx).forget()


proc `%`(x: openArray[byte]): JsonNode =
  result = %toHex(x, false)

proc toJson(receipt: Receipt): JsonNode =
  result = newJObject()

  result["cumulativeGasUsed"] = %receipt.cumulativeGasUsed
  result["bloom"] = %receipt.bloom
  result["logs"] = %receipt.logs

  if receipt.hasStateRoot:
    result["root"] = %($receipt.stateRoot)
  else:
    result["status"] = %receipt.status

proc dumpReceipts*(chainDB: CoreDbRef, header: BlockHeader): JsonNode =
  result = newJArray()
  for receipt in chainDB.getReceipts(header.receiptRoot):
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
  for k, v in db.kvt:
    n[k.toHex(false)] = %v
  node["state"] = n

proc dumpMemoryDB*(node: JsonNode, kvt: TableRef[common.Blob, common.Blob]) =
  var n = newJObject()
  for k, v in kvt:
    n[k.toHex(false)] = %v
  node["state"] = n

proc dumpMemoryDB*(node: JsonNode, capture: CoreDbCaptRef|CoreDxCaptRef) =
  node.dumpMemoryDB capture.logDb

const
  senderName = "sender"
  recipientName = "recipient"
  minerName = "miner"
  uncleName = "uncle"
  internalTxName = "internalTx"

proc traceTransaction*(com: CommonRef, header: BlockHeader,
                       body: BlockBody, txIndex: int, tracerFlags: set[TracerFlags] = {}): JsonNode =
  let
    # we add a memory layer between backend/lower layer db
    # and capture state db snapshot during transaction execution
    saveCtx = com.setParentCtx(header)
    capture = com.db.newCapture.value
    tracerInst = newLegacyTracer(tracerFlags)
    captureCom = com.clone(capture.recorder)
    vmState = BaseVMState.new(header, captureCom)
  defer:
    capture.forget
    com.reset saveCtx

  var stateDb = vmState.stateDB

  if header.txRoot == EMPTY_ROOT_HASH: return newJNull()
  doAssert(body.transactions.calcTxRoot == header.txRoot)
  doAssert(body.transactions.len != 0)

  var
    gasUsed: GasInt
    before = newJArray()
    after = newJArray()
    stateDiff = %{"before": before, "after": after}
    beforeRoot: common.Hash256

  let
    miner = vmState.coinbase()

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient(sender)

    if idx == txIndex:
      vmState.tracer = tracerInst # only enable tracer on target tx
      before.captureAccount(stateDb, sender, senderName)
      before.captureAccount(stateDb, recipient, recipientName)
      before.captureAccount(stateDb, miner, minerName)
      stateDb.persist()
      stateDiff["beforeRoot"] = %($stateDb.rootHash)
      beforeRoot = stateDb.rootHash

    let rc = vmState.processTransaction(tx, sender, header)
    gasUsed = if rc.isOk: rc.value else: 0

    if idx == txIndex:
      after.captureAccount(stateDb, sender, senderName)
      after.captureAccount(stateDb, recipient, recipientName)
      after.captureAccount(stateDb, miner, minerName)
      tracerInst.removeTracedAccounts(sender, recipient, miner)
      stateDb.persist()
      stateDiff["afterRoot"] = %($stateDb.rootHash)
      break

  # internal transactions:
  var stateBefore = AccountsLedgerRef.init(capture.recorder, beforeRoot, com.pruneTrie)
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

proc dumpBlockState*(com: CommonRef, header: BlockHeader, body: BlockBody, dumpState = false): JsonNode =
  let
    parent = com.db.getParentHeader(header)
    saveCtx = com.setParentCtx(header)
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)
    # we only need a stack dump when scanning for internal transaction address
    captureFlags = {DisableMemory, DisableStorage, EnableAccount}
    tracerInst = newLegacyTracer(captureFlags)
    vmState = BaseVMState.new(header, captureCom, tracerInst)
    miner = vmState.coinbase()
  defer:
    capture.forget
    com.reset saveCtx

  var
    before = newJArray()
    after = newJArray()
    stateBefore = AccountsLedgerRef.init(capture.recorder, parent.stateRoot, com.pruneTrie)

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient(sender)
    before.captureAccount(stateBefore, sender, senderName & $idx)
    before.captureAccount(stateBefore, recipient, recipientName & $idx)

  before.captureAccount(stateBefore, miner, minerName)

  for idx, uncle in body.uncles:
    before.captureAccount(stateBefore, uncle.coinbase, uncleName & $idx)

  discard vmState.processBlock(header, body)

  var stateAfter = vmState.stateDB

  for idx, tx in body.transactions:
    let sender = tx.getSender
    let recipient = tx.getRecipient(sender)
    after.captureAccount(stateAfter, sender, senderName & $idx)
    after.captureAccount(stateAfter, recipient, recipientName & $idx)
    tracerInst.removeTracedAccounts(sender, recipient)

  after.captureAccount(stateAfter, miner, minerName)
  tracerInst.removeTracedAccounts(miner)

  for idx, uncle in body.uncles:
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

proc traceBlock*(com: CommonRef, header: BlockHeader, body: BlockBody, tracerFlags: set[TracerFlags] = {}): JsonNode =
  let
    saveCtx = com.setParentCtx(header)
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)
    tracerInst = newLegacyTracer(tracerFlags)
    vmState = BaseVMState.new(header, captureCom, tracerInst)
  defer:
    capture.forget
    com.reset saveCtx

  if header.txRoot == EMPTY_ROOT_HASH: return newJNull()
  doAssert(body.transactions.calcTxRoot == header.txRoot)
  doAssert(body.transactions.len != 0)

  var gasUsed = GasInt(0)

  for tx in body.transactions:
    let
      sender = tx.getSender
      rc = vmState.processTransaction(tx, sender, header)
    if rc.isOk:
      gasUsed = gasUsed + rc.value

  result = tracerInst.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableState notin tracerFlags:
    result.dumpMemoryDB(capture)

proc traceTransactions*(com: CommonRef, header: BlockHeader, blockBody: BlockBody): JsonNode =
  result = newJArray()
  for i in 0 ..< blockBody.transactions.len:
    result.add traceTransaction(com, header, blockBody, i, {DisableState})


proc dumpDebuggingMetaData*(vmState: BaseVMState, header: BlockHeader,
                            blockBody: BlockBody, launchDebugger = true) =
  let
    com = vmState.com
    blockNumber = header.blockNumber
    capture = com.db.newCapture.value
    captureCom = com.clone(capture.recorder)
    bloom = createBloom(vmState.receipts)
  defer:
    capture.forget()

  let blockSummary = %{
    "receiptsRoot": %("0x" & toHex(calcReceiptRoot(vmState.receipts).data)),
    "stateRoot": %("0x" & toHex(vmState.stateDB.rootHash.data)),
    "logsBloom": %("0x" & toHex(bloom))
  }

  var metaData = %{
    "blockNumber": %blockNumber.toHex,
    "txTraces": traceTransactions(captureCom, header, blockBody),
    "stateDump": dumpBlockState(captureCom, header, blockBody),
    "blockTrace": traceBlock(captureCom, header, blockBody, {DisableState}),
    "receipts": toJson(vmState.receipts),
    "block": blockSummary
  }

  metaData.dumpMemoryDB(capture)

  let jsonFileName = "debug" & $blockNumber & ".json"
  if launchDebugger:
    launchPremix(jsonFileName, metaData)
  else:
    writeFile(jsonFileName, metaData.pretty())
