# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Block Chain Packer Environment
## ===============================================
##

import
  std/[sets, times],
  ../../common/common,
  ../../constants,
  ../../db/accounts_cache,
  ../../utils/utils,
  ../../vm_state,
  ../../vm_types,
  ../clique/clique_sealer,
  ../pow/difficulty,
  ../executor,
  ../casper,
  ./tx_chain/[tx_basefee, tx_gaslimits],
  ./tx_item

export
  TxChainGasLimits,
  TxChainGasLimitsPc

{.push raises: [Defect].}

const
  TRG_THRESHOLD_PER_CENT = ##\
    ## VM executor may stop if this per centage of `trgLimit` has
    ## been reached.
    90

  MAX_THRESHOLD_PER_CENT = ##\
    ## VM executor may stop if this per centage of `maxLimit` has
    ## been reached.
    90

type
  TxChainPackerEnv = tuple
    vmState: BaseVMState     ## current tx/packer environment
    receipts: seq[Receipt]   ## `vmState.receipts` after packing
    reward: UInt256          ## Miner balance difference after packing
    profit: UInt256          ## Net reward (w/o PoW specific block rewards)
    txRoot: Hash256          ## `rootHash` after packing
    stateRoot: Hash256       ## `stateRoot` after packing

  TxChainRef* = ref object ##\
    ## State cache of the transaction environment for creating a new\
    ## block. This state is typically synchrionised with the canonical\
    ## block chain head when updated.
    com: CommonRef           ## Block chain config
    miner: EthAddress        ## Address of fee beneficiary
    lhwm: TxChainGasLimitsPc ## Hwm/lwm gas limit percentage

    maxMode: bool            ## target or maximal limit for next block header
    roAcc: ReadOnlyStateDB   ## Accounts cache fixed on current sync header
    limits: TxChainGasLimits ## Gas limits for packer and next header
    txEnv: TxChainPackerEnv  ## Assorted parameters, tx packer environment
    prepHeader: BlockHeader  ## Prepared Header from Consensus Engine

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------
proc prepareHeader(dh: TxChainRef; parent: BlockHeader)
     {.gcsafe, raises: [Defect, CatchableError].} =

  case dh.com.consensus
  of ConsensusType.POW:
    dh.prepHeader.timestamp  = getTime().utc.toTime
    dh.prepHeader.difficulty = dh.com.calcDifficulty(
      dh.prepHeader.timestamp, parent)
    dh.prepHeader.coinbase   = dh.miner
    dh.prepHeader.mixDigest.reset
  of ConsensusType.POA:
    discard dh.com.poa.prepare(parent, dh.prepHeader)
    # beware POA header.coinbase != signerAddress
    # but BaseVMState.minerAddress == signerAddress
    # - minerAddress is extracted from header.extraData
    # - header.coinbase is from clique engine
    dh.prepHeader.coinbase = dh.miner
  of ConsensusType.POS:
    dh.com.pos.prepare(dh.prepHeader)

proc prepareForSeal(dh: TxChainRef; header: var BlockHeader) =
  case dh.com.consensus
  of ConsensusType.POW:
    # do nothing, tx pool was designed with POW in mind
    discard
  of ConsensusType.POA:
    dh.com.poa.prepareForSeal(dh.prepHeader, header)
  of ConsensusType.POS:
    dh.com.pos.prepareForSeal(header)

proc resetTxEnv(dh: TxChainRef; parent: BlockHeader; fee: Option[UInt256])
  {.gcsafe,raises: [Defect,CatchableError].} =
  dh.txEnv.reset

  # do hardfork transition before
  # BaseVMState querying any hardfork/consensus from CommonRef
  dh.com.hardForkTransition(parent.blockHash, parent.blockNumber+1, some(parent.timestamp.adjustForNextBlock))
  dh.prepareHeader(parent)

  # we don't consider PoS difficulty here
  # because that is handled in vmState
  dh.txEnv.vmState = BaseVMState.new(
    parent    = parent,
    timestamp = dh.prepHeader.timestamp,
    gasLimit  = (if dh.maxMode: dh.limits.maxLimit else: dh.limits.trgLimit),
    fee       = fee,
    prevRandao= dh.prepHeader.prevRandao,
    difficulty= dh.prepHeader.difficulty,
    miner     = dh.prepHeader.coinbase,
    com       = dh.com)

  dh.txEnv.txRoot = EMPTY_ROOT_HASH
  dh.txEnv.stateRoot = dh.txEnv.vmState.parent.stateRoot

