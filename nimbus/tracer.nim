# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/[strutils, json],
  nimcrypto/utils as ncrutils,
  results,
  web3/conversions,
  eth/common/transaction_utils,
  ./beacon/web3_eth_conv,
  ./common/common,
  ./constants,
  ./core/executor,
  ./db/[core_db, ledger],
  ./evm/[code_bytes, state, types],
  ./evm/tracer/legacy_tracer,
  ./transaction,
  ./utils/utils

when not CoreDbEnableCaptJournal:
  {.error: "Compiler flag missing for tracer, try -d:dbjapi_enabled".}

type
  CaptCtxRef = ref object
    db: CoreDbRef               # not `nil`
    root: common.Hash32
    ctx: CoreDbCtxRef           # not `nil`
    cpt: CoreDbCaptRef          # not `nil`
    restore: CoreDbCtxRef       # `nil` unless `ctx` activated

const
  senderName = "sender"
  recipientName = "recipient"
  minerName = "miner"
  uncleName = "uncle"
  internalTxName = "internalTx"

proc dumpMemoryDB*(node: JsonNode, cpt: CoreDbCaptRef) {.gcsafe.}
proc toJson*(receipts: seq[Receipt]): JsonNode {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template safeTracer(info: string; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert info & " name=" & $e.name & " msg=" & e.msg

# -------------------

proc init(
    T: type CaptCtxRef;
    com: CommonRef;
    root: common.Hash32;
      ): T =
  let ctx = block:
    let rc = com.db.ctx.newCtxByKey(root)
    if rc.isErr:
      raiseAssert "newCptCtx: " & $$rc.error
    rc.value
  T(db: com.db, root: root, cpt: com.db.pushCapture(), ctx: ctx)

proc init(
    T: type CaptCtxRef;
    com: CommonRef;
    topHeader: Header;
      ): T
      {.raises: [CatchableError].} =
  T.init(com, com.db.getBlockHeader(topHeader.parentHash).stateRoot)

proc activate(cc: CaptCtxRef): CaptCtxRef {.discardable.} =
  ## Install/activate new context `cc.ctx`, old one in `cc.restore`
  doAssert not cc.isNil
  doAssert cc.restore.isNil # otherwise activated, already
  cc.restore = cc.ctx.swapCtx cc.db
  cc

proc release(cc: CaptCtxRef) =
  if not cc.restore.isNil:             # switch to original context (if any)
    let ctx = cc.restore.swapCtx(cc.db)
    doAssert ctx == cc.ctx
  cc.ctx.forget()                      # dispose
  cc.cpt.pop()                         # discard top layer of actions tracer

# -------------------

proc `%`(x: addresses.Address|Bytes32|Bytes256|Hash32): JsonNode =
  result = %toHex(x)

proc toJson(receipt: Receipt): JsonNode =
  result = newJObject()

  result["cumulativeGasUsed"] = %receipt.cumulativeGasUsed
  result["bloom"] = %receipt.logsBloom
  result["logs"] = %receipt.logs

  if receipt.hasStateRoot:
    result["root"] = %(receipt.stateRoot.toHex)
  else:
    result["status"] = %receipt.status

proc dumpReceiptsImpl(
    chainDB: CoreDbRef;
    header: Header;
      ): JsonNode
      {.raises: [CatchableError].} =
  result = newJArray()
  for receipt in chainDB.getReceipts(header.receiptsRoot):
    result.add receipt.toJson

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc captureAccount(
    n: JsonNode;
    db: LedgerRef;
    address: EthAddress;
    name: string;
      ) =
  var jaccount = newJObject()
  jaccount["name"] = %name
  jaccount["address"] = %(address.to0xHex)

  let nonce = db.getNonce(address)
  let balance = db.getBalance(address)
  let codeHash = db.getCodeHash(address)
  let storageRoot = db.getStorageRoot(address)

  jaccount["nonce"] = %(conversions.`$`(nonce.Web3Quantity))
  jaccount["balance"] = %("0x" & balance.toHex)

  let code = db.getCode(address)
  jaccount["codeHash"] = %(codeHash.to0xHex)
  jaccount["code"] = %("0x" & code.bytes.toHex(true))
  jaccount["storageRoot"] = %(storageRoot.to0xHex)

  var storage = newJObject()
  for key, value in db.storage(address):
    storage["0x" & key.dumpHex] = %("0x" & value.dumpHex)
  jaccount["storage"] = storage

  n.add jaccount


proc traceTransactionImpl(
    com: CommonRef;
    header: Header;
    transactions: openArray[Transaction];
    txIndex: uint64;
    tracerFlags: set[TracerFlags] = {};
      ): JsonNode
      {.raises: [CatchableError].}=
  if header.txRoot == EMPTY_ROOT_HASH:
    return newJNull()

  let
    tracerInst = newLegacyTracer(tracerFlags)
    cc = activate CaptCtxRef.init(com, header)
    vmState = BaseVMState.new(header, com, storeSlotHash = true).valueOr: return newJNull()
    stateDb = vmState.stateDB

  defer: cc.release()

  doAssert(transactions.calcTxRoot == header.txRoot)
  doAssert(transactions.len != 0)

  var
    gasUsed: GasInt
    before = newJArray()
    after = newJArray()
    stateDiff = %{"before": before, "after": after}
    stateCtx = CaptCtxRef(nil)

  let
    miner = vmState.coinbase()

  for idx, tx in transactions:
    let sender = tx.recoverSender().expect("valid signature")
    let recipient = tx.getRecipient(sender)

    if idx.uint64 == txIndex:
      vmState.tracer = tracerInst # only enable tracer on target tx
      before.captureAccount(stateDb, sender, senderName)
      before.captureAccount(stateDb, recipient, recipientName)
      before.captureAccount(stateDb, miner, minerName)
      stateDb.persist()
      stateDiff["beforeRoot"] = %(stateDb.rootHash.toHex)
      discard com.db.ctx.getAccounts.state(updateOk=true) # lazy hashing!
      stateCtx = CaptCtxRef.init(com, stateDb.rootHash)

    let rc = vmState.processTransaction(tx, sender, header)
    gasUsed = if rc.isOk: rc.value else: 0

    if idx.uint64 == txIndex:
      discard com.db.ctx.getAccounts.state(updateOk=true) # lazy hashing!
      after.captureAccount(stateDb, sender, senderName)
      after.captureAccount(stateDb, recipient, recipientName)
      after.captureAccount(stateDb, miner, minerName)
      tracerInst.removeTracedAccounts(sender, recipient, miner)
      stateDb.persist()
      stateDiff["afterRoot"] = %(stateDb.rootHash.toHex)
      break

  # internal transactions:
  let
    cx = activate stateCtx
    ldgBefore = LedgerRef.init(com.db, cx.root, storeSlotHash = true)
  defer: cx.release()

  for idx, acc in tracedAccountsPairs(tracerInst):
    before.captureAccount(ldgBefore, acc, internalTxName & $idx)

  for idx, acc in tracedAccountsPairs(tracerInst):
    after.captureAccount(stateDb, acc, internalTxName & $idx)

  result = tracerInst.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableStateDiff notin tracerFlags:
    result["stateDiff"] = stateDiff

  # now we dump captured state db
  if TracerFlags.DisableState notin tracerFlags:
    result.dumpMemoryDB(cx.cpt)


proc dumpBlockStateImpl(
    com: CommonRef;
    blk: EthBlock;
    dumpState = false;
      ): JsonNode
      {.raises: [CatchableError].} =
  template header: Header = blk.header

  let
    cc = activate CaptCtxRef.init(com, header)
    parent = com.db.getBlockHeader(header.parentHash)

    # only need a stack dump when scanning for internal transaction address
    captureFlags = {DisableMemory, DisableStorage, EnableAccount}
    tracerInst = newLegacyTracer(captureFlags)
    vmState = BaseVMState.new(header, com, tracerInst, storeSlotHash = true).valueOr:
      return newJNull()
    miner = vmState.coinbase()

  defer: cc.release()

  var
    before = newJArray()
    after = newJArray()
    stateBefore = LedgerRef.init(com.db, parent.stateRoot, storeSlotHash = true)

  for idx, tx in blk.transactions:
    let sender = tx.recoverSender().expect("valid signature")
    let recipient = tx.getRecipient(sender)
    before.captureAccount(stateBefore, sender, senderName & $idx)
    before.captureAccount(stateBefore, recipient, recipientName & $idx)

  before.captureAccount(stateBefore, miner, minerName)

  for idx, uncle in blk.uncles:
    before.captureAccount(stateBefore, uncle.coinbase, uncleName & $idx)

  discard vmState.processBlock(blk)

  var stateAfter = vmState.stateDB

  for idx, tx in blk.transactions:
    let sender = tx.recoverSender().expect("valid signature")
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
    result.dumpMemoryDB(cc.cpt)


proc traceBlockImpl(
    com: CommonRef;
    blk: EthBlock;
    tracerFlags: set[TracerFlags] = {};
      ): JsonNode
      {.raises: [CatchableError].} =
  template header: Header = blk.header

  let
    cc = activate CaptCtxRef.init(com, header)
    tracerInst = newLegacyTracer(tracerFlags)
    # Tracer needs a database where the reverse slot hash table has been set up
    vmState = BaseVMState.new(header, com, tracerInst, storeSlotHash = true).valueOr:
      return newJNull()

  defer: cc.release()

  if header.txRoot == EMPTY_ROOT_HASH: return newJNull()
  doAssert(blk.transactions.calcTxRoot == header.txRoot)
  doAssert(blk.transactions.len != 0)

  var gasUsed = GasInt(0)

  for tx in blk.transactions:
    let
      sender = tx.recoverSender().expect("valid signature")
      rc = vmState.processTransaction(tx, sender, header)
    if rc.isOk:
      gasUsed = gasUsed + rc.value

  result = tracerInst.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableState notin tracerFlags:
    result.dumpMemoryDB(cc.cpt)

proc traceTransactionsImpl(
    com: CommonRef;
    header: Header;
    transactions: openArray[Transaction];
      ): JsonNode
      {.raises: [CatchableError].} =
  result = newJArray()
  for i in 0 ..< transactions.len:
    result.add traceTransactionImpl(
      com, header, transactions, i.uint64, {DisableState})

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc traceBlock*(
    com: CommonRef;
    blk: EthBlock;
    tracerFlags: set[TracerFlags] = {};
      ): JsonNode =
  "traceBlock".safeTracer:
    result = com.traceBlockImpl(blk, tracerFlags)

proc toJson*(receipts: seq[Receipt]): JsonNode =
  result = newJArray()
  for receipt in receipts:
    result.add receipt.toJson

proc dumpMemoryDB*(node: JsonNode, cpt: CoreDbCaptRef) =
  var n = newJObject()
  for (k,v) in cpt.kvtLog:
    n[k.toHex(false)] = %v
  node["state"] = n

proc dumpReceipts*(chainDB: CoreDbRef, header: Header): JsonNode =
  "dumpReceipts".safeTracer:
    result = chainDB.dumpReceiptsImpl header

proc traceTransaction*(
    com: CommonRef;
    header: Header;
    txs: openArray[Transaction];
    txIndex: uint64;
    tracerFlags: set[TracerFlags] = {};
      ): JsonNode =
  "traceTransaction".safeTracer:
      result = com.traceTransactionImpl(header, txs, txIndex,tracerFlags)

proc dumpBlockState*(
    com: CommonRef;
    blk: EthBlock;
    dumpState = false;
      ): JsonNode =
  "dumpBlockState".safeTracer:
    result = com.dumpBlockStateImpl(blk, dumpState)

proc traceTransactions*(
    com: CommonRef;
    header: Header;
    transactions: openArray[Transaction];
      ): JsonNode =
  "traceTransactions".safeTracer:
    result = com.traceTransactionsImpl(header, transactions)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
