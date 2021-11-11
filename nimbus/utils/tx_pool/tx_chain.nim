# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Block Chain Head State
## =======================================
##

import
  std/[math, times],
  ../../chain_config,
  ../../constants,
  ../../db/[db_chain, accounts_cache],
  ../../forks,
  ../../vm_state,
  ../../vm_types,
  ../header,
  ./tx_item,
  eth/[common, keys, p2p]

{.push raises: [Defect].}

type
  TxChainError* = object of CatchableError
    ## Catch and relay exception error

  TxChainNonce* =
    proc(rdb: ReadOnlyStateDB; account: EthAddress): AccountNonce
      {.gcsafe,raises: [Defect,CatchableError].}

  TxChainBalance* =
    proc(rdb: ReadOnlyStateDB; account: EthAddress): UInt256
      {.gcsafe,raises: [Defect,CatchableError].}

  TxChainMiner = object
    ok: bool                   ## Have miner key
    key: PrivateKey            ## Signer key
    address: EthAddress        ## Coinbase

  TxChainRef* = ref object ##\
    ## Cache the state of the block chain which serves as logical insertion
    ## point for a new block. This state is typically the canonical head
    ## when updated.
    db: BaseChainDB            ## Block chain database
    miner: TxChainMiner        ## Optional miner specs

    vmState: BaseVMState       ## Current state relative to `head`
    nextBaseFee: GasPrice      ## Base fee derived from `head`
    nextCoinbase: EthAddress   ## Derived from `head` unless signer available
    nextExtraData: Blob        ## To be used in next block
    nextFork: Fork             ## Fork of next block
    minGasLimit: GasInt        ## Minimum `gasLimit` for the packer
    trgGasLimit: GasInt        ## The `gasLimit` for the packer, soft limit
    maxGasLimit: GasInt        ## May increase the `gasLimit` a bit, hard limit

const
  # The London block is currently implemented in Nimbus only to do some tesing
  londonBlock = 12_965_000.u256

  EIP1559_BASE_FEE_CHANGE_DENOMINATOR = ##\
    ## Bounds the amount the base fee can change between blocks.
    8

  EIP1559_ELASTICITY_MULTIPLIER = ##\
    ## Bounds the maximum gas limit an EIP-1559 block may have.
    2

  EIP1559_INITIAL_BASE_FEE = ##\
    ## Initial base fee for Eip1559 blocks.
    1_000_000_000.u256

  PRE_LONDON_GAS_LIMIT_TRG = ##\
    ## https://ethereum.org/en/developers/docs/blocks/#block-size
    15_000_000.GasInt

  PRE_LONDON_GAS_LIMIT_MAX = ##\
    ## https://ethereum.org/en/developers/docs/blocks/#block-size
    30_000_000.GasInt

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

template safeExecutor*(info: string; code: untyped) =
  try:
    code
  except CatchableError as e:
    raise (ref CatchableError)(msg: e.msg)
  except Defect as e:
    raise (ref Defect)(msg: e.msg)
  except:
    let e = getCurrentException()
    raise newException(TxChainError, info & "(): " & $e.name & " -- " & e.msg)


proc getNextBaseFee*(dh: TxChainRef): UInt256 =
  ## Calculates the `baseFee` of the head assuming this is tha parent of a
  ## new block header to generate. This function is derived from
  ## `p2p/gaslimit.calcEip1599BaseFee()` which in turn has itts origins on
  ## `consensus/misc/eip1559.go` od geth.

  # syntactic sugar, baseFee is for the next header
  let parent = dh.vmState.blockHeader

  if dh.nextFork < FkLondon:
    return 0.u256

  # If the new block is the first EIP-1559 block, return initial base fee.
  if dh.db.config.toFork(parent.blockNumber) < FkLondon:
    return EIP1559_INITIAL_BASE_FEE

  let parGasTrg = parent.gasLimit div EIP1559_ELASTICITY_MULTIPLIER

  # If parent gasUsed is the same as the target, the baseFee remains unchanged.
  if parent.gasUsed == parGasTrg:
    return parent.baseFee

  let
    parGasDenom = (parGasTrg * EIP1559_BASE_FEE_CHANGE_DENOMINATOR).u256
    parBaseFee = parent.baseFee # getter based on fee: Option[UInt256]

  if parGasTrg < parent.gasUsed:
    # If the parent block used more gas than its target, the baseFee should
    # increase.
    let
      gasUsedDelta = (parent.gasUsed - parGasTrg).u256
      baseFeeDelta = (parBaseFee * gasUsedDelta) div parGasDenom

    return parBaseFee + max(1.u256, baseFeeDelta)

  # Otherwise if the parent block used less gas than its target, the
  # baseFee should decrease.
  let
    gasUsedDelta = (parGasTrg - parent.gasUsed).u256
    baseFeeDelta = (parBaseFee * gasUsedDelta) div parGasDenom

  if baseFeeDelta < parBaseFee:
    return parBaseFee - baseFeeDelta

  0.u256


