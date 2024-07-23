# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

## Transaction Pool Block Chain Packer Environment
## ===============================================
##

import
  results,
  ../../common/common,
  ../../constants,
  ../../db/ledger,
  ../../utils/utils,
  ../../evm/state,
  ../../evm/types,
  ../pow/header,
  ../eip4844,
  ../casper,
  eth/eip1559

type
  TxChainRef* = ref object ##\
    ## State cache of the transaction environment for creating a new\
    ## block. This state is typically synchrionised with the canonical\
    ## block chain head when updated.
    com: CommonRef           ## Block chain config
    roAcc: ReadOnlyStateDB   ## Accounts cache fixed on current sync header
    prepHeader: BlockHeader  ## Prepared Header from Consensus Engine

    vmState: BaseVMState     ## current tx/packer environment
    receiptsRoot: Hash256
    logsBloom: BloomFilter
    txRoot: Hash256          ## `rootHash` after packing
    stateRoot: Hash256       ## `stateRoot` after packing

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------
proc baseFeeGet(com: CommonRef; parent: BlockHeader): Opt[UInt256] =
  ## Calculates the `baseFee` of the head assuming this is the parent of a
  ## new block header to generate.

  # Note that the baseFee is calculated for the next header
  if not com.isLondonOrLater(parent.number+1):
    return Opt.none(UInt256)

  # If the new block is the first EIP-1559 block, return initial base fee.
  if not com.isLondonOrLater(parent.number):
    return Opt.some(EIP1559_INITIAL_BASE_FEE)

  Opt.some calcEip1599BaseFee(
    parent.gasLimit,
    parent.gasUsed,
    parent.baseFeePerGas.get(0.u256))

proc gasLimitsGet(com: CommonRef; parent: BlockHeader): GasInt =
  if com.isLondonOrLater(parent.number+1):
    var parentGasLimit = parent.gasLimit
    if not com.isLondonOrLater(parent.number):
      # Bump by 2x
      parentGasLimit = parent.gasLimit * EIP1559_ELASTICITY_MULTIPLIER
    calcGasLimit1559(parentGasLimit, desiredLimit = DEFAULT_GAS_LIMIT)
  else:
    computeGasLimit(
      parent.gasUsed,
      parent.gasLimit,
      gasFloor = DEFAULT_GAS_LIMIT,
      gasCeil = DEFAULT_GAS_LIMIT)
      
func prepareHeader(dh: TxChainRef) =
  dh.com.pos.prepare(dh.prepHeader)

func prepareForSeal(dh: TxChainRef; header: var BlockHeader) =
  dh.com.pos.prepareForSeal(header)

func getTimestamp(dh: TxChainRef): EthTime =
  dh.com.pos.timestamp

func feeRecipient*(dh: TxChainRef): EthAddress =
  ## Getter
  dh.com.pos.feeRecipient

proc resetTxEnv(dh: TxChainRef; parent: BlockHeader) =
  # do hardfork transition before
  # BaseVMState querying any hardfork/consensus from CommonRef

  let timestamp = dh.getTimestamp()
  dh.com.hardForkTransition(
    parent.blockHash, parent.number+1, Opt.some(timestamp))
  dh.prepareHeader()

  # we don't consider PoS difficulty here
  # because that is handled in vmState
  let blockCtx = BlockContext(
    timestamp    : dh.prepHeader.timestamp,
    gasLimit     : gasLimitsGet(dh.com, parent),
    baseFeePerGas: baseFeeGet(dh.com, parent),
    prevRandao   : dh.prepHeader.prevRandao,
    difficulty   : dh.prepHeader.difficulty,
    coinbase     : dh.feeRecipient,
    excessBlobGas: calcExcessBlobGas(parent),
  )

  dh.vmState = BaseVMState.new(
    parent   = parent,
    blockCtx = blockCtx,
    com      = dh.com)

  dh.txRoot = EMPTY_ROOT_HASH
  dh.stateRoot = dh.vmState.parent.stateRoot

