# Nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  chronicles,
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

logScope:
  topics = "txpool"

type
  TxPoolRef* = ref object
    vmState  : BaseVMState
    chain    : ForkedChainRef
    senderTab: TxSenderTab
    idTab    : TxIdTab
    rmHash   : Hash32

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

proc setupVMState(com: CommonRef; parent: Header, parentHash: Hash32): BaseVMState =
  let
    pos = com.pos
    electra = com.isPragueOrLater(pos.timestamp)

  BaseVMState.new(
    parent   = parent,
    blockCtx = BlockContext(
      timestamp    : pos.timestamp,
      gasLimit     : getGasLimit(com, parent),
      baseFeePerGas: getBaseFee(com, parent),
      prevRandao   : pos.prevRandao,
      difficulty   : UInt256.zero(),
      coinbase     : pos.feeRecipient,
      excessBlobGas: calcExcessBlobGas(parent, electra),
      parentHash   : parentHash,
    ),
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

func baseFee(xp: TxPoolRef): GasInt =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  if xp.vmState.blockCtx.baseFeePerGas.isSome:
    xp.vmState.blockCtx.baseFeePerGas.get.truncate(GasInt)
  else:
    0.GasInt

func gasLimit(xp: TxPoolRef): GasInt =
  xp.vmState.blockCtx.gasLimit

func excessBlobGas(xp: TxPoolRef): GasInt =
  xp.vmState.blockCtx.excessBlobGas

proc getBalance(xp: TxPoolRef; account: Address): UInt256 =
  xp.vmState.ledger.getBalance(account)

proc getNonce(xp: TxPoolRef; account: Address): AccountNonce =
  xp.vmState.ledger.getNonce(account)

proc classifyValid(xp: TxPoolRef; tx: Transaction, sender: Address): bool =
  if tx.tip(xp.baseFee) <= 0.GasInt:
    warn "Invalid Transaction: No tip"
    return false

  if tx.gasLimit > xp.gasLimit:
    warn "Invalid Transaction: Gas limit too high", 
      txGasLimit = tx.gasLimit, 
      gasLimit = xp.gasLimit
    return false

  # Ensure that the user was willing to at least pay the base fee
  # And to at least pay the current data gasprice
  if tx.txType >= TxEip1559:
    if tx.maxFeePerGas < xp.baseFee:
      warn "Invalid Transaction: maxFeePerGas lower than baseFee", 
        maxFeePerGas = tx.maxFeePerGas, 
        baseFee = xp.baseFee
      return false

  if tx.txType == TxEip4844:
    let
      excessBlobGas = xp.excessBlobGas
      electra = xp.vmState.fork >= FkPrague
      blobGasPrice = getBlobBaseFee(excessBlobGas, electra)
    if tx.maxFeePerBlobGas < blobGasPrice:
      warn "Invalid Transaction: maxFeePerBlobGas lower than blobGasPrice", 
        maxFeePerBlobGas = tx.maxFeePerBlobGas, 
        blobGasPrice = blobGasPrice
      return false

  # Check whether the worst case expense is covered by the price budget,
  let
    balance = xp.getBalance(sender)
    gasCost = tx.gasCost
  if balance < gasCost:
    warn "Invalid Transaction: Insufficient balance for gas cost", 
      balance = balance, 
      gasCost = gasCost
    return false
  let balanceOffGasCost = balance - gasCost
  if balanceOffGasCost < tx.value:
    warn "Invalid Transaction: Insufficient balance for tx value", 
      balanceOffGasCost = balanceOffGasCost, 
      txValue = tx.value
    return false

  # For legacy transactions check whether minimum gas price and tip are
  # high enough. These checks are optional.
  if tx.txType < TxEip1559:
    if tx.gasPrice < 0:
      warn "Invalid Transaction: Legacy transaction with invalid gas price", 
        gasPrice = tx.gasPrice
      return false

    # Fall back transaction selector scheme
    if tx.tip(xp.baseFee) < 1.GasInt:
      warn "Invalid Transaction: Legacy transaction with tip lower than 1"
      return false

  if tx.txType >= TxEip1559:
    if tx.tip(xp.baseFee) < 1.GasInt:
      warn "Invalid Transaction: EIP-1559 transaction with tip lower than 1"
      return false

    if tx.maxFeePerGas < 1.GasInt:
      warn "Invalid Transaction: EIP-1559 transaction with maxFeePerGas lower than 1"
      return false
  
  debug "Valid Transaction",
    txType = tx.txType, 
    sender = sender,
    gasLimit = tx.gasLimit, 
    gasPrice = tx.gasPrice, 
    value = tx.value
  true

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: TxPoolRef; chain: ForkedChainRef) =
  ## Constructor, returns new tx-pool descriptor.
  xp.vmState = setupVMState(chain.com,
    chain.latestHeader, chain.latestHash)
  xp.chain = chain
  xp.rmHash = chain.latestHash

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func vmState*(xp: TxPoolRef): BaseVMState =
  xp.vmState