proc setGasLimits(dh: TxChainRef; gasLimit: GasInt) =
  ## Update taget gas limit

  if FkLondon <= dh.nextFork:
    dh.trgGasLimit = max(gasLimit, GAS_LIMIT_MINIMUM)

    # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-1559.md
    # find in box: block.gas_used
    let delta = dh.trgGasLimit.floorDiv(GAS_LIMIT_ADJUSTMENT_FACTOR)
    dh.minGasLimit = dh.trgGasLimit + delta
    dh.maxGasLimit = dh.trgGasLimit - delta

    # Fringe case: use the middle between min/max
    if dh.minGasLimit <= GAS_LIMIT_MINIMUM:
      dh.minGasLimit = GAS_LIMIT_MINIMUM
      dh.trgGasLimit = (dh.minGasLimit + dh.maxGasLimit) div 2

  else:
    dh.maxGasLimit = PRE_LONDON_GAS_LIMIT_MAX

    const delta = (PRE_LONDON_GAS_LIMIT_TRG - GAS_LIMIT_MINIMUM) div 2

    # Just made up to be convenient for the packer
    if gasLimit <= GAS_LIMIT_MINIMUM + delta:
      dh.minGasLimit = max(gasLimit, GAS_LIMIT_MINIMUM)
      dh.trgGasLimit = PRE_LONDON_GAS_LIMIT_TRG
    else:
      # This setting preserves the setting from the parent block
      dh.minGasLimit = gasLimit - delta
      dh.trgGasLimit = gasLimit


proc update(dh: TxChainRef; newHead: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Update by new block header

  safeExecutor("tx_chain.vmState()"):
    let stateRoot = AccountsCache.init(
      dh.db.db, newHead.stateRoot, dh.db.pruneTrie)
    dh.vmState = newBaseVMState(stateRoot, newHead, dh.db)

  dh.nextFork = dh.db.config.toFork(newHead.blockNumber + 1)
  dh.nextExtraData = newHead.extraData
  dh.nextCoinbase = if dh.miner.ok: dh.miner.address else: newHead.coinbase
  dh.nextBaseFee = dh.getNextBaseFee.truncate(uint64).GasPrice

  dh.setGasLimits(newHead.gasLimit)

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxChainRef; db: BaseChainDB; miner: Option[PrivateKey]): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor
  new result

  result.db = db
  result.update(db.getCanonicalHead)

  if miner.isSome:
    result.miner = TxChainMiner(
      ok:      true,
      key:     miner.get,
      address: miner.get.toPublicKey.toCanonicalAddress)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc getBalance*(dh: TxChainRef; account: EthAddress): UInt256
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getBalance()`
  dh.vmState.readOnlyStateDB.getBalance(account)

proc getNonce*(dh: TxChainRef; account: EthAddress): AccountNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getNonce()`
  dh.vmState.readOnlyStateDB.getNonce(account)

proc nextHeader*(dh: TxChainRef; gasLimit: GasInt): BlockHeader
    {.gcsafe,raises: [Defect,ValueError].} =
  ## Generate a new header, child of the cached `head`

  # may need increase the gas limit
  var effGasLimit = dh.trgGasLimit
  if effGasLimit < gasLimit:
    effGasLimit = dh.maxGasLimit

  generateHeaderFromParentHeader(
    config = dh.db.config,
    parent = dh.vmState.blockHeader,
    coinbase = dh.nextCoinbase,
    timestamp = some(getTime().utc.toTime),
    gasLimit = effGasLimit,
    extraData = dh.nextExtraData,
    baseFee = some(dh.nextBaseFee.uint64.u256))

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc db*(dh: TxChainRef): BaseChainDB =
  ## Getter
  dh.db

proc head*(dh: TxChainRef): BlockHeader =
  ## Getter, current
  dh.vmState.blockHeader

proc nextBaseFee*(dh: TxChainRef): GasPrice =
  ## Getter, baseFee of next bock
  dh.nextBaseFee

proc nextCoinbase*(dh: TxChainRef): EthAddress =
  ## Getter
  dh.nextCoinbase

proc nextExtraData*(dh: TxChainRef): Blob =
  ## Getter
  dh.nextExtraData

proc nextFork*(dh: TxChainRef): Fork =
  ## Getter, fork of next block
  dh.nextFork

proc maxGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.maxGasLimit

proc minGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.minGasLimit

proc trgGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.trgGasLimit

proc vmState*(dh: TxChainRef): BaseVMState =
  ## Getter, current block chain state
  dh.vmState

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `head=`*(dh: TxChainRef; header: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, updates descriptor. This setter re-positions the `vmState` and
  ## account cachs to a new insertion point on the block chain database.
  dh.update(header)

proc `nextCoinbase=`*(dh: TxChainRef; val: EthAddress) =
  ## Setter
  dh.nextCoinbase = val

proc `nextExtraData=`*(dh: TxChainRef; val: Blob) =
  ## Setter
  dh.nextExtraData = val

# ------------------------------------------------------------------------------
# Public functions, debugging & testing
# ------------------------------------------------------------------------------

proc setNextGasLimit*(dh: TxChainRef; val: GasInt) =
  ## Temorarily overwrite (until next header update). The argument might be
  ## adjusted so that it is in the proper range. This function
  ## is intended to support debugging and testing.
  dh.setGasLimits(val)

proc setNextBaseFee*(dh: TxChainRef; val: GasPrice) =
  ## Temorarily overwrite (until next header update). This function
  ## is intended to support debugging and testing.
  dh.nextBaseFee = val

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
