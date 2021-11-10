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
  TxDbHeadNonce* =
    proc(rdb: ReadOnlyStateDB; account: EthAddress): AccountNonce
      {.gcsafe,raises: [Defect,CatchableError].}

  TxDbHeadBalance* =
    proc(rdb: ReadOnlyStateDB; account: EthAddress): UInt256
      {.gcsafe,raises: [Defect,CatchableError].}

  TxDbMiner = object
    ok: bool                   ## Have miner key
    key: PrivateKey            ## Signer key
    address: EthAddress        ## Coinbase

  TxDbHeadRef* = ref object ##\
    ## Cache the state of the block chain which serves as logical insertion
    ## point for a new block. This state is typically the canonical head
    ## when updated.
    db: BaseChainDB            ## Block chain database
    miner: TxDbMiner           ## Optional miner specs
    nonceFn: TxDbHeadNonce     ## Sender account `getNonce()` function
    balanceFn: TxDbHeadBalance ## Sender account `getBalance()` function

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


proc getBaseFee*(dh: TxDbHeadRef): UInt256 =
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


proc setGasLimits(dh: TxDbHeadRef; gasLimit: GasInt) =
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


proc update(dh: TxDbHeadRef; newHead: BlockHeader)
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

proc init*(T: type TxDbHeadRef; db: BaseChainDB; miner: Option[PrivateKey]): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor
  new result

  result.db = db
  result.update(db.getCanonicalHead)
  result.nonceFn = getNonce
  result.balanceFn = getBalance

  if miner.isSome:
    result.miner = TxDbMiner(
      ok:      true,
      key:     miner.get,
      address: miner.get.toPublicKey.toCanonicalAddress)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc accountBalance*(dh: TxDbHeadRef; account: EthAddress): UInt256
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getBalance()`
  dh.balanceFn(ReadOnlyStateDB(dh.accDb),account)

proc accountNonce*(dh: TxDbHeadRef; account: EthAddress): AccountNonce
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Wrapper around `getNonce()`
  dh.nonceFn(ReadOnlyStateDB(dh.accDb),account)

proc nextHeader*(dh: TxDbHeadRef; gasLimit: GasInt): BlockHeader
    {.gcsafe,raises: [Defect,ValueError].} =
  ## Generate a new header the parent header is child of
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

proc db*(dh: TxDbHeadRef): BaseChainDB =
  ## Getter
  dh.db

proc head*(dh: TxDbHeadRef): BlockHeader =
  ## Getter
  dh.head

proc fork*(dh: TxDbHeadRef): Fork =
  ## Getter
  dh.fork

proc baseFee*(dh: TxDbHeadRef): GasPrice =
  ## Getter
  dh.baseFee

proc trgGasLimit*(dh: TxDbHeadRef): GasInt =
  ## Getter
  dh.trgGasLimit

proc maxGasLimit*(dh: TxDbHeadRef): GasInt =
  ## Getter
  dh.maxGasLimit

proc minGasLimit*(dh: TxDbHeadRef): GasInt =
  ## Getter
  dh.minGasLimit

proc coinbase*(dh: TxDbHeadRef): EthAddress =
  ## Getter
  dh.coinbase

proc extraData*(dh: TxDbHeadRef): Blob =
  ## Getter
  dh.extraData

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `head=`*(dh: TxDbHeadRef; header: BlockHeader)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Setter, updates descriptor
  dh.update(header)

proc `coinbase=`*(dh: TxDbHeadRef; val: EthAddress) =
  ## Setter
  dh.coinbase = val

proc `extraData=`*(dh: TxDbHeadRef; val: Blob) =
  ## Setter
  dh.extraData = val

# ------------------------------------------------------------------------------
# Public functions, debugging & testing
# ------------------------------------------------------------------------------

proc setGasLimit*(dh: TxDbHeadRef; val: GasInt) =
  ## Temorarily overwrite (until next header update). The argument might be
  ## adjusted so that it is in the proper range.
  dh.setGasLimits(val)

proc setBaseFee*(dh: TxDbHeadRef; val: GasPrice) =
  ## Temorarily overwrite (until next header update). This function
  ## is intended to support debugging and testing.
  dh.baseFee = val

proc setAccountFns*(dh: TxDbHeadRef;
                    nonceFn: TxDbHeadNonce = getNonce;
                    balanceFn: TxDbHeadBalance = getBalance) =
  ## Replace per sender account lookup functions. This function
  ## is intended to support debugging and testing.
  dh.nonceFn = nonceFn
  dh.balanceFn = balanceFn

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
