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
  ../header,
  ./tx_item,
  eth/[common, keys, p2p]

{.push raises: [Defect].}

type
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
    nonceFn: TxChainNonce      ## Sender account `getNonce()` function
    balanceFn: TxChainBalance  ## Sender account `getBalance()` function

    head: BlockHeader          ## New block insertion point
    thisFork: Fork             ## Fork of current `head`
    accDB: AccountsCache       ## Sender accounts, relative to `head`
    baseFee: GasPrice          ## Current base fee derived from `head`
    coinbase: EthAddress       ## Derived from `head` unless signer available
    minGasLimit: GasInt        ## Minimum `gasLimit` for the packer
    trgGasLimit: GasInt        ## The `gasLimit` for the packer, soft limit
    maxGasLimit: GasInt        ## May increase the `gasLimit` a bit, hard limit
    extraData: Blob            ## To be used in next head
    fork: Fork                 ## Fork relative to next head

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
# Private functions, account helpers
# ------------------------------------------------------------------------------

proc getBalance(rdb: ReadOnlyStateDB; account: EthAddress): UInt256 =
  ## Wrapper around `getBalance()`
  accounts_cache.getBalance(rdb,account)

proc getNonce(rdb: ReadOnlyStateDB; account: EthAddress): AccountNonce =
  ## Wrapper around `getNonce()`
  accounts_cache.getNonce(rdb,account)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc toForkOrLondon(db: BaseChainDB; number: BlockNumber): Fork =
  ## returns the real fork, including *London* which is unsupported by the
  ## current implementation of configutation tools (does not provide for
  ## detecting a *London* fork unless set manually for debugging.)
  ##
  ## This function also returns *London* on a block earlier than `londonBlock`
  ## if configured smaller than that (as mentioned above, when set manually
  ## for testing.)
  if db.networkId == MainNet and londonBlock <= number:
    return FkLondon
  db.config.toFork(number)


proc getBaseFee*(dh: TxChainRef): UInt256 =
  ## Calculates the `baseFee` of the head assuming this is tha parent of a
  ## new block header to generate. This function is derived from
  ## `p2p/gaslimit.calcEip1599BaseFee()` which in turn has itts origins on
  ## `consensus/misc/eip1559.go` od geth.

  if dh.fork < FkLondon:
    return 0.u256

  let parent = dh.head # syntactic sugar, baseFee is for the next header

  # If the new block is the first EIP-1559 block, return initial base fee
  if dh.db.toForkOrLondon(parent.blockNumber) < FkLondon:
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
  if FkLondon <= dh.fork:
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
  dh.head = newHead
  dh.fork = dh.db.toForkOrLondon(dh.head.blockNumber + 1)
  dh.accDB = AccountsCache.init(dh.db.db, dh.head.stateRoot, dh.db.pruneTrie)
  dh.extraData = newHead.extraData
  dh.coinbase = if dh.miner.ok: dh.miner.address else: newHead.coinbase
  dh.baseFee = dh.getBaseFee.truncate(uint64).GasPrice

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
  result.nonceFn = getNonce
  result.balanceFn = getBalance

  if miner.isSome:
    result.miner = TxChainMiner(
      ok:      true,
      key:     miner.get,
      address: miner.get.toPublicKey.toCanonicalAddress)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc accountBalance*(dh: TxChainRef; account: EthAddress): UInt256
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getBalance()`
  dh.balanceFn(ReadOnlyStateDB(dh.accDb),account)

proc accountNonce*(dh: TxChainRef; account: EthAddress): AccountNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getNonce()`
  dh.nonceFn(ReadOnlyStateDB(dh.accDb),account)

proc nextHeader*(dh: TxChainRef; gasLimit: GasInt): BlockHeader
    {.gcsafe,raises: [Defect,ValueError].} =
  ## Generate a new header, child of the cached `head`
  var
    effBaseFee = dh.baseFee.uint64.u256
    effGasLimit = dh.trgGasLimit

  # may need increase the gas limit
  if effGasLimit < gasLimit:
    effGasLimit = dh.maxGasLimit

  generateHeaderFromParentHeader(
    config = dh.db.config,
    parent = dh.head,
    coinbase = dh.coinbase,
    timestamp = some(getTime().utc.toTime),
    gasLimit = effGasLimit,
    extraData = dh.extraData,
    baseFee = some(effBaseFee))

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc db*(dh: TxChainRef): BaseChainDB =
  ## Getter
  dh.db

proc head*(dh: TxChainRef): BlockHeader =
  ## Getter
  dh.head

proc fork*(dh: TxChainRef): Fork =
  ## Getter
  dh.fork

proc baseFee*(dh: TxChainRef): GasPrice =
  ## Getter
  dh.baseFee

proc trgGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.trgGasLimit

proc maxGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.maxGasLimit

proc minGasLimit*(dh: TxChainRef): GasInt =
  ## Getter
  dh.minGasLimit

proc coinbase*(dh: TxChainRef): EthAddress =
  ## Getter
  dh.coinbase

proc extraData*(dh: TxChainRef): Blob =
  ## Getter
  dh.extraData

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `head=`*(dh: TxChainRef; header: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, updates descriptor
  dh.update(header)

proc `coinbase=`*(dh: TxChainRef; val: EthAddress) =
  ## Setter
  dh.coinbase = val

proc `extraData=`*(dh: TxChainRef; val: Blob) =
  ## Setter
  dh.extraData = val

# ------------------------------------------------------------------------------
# Public functions, debugging & testing
# ------------------------------------------------------------------------------

proc setGasLimit*(dh: TxChainRef; val: GasInt) =
  ## Temorarily overwrite (until next header update). The argument might be
  ## adjusted so that it is in the proper range. This function
  ## is intended to support debugging and testing.
  dh.setGasLimits(val)

proc setBaseFee*(dh: TxChainRef; val: GasPrice) =
  ## Temorarily overwrite (until next header update). This function
  ## is intended to support debugging and testing.
  dh.baseFee = val

proc setAccountFns*(dh: TxChainRef;
                    nonceFn: TxChainNonce = getNonce;
                    balanceFn: TxChainBalance = getBalance) =
  ## Replace per sender account lookup functions. This function
  ## is intended to support debugging and testing.
  dh.nonceFn = nonceFn
  dh.balanceFn = balanceFn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
