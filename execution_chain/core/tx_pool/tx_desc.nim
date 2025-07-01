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
  std/[times, tables],
  eth/eip1559,
  eth/common/transaction_utils,
  stew/sorted_set,
  web3/engine_api_types,
  ../../common/common,
  ../../evm/state,
  ../../evm/types,
  ../../db/ledger,
  ../../constants,
  ../../transaction,
  ../chain/forked_chain,
  ../pow/header,
  ../eip4844,
  ../eip7594,
  ../validate,
  ../pooled_txs,
  ./tx_tabs,
  ./tx_item

from eth/common/eth_types_rlp import rlpHash

logScope:
  topics = "txpool"

type
  PosPayloadAttr = object
    feeRecipient: Address
    timestamp   : EthTime
    prevRandao  : Bytes32
    withdrawals : seq[Withdrawal] ## EIP-4895
    beaconRoot  : Hash32 ## EIP-4788

  TxPoolRef* = ref object
    vmState  : BaseVMState
    chain    : ForkedChainRef
    senderTab: TxSenderTab
    idTab    : TxIdTab
    rmHash   : Hash32
    pos      : PosPayloadAttr
    blobTab  : BlobLookupTab

const
  MAX_POOL_SIZE = 5000
  MAX_TXS_PER_ACCOUNT = 100
  TX_ITEM_LIFETIME = initDuration(minutes = 60)
  TX_MAX_SIZE* = 128 * 1024
  # BLOB_TX_MAX_SIZE is the maximum size a single transaction can have, outside
  # the included blobs. Since blob transactions are pulled instead of pushed,
  # and only a small metadata is kept in ram, there is no critical limit that
  # should be enforced. Still, capping it to some sane limit can never hurt.
  BLOB_TX_MAX_SIZE* = 1024 * 1024

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

proc setupVMState(com: CommonRef;
                  parent: Header,
                  parentHash: Hash32,
                  pos: PosPayloadAttr,
                  parentFrame: CoreDbTxRef): BaseVMState =
  let
    fork = com.toEVMFork(pos.timestamp)

  BaseVMState.new(
    parent   = parent,
    blockCtx = BlockContext(
      timestamp    : pos.timestamp,
      gasLimit     : getGasLimit(com, parent),
      baseFeePerGas: getBaseFee(com, parent),
      prevRandao   : pos.prevRandao,
      difficulty   : UInt256.zero(),
      coinbase     : pos.feeRecipient,
      excessBlobGas: com.calcExcessBlobGas(parent, fork),
      parentHash   : parentHash,
    ),
    txFrame = parentFrame.txFrameBegin(),
    com     = com)

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
  xp.blobTab.removeLookup(item)
  sn.insertOrReplace(item)
  ok()

func baseFee(xp: TxPoolRef): GasInt =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  if xp.vmState.blockCtx.baseFeePerGas.isSome:
    xp.vmState.blockCtx.baseFeePerGas.get.truncate(GasInt)
  else:
    0.GasInt

func excessBlobGas(xp: TxPoolRef): GasInt =
  xp.vmState.blockCtx.excessBlobGas

proc getBalance(xp: TxPoolRef; account: Address): UInt256 =
  xp.vmState.ledger.getBalance(account)

proc getNonce(xp: TxPoolRef; account: Address): AccountNonce =
  xp.vmState.ledger.getNonce(account)

