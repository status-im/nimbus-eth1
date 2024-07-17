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
  ../eip4844,
  ../pow/difficulty,
  ../executor,
  ../casper,
  ./tx_chain/[tx_basefee, tx_gaslimits],
  ./tx_item

type
  TxChainPackerEnv = tuple
    vmState: BaseVMState     ## current tx/packer environment
    receipts: seq[Receipt]   ## `vmState.receipts` after packing
    reward: UInt256          ## Miner balance difference after packing
    profit: UInt256          ## Net reward (w/o PoW specific block rewards)
    txRoot: Hash256          ## `rootHash` after packing
    stateRoot: Hash256       ## `stateRoot` after packing
    blobGasUsed:
      Opt[uint64]         ## EIP-4844 block blobGasUsed
    excessBlobGas:
      Opt[uint64]         ## EIP-4844 block excessBlobGas

  TxChainRef* = ref object ##\
    ## State cache of the transaction environment for creating a new\
    ## block. This state is typically synchrionised with the canonical\
    ## block chain head when updated.
    com: CommonRef           ## Block chain config
    roAcc: ReadOnlyStateDB   ## Accounts cache fixed on current sync header
    gasLimit*: GasInt
    txEnv: TxChainPackerEnv  ## Assorted parameters, tx packer environment
    prepHeader: BlockHeader  ## Prepared Header from Consensus Engine

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------
func prepareHeader(dh: TxChainRef; parent: BlockHeader, timestamp: EthTime)
     {.raises: [].} =
  dh.com.pos.prepare(dh.prepHeader)

func prepareForSeal(dh: TxChainRef; header: var BlockHeader) {.raises: [].} =
  dh.com.pos.prepareForSeal(header)

func getTimestamp(dh: TxChainRef, parent: BlockHeader): EthTime =
  dh.com.pos.timestamp

func feeRecipient*(dh: TxChainRef): EthAddress

proc resetTxEnv(dh: TxChainRef; parent: BlockHeader; baseFeePerGas: Opt[UInt256])
  {.gcsafe,raises: [].} =
  dh.txEnv.reset

  # do hardfork transition before
  # BaseVMState querying any hardfork/consensus from CommonRef

  let timestamp = dh.getTimestamp(parent)
  dh.com.hardForkTransition(
    parent.blockHash, parent.number+1, Opt.some(timestamp))
  dh.prepareHeader(parent, timestamp)

  # we don't consider PoS difficulty here
  # because that is handled in vmState
  let blockCtx = BlockContext(
    timestamp    : dh.prepHeader.timestamp,
    gasLimit     : dh.gasLimit,
    baseFeePerGas: baseFeePerGas,
    prevRandao   : dh.prepHeader.prevRandao,
    difficulty   : dh.prepHeader.difficulty,
    coinbase     : dh.feeRecipient,
    excessBlobGas: calcExcessBlobGas(parent),
  )

  dh.txEnv.vmState = BaseVMState.new(
    parent   = parent,
    blockCtx = blockCtx,
    com      = dh.com)

  dh.txEnv.txRoot = EMPTY_ROOT_HASH
  dh.txEnv.stateRoot = dh.txEnv.vmState.parent.stateRoot
  dh.txEnv.blobGasUsed = Opt.none(uint64)
  dh.txEnv.excessBlobGas = Opt.none(uint64)

proc update(dh: TxChainRef; parent: BlockHeader)
    {.gcsafe,raises: [].} =

  let
    db  = dh.com.db
    acc = LedgerRef.init(db, parent.stateRoot)
    fee = baseFeeGet(dh.com, parent)

  # Keep a separate accounts descriptor positioned at the sync point
  dh.roAcc = ReadOnlyStateDB(acc)

  dh.gasLimit = dh.com.gasLimitsGet(parent)
  dh.resetTxEnv(parent, fee)

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

proc getHeader*(dh: TxChainRef): BlockHeader
    {.gcsafe,raises: [].} =
  ## Generate a new header, a child of the cached `head`
  let gasUsed = if dh.txEnv.receipts.len == 0: 0.GasInt
                else: dh.txEnv.receipts[^1].cumulativeGasUsed

  result = BlockHeader(
    parentHash:    dh.txEnv.vmState.parent.blockHash,
    ommersHash:    EMPTY_UNCLE_HASH,
    coinbase:      dh.prepHeader.coinbase,
    stateRoot:     dh.txEnv.stateRoot,
    txRoot:        dh.txEnv.txRoot,
    receiptsRoot:  dh.txEnv.receipts.calcReceiptsRoot,
    logsBloom:     dh.txEnv.receipts.createBloom,
    difficulty:    dh.prepHeader.difficulty,
    number:        dh.txEnv.vmState.blockNumber,
    gasLimit:      dh.txEnv.vmState.blockCtx.gasLimit,
    gasUsed:       gasUsed,
    timestamp:     dh.prepHeader.timestamp,
    # extraData:   Blob       # signing data
    # mixHash:     Hash256    # mining hash for given difficulty
    # nonce:       BlockNonce # mining free vaiable
    baseFeePerGas: dh.txEnv.vmState.blockCtx.baseFeePerGas,
    blobGasUsed:   dh.txEnv.blobGasUsed,
    excessBlobGas: dh.txEnv.excessBlobGas)

  if dh.com.isShanghaiOrLater(result.timestamp):
    result.withdrawalsRoot = Opt.some(calcWithdrawalsRoot(dh.com.pos.withdrawals))

  if dh.com.isCancunOrLater(result.timestamp):
    result.parentBeaconBlockRoot = Opt.some(dh.com.pos.parentBeaconBlockRoot)

  dh.prepareForSeal(result)

