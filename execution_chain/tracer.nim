# Nimbus
# Copyright (c) 2019-2025 Status Research & Development GmbH
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
  ./ledger/[core_ledger, ledger],
  ./evm/[code_bytes, state, types],
  ./evm/tracer/legacy_tracer,
  ./transaction,
  ./utils/utils

type CaptCtxRef = ref object
  ledger: CoreDbRef               # not `nil`
  root: common.Hash32

const
  senderName = "sender"
  recipientName = "recipient"
  minerName = "miner"
  uncleName = "uncle"
  internalTxName = "internalTx"

proc toJson*(receipts: seq[Receipt]): JsonNode {.gcsafe.}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc init(
    T: type CaptCtxRef;
    com: CommonRef;
    root: common.Hash32;
      ): T =
  T(ledger: com.ledger, root: root)

proc init(
    T: type CaptCtxRef;
    com: CommonRef;
    topHeader: Header;
      ): T =
  let header = com.ledger.baseTxFrame().getBlockHeader(topHeader.parentHash).expect("top header parent exists")
  T.init(com, header.stateRoot)

# -------------------
proc `%`(x: addresses.Address | Bytes32 | Bytes256 | Hash32): JsonNode =
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
    chainDB: CoreDbTxRef;
    header: Header;
      ): JsonNode =
  result = newJArray()
  let receiptList = chainDB.getReceipts(header.receiptsRoot).
    expect("receipts exists")
  for receipt in receiptList:
    result.add receipt.toJson

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc captureAccount(
    n: JsonNode;
    ledger: LedgerRef;
    address: Address;
    name: string;
      ) =
  var jaccount = newJObject()
  jaccount["name"] = %name
  jaccount["address"] = %(address.to0xHex)

  let nonce = ledger.getNonce(address)
  let balance = ledger.getBalance(address)
  let codeHash = ledger.getCodeHash(address)
  let storageRoot = ledger.getStorageRoot(address)

  jaccount["nonce"] = %(conversions.`$`(nonce.Web3Quantity))
  jaccount["balance"] = %("0x" & balance.toHex)

  let code = ledger.getCode(address)
  jaccount["codeHash"] = %(codeHash.to0xHex)
  jaccount["code"] = %("0x" & code.bytes.toHex(true))
  jaccount["storageRoot"] = %(storageRoot.to0xHex)

  var storage = newJObject()
  for key, value in ledger.storage(address):
    storage["0x" & key.dumpHex] = %("0x" & value.dumpHex)
  jaccount["storage"] = storage

  n.add jaccount


proc traceTransactionImpl(
    com: CommonRef;
    header: Header;
    transactions: openArray[Transaction];
    txIndex: uint64;
    tracerFlags: set[TracerFlags] = {};
      ): JsonNode =
  if header.txRoot == EMPTY_ROOT_HASH:
    return newJNull()

  let
    tracerInst = newLegacyTracer(tracerFlags)
    cc = CaptCtxRef.init(com, header)
    txFrame = com.ledger.baseTxFrame()
    parent = txFrame.getBlockHeader(header.parentHash).valueOr:
      return newJNull()
    vmState = BaseVMState.new(parent, header, com, txFrame, storeSlotHash = true)
    ledger = vmState.ledger

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
      before.captureAccount(ledger, sender, senderName)
      before.captureAccount(ledger, recipient, recipientName)
      before.captureAccount(ledger, miner, minerName)
      ledger.persist()
      stateDiff["beforeRoot"] = %(ledger.getStateRoot().toHex)
      stateCtx = CaptCtxRef.init(com, ledger.getStateRoot())

    let rc = vmState.processTransaction(tx, sender, header)
    gasUsed = if rc.isOk: rc.value.gasUsed else: 0

    if idx.uint64 == txIndex:
      after.captureAccount(ledger, sender, senderName)
      after.captureAccount(ledger, recipient, recipientName)
      after.captureAccount(ledger, miner, minerName)
      tracerInst.removeTracedAccounts(sender, recipient, miner)
      ledger.persist()
      stateDiff["afterRoot"] = %(ledger.getStateRoot().toHex)
      break

  # internal transactions:
  let
    cx = stateCtx
    ldgBefore = LedgerRef.init(com.ledger.baseTxFrame(), storeSlotHash = true)

  for idx, acc in tracedAccountsPairs(tracerInst):
    before.captureAccount(ldgBefore, acc, internalTxName & $idx)

  for idx, acc in tracedAccountsPairs(tracerInst):
    after.captureAccount(ledger, acc, internalTxName & $idx)

  result = tracerInst.getTracingResult()
  result["gas"] = %gasUsed

  if TracerFlags.DisableStateDiff notin tracerFlags:
    result["stateDiff"] = stateDiff