proc update(dh: TxChainRef; parent: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =

  let
    db  = dh.com.db
    acc = AccountsCache.init(db.db, parent.stateRoot, dh.com.pruneTrie)
    fee = if dh.com.isLondon(parent.blockNumber + 1):
            some(dh.com.baseFeeGet(parent).uint64.u256)
          else:
            UInt256.none()

  # Keep a separate accounts descriptor positioned at the sync point
  dh.roAcc = ReadOnlyStateDB(acc)

  dh.limits = dh.com.gasLimitsGet(parent, dh.lhwm)
  dh.resetTxEnv(parent, fee)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc new*(T: type TxChainRef; com: CommonRef; miner: EthAddress): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor
  new result

  result.com = com
  result.miner = miner
  result.lhwm.lwmTrg = TRG_THRESHOLD_PER_CENT
  result.lhwm.hwmMax = MAX_THRESHOLD_PER_CENT
  result.lhwm.gasFloor = DEFAULT_GAS_LIMIT
  result.lhwm.gasCeil  = DEFAULT_GAS_LIMIT
  result.update(com.db.getCanonicalHead)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getBalance*(dh: TxChainRef; account: EthAddress): UInt256
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `vmState.readOnlyStateDB.getBalance()` for a `vmState`
  ## descriptor positioned at the `dh.head`. This might differ from the
  ## `dh.vmState.readOnlyStateDB.getBalance()` which returnes the current
  ## balance relative to what has been accumulated by the current packing
  ## procedure.
  dh.roAcc.getBalance(account)

proc getNonce*(dh: TxChainRef; account: EthAddress): AccountNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `vmState.readOnlyStateDB.getNonce()` for a `vmState`
  ## descriptor positioned at the `dh.head`. This might differ from the
  ## `dh.vmState.readOnlyStateDB.getNonce()` which returnes the current balance
  ## relative to what has been accumulated by the current packing procedure.
  dh.roAcc.getNonce(account)

proc getHeader*(dh: TxChainRef): BlockHeader
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Generate a new header, a child of the cached `head`
  let gasUsed = if dh.txEnv.receipts.len == 0: 0.GasInt
                else: dh.txEnv.receipts[^1].cumulativeGasUsed

  result = BlockHeader(
    parentHash:  dh.txEnv.vmState.parent.blockHash,
    ommersHash:  EMPTY_UNCLE_HASH,
    coinbase:    dh.prepHeader.coinbase,
    stateRoot:   dh.txEnv.stateRoot,
    txRoot:      dh.txEnv.txRoot,
    receiptRoot: dh.txEnv.receipts.calcReceiptRoot,
    bloom:       dh.txEnv.receipts.createBloom,
    difficulty:  dh.prepHeader.difficulty,
    blockNumber: dh.txEnv.vmState.blockNumber,
    gasLimit:    dh.txEnv.vmState.gasLimit,
    gasUsed:     gasUsed,
    timestamp:   dh.prepHeader.timestamp,
    # extraData: Blob       # signing data
    # mixDigest: Hash256    # mining hash for given difficulty
    # nonce:     BlockNonce # mining free vaiable
    fee:         dh.txEnv.vmState.fee)

  dh.prepareForSeal(result)

proc clearAccounts*(dh: TxChainRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Reset transaction environment, e.g. before packing a new block
  dh.resetTxEnv(dh.txEnv.vmState.parent, dh.txEnv.vmState.fee)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc com*(dh: TxChainRef): CommonRef =
  ## Getter
  dh.com

proc head*(dh: TxChainRef): BlockHeader =
  ## Getter
  dh.txEnv.vmState.parent

proc limits*(dh: TxChainRef): TxChainGasLimits =
  ## Getter
  dh.limits

proc lhwm*(dh: TxChainRef): TxChainGasLimitsPc =
  ## Getter
  dh.lhwm

proc maxMode*(dh: TxChainRef): bool =
  ## Getter
  dh.maxMode

proc feeRecipient*(dh: TxChainRef): EthAddress =
  ## Getter
  if dh.com.consensus == ConsensusType.POS:
    dh.com.pos.feeRecipient
  else:
    dh.miner

proc baseFee*(dh: TxChainRef): GasPrice =
  ## Getter, baseFee for the next bock header. This value is auto-generated
  ## when a new insertion point is set via `head=`.
  if dh.txEnv.vmState.fee.isSome:
    dh.txEnv.vmState.fee.get.truncate(uint64).GasPrice
  else:
    0.GasPrice

proc nextFork*(dh: TxChainRef): EVMFork =
  ## Getter, fork of next block
  dh.com.toEVMFork(dh.txEnv.vmState.forkDeterminationInfoForVMState)

proc gasUsed*(dh: TxChainRef): GasInt =
  ## Getter, accumulated gas burned for collected blocks
  if 0 < dh.txEnv.receipts.len:
    return dh.txEnv.receipts[^1].cumulativeGasUsed

proc profit*(dh: TxChainRef): UInt256 =
  ## Getter
  dh.txEnv.profit

proc receipts*(dh: TxChainRef): seq[Receipt] =
  ## Getter, receipts for collected blocks
  dh.txEnv.receipts

proc reward*(dh: TxChainRef): UInt256 =
  ## Getter, reward for collected blocks
  dh.txEnv.reward

proc stateRoot*(dh: TxChainRef): Hash256 =
  ## Getter, accounting DB state root hash for the next block header
  dh.txEnv.stateRoot

proc txRoot*(dh: TxChainRef): Hash256 =
  ## Getter, transaction state root hash for the next block header
  dh.txEnv.txRoot

proc vmState*(dh: TxChainRef): BaseVMState =
  ## Getter, `BaseVmState` descriptor based on the current insertion point.
  dh.txEnv.vmState

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `baseFee=`*(dh: TxChainRef; val: GasPrice) =
  ## Setter, temorarily overwrites parameter until next `head=` update. This
  ## function would be called in exceptional cases only as this parameter is
  ## determined by the `head=` update.
  if 0 < val or dh.com.isLondon(dh.txEnv.vmState.blockNumber):
    dh.txEnv.vmState.fee = some(val.uint64.u256)
  else:
    dh.txEnv.vmState.fee = UInt256.none()

proc `head=`*(dh: TxChainRef; val: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, updates descriptor. This setter re-positions the `vmState` and
  ## account caches to a new insertion point on the block chain database.
  dh.update(val)

proc `lhwm=`*(dh: TxChainRef; val: TxChainGasLimitsPc) =
  ## Setter, tuple `(lwmTrg,hwmMax)` will allow the packer to continue
  ## up until the percentage level has been reached of the `trgLimit`, or
  ## `maxLimit` depending on what has been activated.
  if dh.lhwm != val:
    dh.lhwm = val
    let parent = dh.txEnv.vmState.parent
    dh.limits = dh.com.gasLimitsGet(parent, dh.limits.gasLimit, dh.lhwm)
    dh.txEnv.vmState.gasLimit = if dh.maxMode: dh.limits.maxLimit
                                else:          dh.limits.trgLimit

proc `maxMode=`*(dh: TxChainRef; val: bool) =
  ## Setter, the packing mode (maximal or target limit) for the next block
  ## header
  dh.maxMode = val
  dh.txEnv.vmState.gasLimit = if dh.maxMode: dh.limits.maxLimit
                              else:          dh.limits.trgLimit

proc `miner=`*(dh: TxChainRef; val: EthAddress) =
  ## Setter
  dh.miner = val
  dh.txEnv.vmState.minerAddress = val

proc `profit=`*(dh: TxChainRef; val: UInt256) =
  ## Setter
  dh.txEnv.profit = val

proc `receipts=`*(dh: TxChainRef; val: seq[Receipt]) =
  ## Setter, implies `gasUsed`
  dh.txEnv.receipts = val

proc `reward=`*(dh: TxChainRef; val: UInt256) =
  ## Getter
  dh.txEnv.reward = val

proc `stateRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter
  dh.txEnv.stateRoot = val

proc `txRoot=`*(dh: TxChainRef; val: Hash256) =
  ## Setter
  dh.txEnv.txRoot = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