proc clearAccounts*(dh: TxChainRef)
    {.gcsafe,raises: [].} =
  ## Reset transaction environment, e.g. before packing a new block
  dh.resetTxEnv(dh.txEnv.vmState.parent, dh.txEnv.vmState.blockCtx.baseFeePerGas)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func com*(dh: TxChainRef): CommonRef =
  ## Getter
  dh.com

func head*(dh: TxChainRef): BlockHeader =
  ## Getter
  dh.txEnv.vmState.parent

func feeRecipient*(dh: TxChainRef): EthAddress =
  ## Getter
  dh.com.pos.feeRecipient

func baseFee*(dh: TxChainRef): GasPrice =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  if dh.txEnv.vmState.blockCtx.baseFeePerGas.isSome:
    dh.txEnv.vmState.blockCtx.baseFeePerGas.get.truncate(uint64).GasPrice
  else:
    0.GasPrice

func excessBlobGas*(dh: TxChainRef): uint64 =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  dh.txEnv.excessBlobGas.get(0'u64)

func nextFork*(dh: TxChainRef): EVMFork =
  ## Getter, fork of next block
  dh.txEnv.vmState.fork

func gasUsed*(dh: TxChainRef): GasInt =
  ## Getter, accumulated gas burned for collected blocks
  if 0 < dh.txEnv.receipts.len:
    return dh.txEnv.receipts[^1].cumulativeGasUsed

func profit*(dh: TxChainRef): UInt256 =
  ## Getter
  dh.txEnv.profit

func receipts*(dh: TxChainRef): seq[Receipt] =
  ## Getter, receipts for collected blocks
  dh.txEnv.receipts

func reward*(dh: TxChainRef): UInt256 =
  ## Getter, reward for collected blocks
  dh.txEnv.reward

func stateRoot*(dh: TxChainRef): Hash256 =
  ## Getter, accounting DB state root hash for the next block header
  dh.txEnv.stateRoot

func txRoot*(dh: TxChainRef): Hash256 =
  ## Getter, transaction state root hash for the next block header
  dh.txEnv.txRoot

func vmState*(dh: TxChainRef): BaseVMState =
  ## Getter, `BaseVmState` descriptor based on the current insertion point.
  dh.txEnv.vmState

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

func `baseFee=`*(dh: TxChainRef; val: GasPrice) =
  ## Setter, temorarily overwrites parameter until next `head=` update. This
  ## function would be called in exceptional cases only as this parameter is
  ## determined by the `head=` update.
  if 0 < val or dh.com.isLondonOrLater(dh.txEnv.vmState.blockNumber):
    dh.txEnv.vmState.blockCtx.baseFeePerGas = Opt.some(val.uint64.u256)
  else:
    dh.txEnv.vmState.blockCtx.baseFeePerGas = Opt.none UInt256

proc `head=`*(dh: TxChainRef; val: BlockHeader)
    {.gcsafe,raises: [].} =
  ## Setter, updates descriptor. This setter re-positions the `vmState` and
  ## account caches to a new insertion point on the block chain database.
  dh.update(val)

func `profit=`*(dh: TxChainRef; val: UInt256) =
  ## Setter
  dh.txEnv.profit = val

func `receipts=`*(dh: TxChainRef; val: seq[Receipt]) =
  ## Setter, implies `gasUsed`
  dh.txEnv.receipts = val

func `reward=`*(dh: TxChainRef; val: UInt256) =
  ## Getter
  dh.txEnv.reward = val

func `stateRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter
  dh.txEnv.stateRoot = val

func `txRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter
  dh.txEnv.txRoot = val

func `excessBlobGas=`*(dh: TxChainRef; val: Opt[uint64]) =
  ## Setter
  dh.txEnv.excessBlobGas = val

func `blobGasUsed=`*(dh: TxChainRef; val: Opt[uint64]) =
  ## Setter
  dh.txEnv.blobGasUsed = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