proc update(dh: TxChainRef; parent: BlockHeader)
    {.gcsafe,raises: [].} =

  let
    db  = dh.com.db
    acc = LedgerRef.init(db, parent.stateRoot)

  # Keep a separate accounts descriptor positioned at the sync point
  dh.roAcc = ReadOnlyStateDB(acc)
  dh.resetTxEnv(parent)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc new*(T: type TxChainRef; com: CommonRef): T
    {.gcsafe, raises: [EVMError].} =
  ## Constructor
  new result

  result.com = com
  result.update(com.db.getCanonicalHead)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getBalance*(dh: TxChainRef; account: EthAddress): UInt256 =
  ## Wrapper around `vmState.readOnlyStateDB.getBalance()` for a `vmState`
  ## descriptor positioned at the `dh.head`. This might differ from the
  ## `dh.vmState.readOnlyStateDB.getBalance()` which returnes the current
  ## balance relative to what has been accumulated by the current packing
  ## procedure.
  dh.roAcc.getBalance(account)

proc getNonce*(dh: TxChainRef; account: EthAddress): AccountNonce =
  ## Wrapper around `vmState.readOnlyStateDB.getNonce()` for a `vmState`
  ## descriptor positioned at the `dh.head`. This might differ from the
  ## `dh.vmState.readOnlyStateDB.getNonce()` which returnes the current balance
  ## relative to what has been accumulated by the current packing procedure.
  dh.roAcc.getNonce(account)

func baseFee*(dh: TxChainRef): GasInt =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  if dh.vmState.blockCtx.baseFeePerGas.isSome:
    dh.vmState.blockCtx.baseFeePerGas.get.truncate(GasInt)
  else:
    0.GasInt

func excessBlobGas*(dh: TxChainRef): uint64 =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  dh.vmState.blockCtx.excessBlobGas

func blobGasUsed*(dh: TxChainRef): uint64 =
  dh.vmState.blobGasUsed

func gasLimit*(dh: TxChainRef): GasInt =
  dh.vmState.blockCtx.gasLimit

proc getHeader*(dh: TxChainRef): BlockHeader
    {.gcsafe,raises: [].} =
  ## Generate a new header, a child of the cached `head`
  result = BlockHeader(
    parentHash:    dh.vmState.parent.blockHash,
    ommersHash:    EMPTY_UNCLE_HASH,
    coinbase:      dh.prepHeader.coinbase,
    stateRoot:     dh.stateRoot,
    txRoot:        dh.txRoot,
    receiptsRoot:  dh.receiptsRoot,
    logsBloom:     dh.logsBloom,
    difficulty:    dh.prepHeader.difficulty,
    number:        dh.vmState.blockNumber,
    gasLimit:      dh.gasLimit,
    gasUsed:       dh.vmState.cumulativeGasUsed,
    timestamp:     dh.prepHeader.timestamp,
    # extraData:   Blob       # signing data
    # mixHash:     Hash256    # mining hash for given difficulty
    # nonce:       BlockNonce # mining free vaiable
    baseFeePerGas: dh.vmState.blockCtx.baseFeePerGas,
    )

  if dh.com.isShanghaiOrLater(result.timestamp):
    result.withdrawalsRoot = Opt.some(calcWithdrawalsRoot(dh.com.pos.withdrawals))

  if dh.com.isCancunOrLater(result.timestamp):
    result.parentBeaconBlockRoot = Opt.some(dh.com.pos.parentBeaconBlockRoot)
    result.blobGasUsed = Opt.some dh.blobGasUsed
    result.excessBlobGas = Opt.some dh.excessBlobGas

  dh.prepareForSeal(result)

proc clearAccounts*(dh: TxChainRef)
    {.gcsafe,raises: [].} =
  ## Reset transaction environment, e.g. before packing a new block
  dh.resetTxEnv(dh.vmState.parent)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func com*(dh: TxChainRef): CommonRef =
  ## Getter
  dh.com

func head*(dh: TxChainRef): BlockHeader =
  ## Getter
  dh.vmState.parent

func nextFork*(dh: TxChainRef): EVMFork =
  ## Getter, fork of next block
  dh.vmState.fork

func vmState*(dh: TxChainRef): BaseVMState =
  ## Getter, `BaseVmState` descriptor based on the current insertion point.
  dh.vmState

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `head=`*(dh: TxChainRef; val: BlockHeader)
    {.gcsafe,raises: [].} =
  ## Setter, updates descriptor. This setter re-positions the `vmState` and
  ## account caches to a new insertion point on the block chain database.
  dh.update(val)

func `receiptsRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter, implies `gasUsed`
  dh.receiptsRoot = val

func `logsBloom=`*(dh: TxChainRef; val: BloomFilter) =
  ## Setter, implies `gasUsed`
  dh.logsBloom = val

func `stateRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter
  dh.stateRoot = val

func `txRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter
  dh.txRoot = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