proc classifyValid(xp: TxPoolRef; tx: Transaction, sender: Address, blobsBundle: BlobsBundle): bool =

  if tx.gasLimit > TX_GAS_LIMIT:
    debug "Invalid transaction: Gas limit too high",
      txGasLimit = tx.gasLimit,
      gasLimit = TX_GAS_LIMIT
    return false

  if tx.txType == TxEip4844:
    let
      excessBlobGas = xp.excessBlobGas
      blobGasPrice = getBlobBaseFee(excessBlobGas, xp.vmState.com, xp.vmState.fork)
    if tx.maxFeePerBlobGas < blobGasPrice:
      debug "Invalid transaction: maxFeePerBlobGas lower than blobGasPrice",
        maxFeePerBlobGas = tx.maxFeePerBlobGas,
        blobGasPrice = blobGasPrice
      return false

  # Check whether the worst case expense is covered by the price budget,
  let
    balance = xp.getBalance(sender)
    gasCost = tx.gasCost
  if balance < gasCost:
    debug "Invalid transaction: Insufficient balance for gas cost",
      balance = balance,
      gasCost = gasCost
    return false
  let balanceOffGasCost = balance - gasCost
  if balanceOffGasCost < tx.value:
    debug "Invalid transaction: Insufficient balance for tx value",
      balanceOffGasCost = balanceOffGasCost,
      txValue = tx.value
    return false

  # For legacy transactions check whether minimum gas price and tip are
  # high enough. These checks are optional.
  if tx.txType < TxEip1559:
    if tx.gasPrice < 0:
      debug "Invalid transaction: Legacy transaction with invalid gas price",
        gasPrice = tx.gasPrice
      return false

    # Fall back transaction selector scheme
    if tx.tip(xp.baseFee) < 1.GasInt:
      debug "Invalid transaction: Legacy transaction with tip lower than 1"
      return false

  if tx.txType >= TxEip1559:
    # Ensure that the user was willing to at least pay the base fee
    # And to at least pay the current data gasprice
    if tx.maxFeePerGas < xp.baseFee:
      debug "Invalid transaction: maxFeePerGas lower than baseFee",
        maxFeePerGas = tx.maxFeePerGas,
        baseFee = xp.baseFee
      return false

    # No tip checking as tip is optional after EIP-1559
    if tx.maxFeePerGas < 1.GasInt:
      debug "Invalid transaction: EIP-1559 transaction with maxFeePerGas lower than 1"
      return false

  if blobsBundle.isNil:
    debug "Valid transaction",
      txType = tx.txType,
      sender = sender,
      gasLimit = tx.gasLimit,
      gasPrice = tx.gasPrice,
      value = tx.value
  else:
    debug "Valid transaction",
      txType = tx.txType,
      sender = sender,
      gasLimit = tx.gasLimit,
      gasPrice = tx.gasPrice,
      value = tx.value,
      numBlobs = blobsBundle.blobs.len,
      wrapperVersion = blobsBundle.wrapperVersion

  true

proc validateBlobTransactionWrapper(tx: PooledTransaction, fork: EVMFork):
                                     Result[void, string] {.raises: [].} =
  if tx.blobsBundle.isNil:
    return err("tx wrapper is none")

  case tx.blobsBundle.wrapperVersion
  of WrapperVersionEIP4844:
    if fork >= FkOsaka:
      return err("Blobsbundle version 0 expect fork before Osaka")
    validateBlobTransactionWrapper4844(tx)
  of WrapperVersionEIP7594:
    # Allow this kind of Blob when Prague still active.
    # Because after transitioned to Osaka or later,
    # it can be included in the next fork
    if fork < FkPrague:
      return err("Blobsbundle version 1 expect Prague or later")
    validateBlobTransactionWrapper7594(tx)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: TxPoolRef; chain: ForkedChainRef) =
  ## Constructor, returns new tx-pool descriptor.
  xp.pos.timestamp = chain.latestHeader.timestamp
  xp.vmState = setupVMState(chain.com,
    chain.latestHeader, chain.latestHash,
    xp.pos, chain.txFrame(chain.latestHash))
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
    xp.chain.latestHeader, xp.chain.latestHash,
    xp.pos, xp.chain.txFrame(xp.chain.latestHash))

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------
proc contains*(xp: TxPoolRef, id: Hash32): bool =
  xp.idTab.hasKey(id)

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
  xp.blobTab.removeLookup(item)

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

  let (size, id) = getEncodedLengthAndHash(ptx.tx)

  if ptx.tx.txType == TxEip4844:
    if size > BLOB_TX_MAX_SIZE:
      return err(txErrorOversized)

    ptx.validateBlobTransactionWrapper(xp.nextFork).isOkOr:
      debug "Invalid transaction: Blob transaction wrapper validation failed",
        tx = ptx.tx,
        error = error
      return err(txErrorInvalidBlob)
  else:
    if size > TX_MAX_SIZE:
      return err(txErrorOversized)

  if xp.alreadyKnown(id):
    debug "Transaction already known", txHash = id
    return err(txErrorAlreadyKnown)

  validateTxBasic(
    xp.com,
    ptx.tx,
    xp.nextFork,
    validateFork = true).isOkOr:
    debug "Invalid transaction: Basic validation failed",
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
    debug "Transaction rejected: Nonce too small",
      txNonce = ptx.tx.nonce,
      nonce = nonce,
      sender = sender
    return err(txErrorNonceTooSmall)

  if not xp.classifyValid(ptx.tx, sender, ptx.blobsBundle):
    return err(txErrorTxInvalid)

  if xp.idTab.len >= MAX_POOL_SIZE:
    xp.removeExpiredTxs()

  if xp.idTab.len >= MAX_POOL_SIZE:
    debug "Transaction rejected: txpool is full"
    return err(txErrorPoolIsFull)

  let item = TxItemRef.new(ptx, id, sender)
  ?xp.insertToSenderTab(item)
  xp.idTab[item.id] = item
  xp.blobTab.addLookup(item)

  debug "Transaction added to txpool",
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
      xp.blobTab, xp.vmState.ledger, xp.baseFee, xp.nextFork):
    yield item

