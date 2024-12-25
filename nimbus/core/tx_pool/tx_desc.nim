# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/times,
  eth/eip1559,
  eth/common/transaction_utils,
  stew/sorted_set,
  ../../common/common,
  ../../evm/state,
  ../../evm/types,
  ../../db/ledger,
  ../../constants,
  ../../transaction,
  ../chain/forked_chain,
  ../pow/header,
  ../eip4844,
  ../casper,
  ../validate,
  ./tx_tabs,
  ./tx_item

from eth/common/eth_types_rlp import rlpHash

type
  TxPoolRef* = ref object
    vmState  : BaseVMState
    chain    : ForkedChainRef
    senderTab: TxSenderTab
    idTab    : TxIdTab

const
  MAX_POOL_SIZE = 5000
  MAX_TXS_PER_ACCOUNT = 100
  TX_ITEM_LIFETIME = initDuration(minutes = 60)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getBaseFee(com: CommonRef; parent: Header): Opt[UInt256] =
  ## Calculates the `baseFee` of the head assuming this is the parent of a
  ## new block header to generate.
  ## Post Merge rule
  Opt.some calcEip1599BaseFee(
    parent.gasLimit,
    parent.gasUsed,
    parent.baseFeePerGas.get(0.u256))

func getGasLimit(com: CommonRef; parent: Header): GasInt =
  ## Post Merge rule
  calcGasLimit1559(parent.gasLimit, desiredLimit = com.gasLimit)

proc setupVMState(com: CommonRef; parent: Header): BaseVMState =
  let
    pos = com.pos
    electra = com.isPragueOrLater(pos.timestamp)
    blockCtx = BlockContext(
      timestamp    : pos.timestamp,
      gasLimit     : getGasLimit(com, parent),
      baseFeePerGas: getBaseFee(com, parent),
      prevRandao   : pos.prevRandao,
      difficulty   : UInt256.zero(),
      coinbase     : pos.feeRecipient,
      excessBlobGas: calcExcessBlobGas(parent, electra),
      parentHash   : parent.blockHash,
    )

  BaseVMState.new(
    parent   = parent,
    blockCtx = blockCtx,
    com      = com)

template append(tab: var TxSenderTab, sn: TxSenderNonceRef) =
  tab[item.sender] = sn

proc getCurrentFromSenderTab(xp: TxPoolRef; item: TxItemRef): Opt[TxItemRef] =
  let sn = xp.senderTab.getOrDefault(item.sender)
  if sn.isNil:
    return Opt.none(TxItemRef)
  let current = sn.list.eq(item.nonce).valueOr:
    return Opt.none(TxItemRef)
  Opt.some(current.data)

proc removeFromSenderTab(xp: TxPoolRef; item: TxItemRef) =
  let sn = xp.senderTab.getOrDefault(item.sender)
  if sn.isNil:
    return
  discard sn.list.delete(item.nonce)

func alreadyKnown(xp: TxPoolRef, id: Hash32): bool =
  xp.idTab.getOrDefault(id).isNil.not

proc insertToSenderTab(xp: TxPoolRef; item: TxItemRef): Result[void, TxError] =
  ## Add transaction `item` to the list. The function has no effect if the
  ## transaction exists, already.
  var sn = xp.senderTab.getOrDefault(item.sender)
  if sn.isNil:
    # First insertion
    sn = TxSenderNonceRef.init()
    sn.insertOrReplace(item)
    xp.senderTab.append(sn)
    return ok()
  
  let current = xp.getCurrentFromSenderTab(item).valueOr:
    if sn.len >= MAX_TXS_PER_ACCOUNT:
      return err(txErrorSenderMaxTxs)

    # no equal sender/nonce,
    # insert into txpool
    sn.insertOrReplace(item)
    return ok()

  ?current.validateTxGasBump(item)

  # Replace current item,
  # insertion to idTab will be handled by addTx.
  xp.idTab.del(current.id)
  sn.insertOrReplace(item)
  ok()

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: TxPoolRef; chain: ForkedChainRef) =
  ## Constructor, returns new tx-pool descriptor.
  let head = chain.latestHeader
  xp.vmState = setupVMState(chain.com, head)
  xp.chain = chain

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func baseFee*(xp: TxPoolRef): GasInt =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  if xp.vmState.blockCtx.baseFeePerGas.isSome:
    xp.vmState.blockCtx.baseFeePerGas.get.truncate(GasInt)
  else:
    0.GasInt

func vmState*(xp: TxPoolRef): BaseVMState =
  xp.vmState

func nextFork*(xp: TxPoolRef): EVMFork =
  xp.vmState.fork

func gasLimit*(xp: TxPoolRef): GasInt =
  xp.vmState.blockCtx.gasLimit

func excessBlobGas*(xp: TxPoolRef): GasInt =
  xp.vmState.blockCtx.excessBlobGas