proc dumpBlockStateImpl(
    com: CommonRef;
    blk: EthBlock;
      ): JsonNode =
  template header: Header = blk.header

  let
    cc = CaptCtxRef.init(com, header)

    # only need a stack dump when scanning for internal transaction address
    captureFlags = {DisableMemory, DisableStorage, EnableAccount}
    tracerInst = newLegacyTracer(captureFlags)
    txFrame = com.ledger.baseTxFrame()
    parent = txFrame.getBlockHeader(header.parentHash).valueOr:
      return newJNull()
    vmState = BaseVMState.new(parent, header, com, txFrame, tracerInst, storeSlotHash = true)
    miner = vmState.coinbase()

  var
    before = newJArray()
    after = newJArray()
    stateBefore = LedgerRef.init(com.ledger.baseTxFrame(), storeSlotHash = true)

  for idx, tx in blk.transactions:
    let sender = tx.recoverSender().expect("valid signature")
    let recipient = tx.getRecipient(sender)
    before.captureAccount(stateBefore, sender, senderName & $idx)
    before.captureAccount(stateBefore, recipient, recipientName & $idx)

  before.captureAccount(stateBefore, miner, minerName)

  for idx, uncle in blk.uncles:
    before.captureAccount(stateBefore, uncle.coinbase, uncleName & $idx)

  discard vmState.processBlock(blk)

  var stateAfter = vmState.ledger

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

proc traceBlockImpl(
    com: CommonRef;
    blk: EthBlock;
    tracerFlags: set[TracerFlags] = {};
      ): JsonNode =
  template header: Header = blk.header

  let
    cc = CaptCtxRef.init(com, header)
    tracerInst = newLegacyTracer(tracerFlags)
    # Tracer needs a database where the reverse slot hash table has been set up
    txFrame = com.ledger.baseTxFrame()
    parent = txFrame.getBlockHeader(header.parentHash).valueOr:
      return newJNull()
    vmState = BaseVMState.new(parent, header, com, txFrame, tracerInst, storeSlotHash = true)

  if header.txRoot == EMPTY_ROOT_HASH: return newJNull()
  doAssert(blk.transactions.calcTxRoot == header.txRoot)
  doAssert(blk.transactions.len != 0)

  var gasUsed = GasInt(0)

  for tx in blk.transactions:
    let
      sender = tx.recoverSender().expect("valid signature")
      rc = vmState.processTransaction(tx, sender, header)
    if rc.isOk:
      gasUsed = gasUsed + rc.value.gasUsed

  result = tracerInst.getTracingResult()
  result["gas"] = %gasUsed

proc traceTransactionsImpl(
    com: CommonRef;
    header: Header;
    transactions: openArray[Transaction];
      ): JsonNode =
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
  com.traceBlockImpl(blk, tracerFlags)

proc toJson*(receipts: seq[Receipt]): JsonNode =
  result = newJArray()
  for receipt in receipts:
    result.add receipt.toJson

proc dumpReceipts*(chainDB: CoreDbTxRef, header: Header): JsonNode =
  chainDB.dumpReceiptsImpl header

proc traceTransaction*(
    com: CommonRef;
    header: Header;
    txs: openArray[Transaction];
    txIndex: uint64;
    tracerFlags: set[TracerFlags] = {};
      ): JsonNode =
  com.traceTransactionImpl(header, txs, txIndex,tracerFlags)

proc dumpBlockState*(
    com: CommonRef;
    blk: EthBlock;
      ): JsonNode =
  com.dumpBlockStateImpl(blk)

proc traceTransactions*(
    com: CommonRef;
    header: Header;
    transactions: openArray[Transaction];
      ): JsonNode =
  com.traceTransactionsImpl(header, transactions)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