func getBlobAndProofV1*(xp: TxPoolRef, v: VersionedHash): Opt[BlobAndProofV1] =
  xp.blobTab.withValue(v, val):
    let np = val.item.pooledTx.blobsBundle
    if np.wrapperVersion == WrapperVersionEIP4844:
      return Opt.some(BlobAndProofV1(
        blob: np.blobs[val.blobIndex],
        proof: np.proofs[val.blobIndex]))

  Opt.none(BlobAndProofV1)

func getBlobAndProofV2*(xp: TxPoolRef, v: VersionedHash): Opt[BlobAndProofV2] =
  func getProofs(list: openArray[KzgProof], index: int): array[CELLS_PER_EXT_BLOB, KzgProof] =
    let
      startIndex = index * CELLS_PER_EXT_BLOB
      endIndex   = startIndex + CELLS_PER_EXT_BLOB
    doAssert(list.len >= endIndex)

    for i in 0..<CELLS_PER_EXT_BLOB:
      result[i] = list[startIndex + i]

  xp.blobTab.withValue(v, val):
    let np = val.item.pooledTx.blobsBundle
    if np.wrapperVersion == WrapperVersionEIP7594:
      return Opt.some(BlobAndProofV2(
        blob: np.blobs[val.blobIndex],
        proofs: getProofs(np.proofs, val.blobIndex)))

  Opt.none(BlobAndProofV2)

# ------------------------------------------------------------------------------
# PoS payload attributes getters
# ------------------------------------------------------------------------------

func feeRecipient*(xp: TxPoolRef): Address =
  xp.pos.feeRecipient

func timestamp*(xp: TxPoolRef): EthTime =
  xp.pos.timestamp

func prevRandao*(xp: TxPoolRef): Bytes32 =
  xp.pos.prevRandao

proc withdrawals*(xp: TxPoolRef): seq[Withdrawal] =
  xp.pos.withdrawals

func parentBeaconBlockRoot*(xp: TxPoolRef): Hash32 =
  xp.pos.beaconRoot

# ------------------------------------------------------------------------------
# PoS payload attributes setters
# ------------------------------------------------------------------------------

proc `feeRecipient=`*(xp: TxPoolRef, val: Address) =
  xp.pos.feeRecipient = val

proc `timestamp=`*(xp: TxPoolRef, val: EthTime) =
  xp.pos.timestamp = val

proc `prevRandao=`*(xp: TxPoolRef, val: Bytes32) =
  xp.pos.prevRandao = val

proc `withdrawals=`*(xp: TxPoolRef, val: sink seq[Withdrawal]) =
  xp.pos.withdrawals = system.move(val)

proc `parentBeaconBlockRoot=`*(xp: TxPoolRef, val: Hash32) =
  xp.pos.beaconRoot = val