proc getBalance*(xp: TxPoolRef; account: Address): UInt256 =
  xp.vmState.ledger.getBalance(account)

proc getNonce*(xp: TxPoolRef; account: Address): AccountNonce =
  xp.vmState.ledger.getNonce(account)

func parentHash*(xp: TxPoolRef): Hash32 =
  xp.vmState.blockCtx.parentHash

template chain*(xp: TxPoolRef): ForkedChainRef =
  xp.chain

template com*(xp: TxPoolRef): CommonRef =
  xp.chain.com

func len*(xp: TxPoolRef): int =
  xp.idTab.len

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc updateVmState*(xp: TxPoolRef; parent: Header) =
  ## Reset transaction environment, e.g. before packing a new block
  xp.vmState = setupVMState(xp.vmState.com, parent)

proc classifyValid(xp: TxPoolRef; tx: Transaction, sender: Address): bool =
  if tx.tip(xp.baseFee) <= 0.GasInt:
    return false

  if tx.gasLimit > xp.gasLimit:
    return false

  # Ensure that the user was willing to at least pay the base fee
  # And to at least pay the current data gasprice
  if tx.txType >= TxEip1559:
    if tx.maxFeePerGas < xp.baseFee:
      return false

  if tx.txType == TxEip4844:
    let
      excessBlobGas = xp.excessBlobGas
      blobGasPrice = getBlobBaseFee(excessBlobGas, xp.nextFork >= FkPrague)
    if tx.maxFeePerBlobGas < blobGasPrice:
      return false

  # Check whether the worst case expense is covered by the price budget,
  let
    balance = xp.getBalance(sender)
    gasCost = tx.gasCost
  if balance < gasCost:
    return false
  let balanceOffGasCost = balance - gasCost
  if balanceOffGasCost < tx.value:
    return false

  # For legacy transactions check whether minimum gas price and tip are
  # high enough. These checks are optional.
  if tx.txType < TxEip1559:
    if tx.gasPrice < 0:
      return false

    # Fall back transaction selector scheme
    if tx.tip(xp.baseFee) < 1.GasInt:
      return false

  if tx.txType >= TxEip1559:
    if tx.tip(xp.baseFee) < 1.GasInt:
      return false

    if tx.maxFeePerGas < 1.GasInt:
      return false

  true

proc addTx*(xp: TxPoolRef, ptx: PooledTransaction): Result[void, TxError] =
  if not ptx.tx.validateChainId(xp.chain.com.chainId):
    return err(txErrorChainIdMismatch)

  if ptx.tx.txType == TxEip4844:
    ptx.validateBlobTransactionWrapper().isOkOr:
      return err(txErrorInvalidBlob)

  let id = ptx.rlpHash
  if xp.alreadyKnown(id):
    return err(txErrorAlreadyKnown)

  validateTxBasic(
    ptx.tx,
    xp.nextFork,
    # A new transaction of the next fork may be
    # coming before the fork activated
    validateFork = false).isOkOr:
    return err(txErrorBasicValidation)

  let
    sender = ptx.tx.recoverSender().valueOr:
      return err(txErrorInvalidSignature)
    nonce = xp.getNonce(sender)

  if ptx.tx.nonce < nonce:
    return err(txErrorNonceTooSmall)

  if not xp.classifyValid(ptx.tx, sender):
    return err(txErrorTxInvalid)

  if xp.idTab.len >= MAX_POOL_SIZE:
    return err(txErrorPoolIsFull)

  let item = TxItemRef.new(ptx, id, sender)
  ?xp.insertToSenderTab(item)
  xp.idTab[item.id] = item
  ok()

proc addTx*(xp: TxPoolRef, tx: Transaction): Result[void, TxError] =
  xp.addTx(PooledTransaction(tx: tx))

proc getItem*(xp: TxPoolRef, id: Hash32): Result[TxItemRef, TxError] =
  let item = xp.idTab.getOrDefault(id)
  if item.isNil:
    return err(txErrorItemNotFound)
  ok(item)

proc removeTx*(xp: TxPoolRef, id: Hash32) =
  let item = xp.getItem(id).valueOr:
    return
  xp.removeFromSenderTab(item)
  xp.idTab.del(id)

proc removeExpiredTxs*(xp: TxPoolRef, lifeTime: Duration = TX_ITEM_LIFETIME) =
  var expired = newSeqOfCap[Hash32](xp.idTab.len div 4)
  let now = utcNow()

  for txHash, item in xp.idTab:
    if now - item.time > lifeTime:
      expired.add txHash

  for txHash in expired:
    xp.removeTx(txHash)

iterator byPriceAndNonce*(xp: TxPoolRef): TxItemRef =
  for item in byPriceAndNonce(xp.senderTab,
      xp.vmState.ledger, xp.baseFee):
    yield item