func nextFork*(xp: TxPoolRef): EVMFork =
  xp.vmState.fork

template chain*(xp: TxPoolRef): ForkedChainRef =
  xp.chain

template com*(xp: TxPoolRef): CommonRef =
  xp.chain.com

func len*(xp: TxPoolRef): int =
  xp.idTab.len

# ------------------------------------------------------------------------------
# Public functions, but private to TxPool, not exported to user
# ------------------------------------------------------------------------------

func rmHash*(xp: TxPoolRef): Hash32 =
  xp.rmHash

func `rmHash=`*(xp: TxPoolRef, val: Hash32) =
  xp.rmHash = val

proc updateVmState*(xp: TxPoolRef) =
  ## Reset transaction environment, e.g. before packing a new block
  xp.vmState = setupVMState(xp.chain.com,
    xp.chain.latestHeader, xp.chain.latestHash)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

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

proc addTx*(xp: TxPoolRef, ptx: PooledTransaction): Result[void, TxError] =
  if not ptx.tx.validateChainId(xp.chain.com.chainId):
    debug "Transaction chain id mismatch", 
      txChainId = ptx.tx.chainId, 
      chainId = xp.chain.com.chainId
    return err(txErrorChainIdMismatch)
  
  let id = ptx.rlpHash

  if ptx.tx.txType == TxEip4844:
    ptx.validateBlobTransactionWrapper().isOkOr:
      warn "Invalid Transaction: Blob transaction wrapper validation failed", 
        tx = ptx.tx,
        error = error
      return err(txErrorInvalidBlob)

  if xp.alreadyKnown(id):
    debug "Transaction already known", txHash = id
    return err(txErrorAlreadyKnown)

  validateTxBasic(
    ptx.tx,
    xp.nextFork,
    validateFork = true).isOkOr:
    warn "Invalid Transaction: Basic validation failed", 
      txHash = id,
      error = error
    return err(txErrorBasicValidation)

  let
    sender = ptx.tx.recoverSender().valueOr:
      return err(txErrorInvalidSignature)
    nonce = xp.getNonce(sender)

  # The downside of this arrangement is the ledger is not
  # always up to date. The comparison below
  # does not always filter out transactions with lower nonce.
  # But it will not affect the correctness of the subsequent
  # algorithm. In `byPriceAndNonce`, once again transactions
  # with lower nonce are filtered out, for different reason.
  # But the end result is same, transactions packed in a block only
  # have consecutive nonces >= than current account's nonce.
  #
  # Calling something like:
  # if xp.chain.latestHash != xp.parentHash:
  #   xp.updateVmState()
  # maybe can solve the accuracy but it is quite expensive.
  if ptx.tx.nonce < nonce:
    warn "Transaction Rejected: Nonce too small", 
      txNonce = ptx.tx.nonce, 
      nonce = nonce,
      sender = sender
    return err(txErrorNonceTooSmall)

  if not xp.classifyValid(ptx.tx, sender):
    return err(txErrorTxInvalid)

  if xp.idTab.len >= MAX_POOL_SIZE:
    xp.removeExpiredTxs()

  if xp.idTab.len >= MAX_POOL_SIZE:
    warn "Transaction Rejected: TxPool is full"
    return err(txErrorPoolIsFull)

  let item = TxItemRef.new(ptx, id, sender)
  ?xp.insertToSenderTab(item)
  xp.idTab[item.id] = item

  info "Transaction added to txpool", 
    txHash = id,
    sender = sender,
    recipient = ptx.tx.getRecipient(sender),
    nonce = ptx.tx.nonce,
    gasPrice = ptx.tx.gasPrice,
    value = ptx.tx.value

  ok()

proc addTx*(xp: TxPoolRef, tx: Transaction): Result[void, TxError] =
  xp.addTx(PooledTransaction(tx: tx))

iterator byPriceAndNonce*(xp: TxPoolRef): TxItemRef =
  for item in byPriceAndNonce(xp.senderTab, xp.idTab,
      xp.vmState.ledger, xp.baseFee):
    yield item
