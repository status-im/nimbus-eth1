# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Descriptor
## ===========================
##

import
  std/[times],
  ../../common/common,
  ./tx_chain,
  ./tx_info,
  ./tx_item,
  ./tx_tabs,
  ./tx_tabs/tx_sender, # for verify()
  eth/keys

{.push raises: [].}

type
  TxPoolCallBackRecursion* = object of Defect
    ## Attempt to recurse a call back function

  TxPoolFlags* = enum ##\
    ## Processing strategy selector symbols

    stageItems1559MinFee ##\
      ## Stage tx items with `tx.maxFee` at least `minFeePrice`. Other items
      ## are left or set pending. This symbol affects post-London tx items,
      ## only.

    stageItems1559MinTip ##\
      ## Stage tx items with `tx.effectiveGasTip(baseFee)` at least
      ## `minTipPrice`. Other items are considered underpriced and left
      ## or set pending. This symbol affects post-London tx items, only.

    stageItemsPlMinPrice ##\
      ## Stage tx items with `tx.gasPrice` at least `minPreLondonGasPrice`.
      ## Other items are considered underpriced and left or set pending.
      ## This symbol affects pre-London tx items, only.

    # -----------

    packItemsMaxGasLimit ##\
      ## It set, the *packer* will execute and collect additional items from
      ## the `staged` bucket while accumulating `gasUsed` as long as
      ## `maxGasLimit` is not exceeded. If `packItemsTryHarder` flag is also
      ## set, the *packer* will not stop until at least `hwmGasLimit` is
      ## reached.
      ##
      ## Otherwise the *packer* will accumulate up until `trgGasLimit` is
      ## not exceeded, and not stop until at least `lwmGasLimit` is reached
      ## in case `packItemsTryHarder` is also set,

    packItemsTryHarder ##\
      ## It set, the *packer* will *not* stop accumulaing transactions up until
      ## the `lwmGasLimit` or `hwmGasLimit` is reached, depending on whether
      ## the `packItemsMaxGasLimit` is set. Otherwise, accumulating stops
      ## immediately before the next transaction exceeds `trgGasLimit`, or
      ## `maxGasLimit` depending on `packItemsMaxGasLimit`.

    # -----------

    autoUpdateBucketsDB ##\
      ## Automatically update the state buckets after running batch jobs if
      ## the `dirtyBuckets` flag is also set.

    autoZombifyUnpacked ##\
      ## Automatically dispose *pending* or *staged* txs that were queued
      ## at least `lifeTime` ago.

    autoZombifyPacked ##\
      ## Automatically dispose *packed* txs that were queued
      ## at least `lifeTime` ago.

  TxPoolParam* = tuple          ## Getter/setter accessible parameters
    minFeePrice: GasPrice       ## Gas price enforced by the pool, `gasFeeCap`
    minTipPrice: GasPrice       ## Desired tip-per-tx target, `effectiveGasTip`
    minPlGasPrice: GasPrice     ## Desired pre-London min `gasPrice`
    dirtyBuckets: bool          ## Buckets need to be updated
    doubleCheck: seq[TxItemRef] ## Check items after moving block chain head
    flags: set[TxPoolFlags]     ## Processing strategy symbols

  TxPoolRef* = ref object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time             ## Start date (read-only)

    chain: TxChainRef           ## block chain state
    txDB: TxTabsRef             ## Transaction lists & tables

    lifeTime*: times.Duration   ## Maximum life time of a tx in the system
    priceBump*: uint            ## Min precentage price when superseding
    blockValue*: UInt256        ## Sum of reward received by feeRecipient

    param: TxPoolParam          ## Getter/Setter parameters

const
  txItemLifeTime = ##\
    ## Maximum amount of time transactions can be held in the database\
    ## unless they are packed already for a block. This default is chosen\
    ## as found in core/tx_pool.go(184) of the geth implementation.
    initDuration(hours = 3)

  txPriceBump = ##\
    ## Minimum price bump percentage to replace an already existing\
    ## transaction (nonce). This default is chosen as found in\
    ## core/tx_pool.go(177) of the geth implementation.
    10u

  txMinFeePrice = 1.GasPrice
  txMinTipPrice = 1.GasPrice
  txPoolFlags = {stageItems1559MinTip,
                  stageItems1559MinFee,
                  stageItemsPlMinPrice,
                  packItemsTryHarder,
                  autoUpdateBucketsDB,
                  autoZombifyUnpacked}

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(xp: TxPoolRef; com: CommonRef)
    {.gcsafe,raises: [CatchableError].} =
  ## Constructor, returns new tx-pool descriptor.
  xp.startDate = getTime().utc.toTime

  xp.chain = TxChainRef.new(com)
  xp.txDB = TxTabsRef.new

  xp.lifeTime = txItemLifeTime
  xp.priceBump = txPriceBump

  xp.param.reset
  xp.param.minFeePrice = txMinFeePrice
  xp.param.minTipPrice = txMinTipPrice
  xp.param.flags = txPoolFlags

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func chain*(xp: TxPoolRef): TxChainRef =
  ## Getter, block chain DB
  xp.chain

func pFlags*(xp: TxPoolRef): set[TxPoolFlags] =
  ## Returns the set of algorithm strategy symbols for labelling items
  ## as`packed`
  xp.param.flags

func pDirtyBuckets*(xp: TxPoolRef): bool =
  ## Getter, buckets need update
  xp.param.dirtyBuckets

func pDoubleCheck*(xp: TxPoolRef): seq[TxItemRef] =
  ## Getter, cached block chain head was moved back
  xp.param.doubleCheck

func pMinFeePrice*(xp: TxPoolRef): GasPrice =
  ## Getter
  xp.param.minFeePrice

func pMinTipPrice*(xp: TxPoolRef): GasPrice =
  ## Getter
  xp.param.minTipPrice

func pMinPlGasPrice*(xp: TxPoolRef): GasPrice =
  ## Getter
  xp.param.minPlGasPrice

func startDate*(xp: TxPoolRef): Time =
  ## Getter
  xp.startDate

func txDB*(xp: TxPoolRef): TxTabsRef =
  ## Getter, pool database
  xp.txDB

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

func `pDirtyBuckets=`*(xp: TxPoolRef; val: bool) =
  ## Setter
  xp.param.dirtyBuckets = val

func pDoubleCheckAdd*(xp: TxPoolRef; val: seq[TxItemRef]) =
  ## Pseudo setter
  xp.param.doubleCheck.add val

func pDoubleCheckFlush*(xp: TxPoolRef) =
  ## Pseudo setter
  xp.param.doubleCheck.setLen(0)

func `pFlags=`*(xp: TxPoolRef; val: set[TxPoolFlags]) =
  ## Install a set of algorithm strategy symbols for labelling items as`packed`
  xp.param.flags = val

func `pMinFeePrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter
  xp.param.minFeePrice = val

func `pMinTipPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter
  xp.param.minTipPrice = val

func `pMinPlGasPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter
  xp.param.minPlGasPrice = val

# ------------------------------------------------------------------------------
# Public functions, heplers (debugging only)
# ------------------------------------------------------------------------------

proc verify*(xp: TxPoolRef): Result[void,TxInfo]
    {.gcsafe, raises: [CatchableError].} =
  ## Verify descriptor and subsequent data structures.

  block:
    let rc = xp.txDB.verify
    if rc.isErr:
      return rc

  # verify consecutive nonces per sender
  var
    initOk = false
    lastSender: EthAddress
    lastNonce: AccountNonce
    lastSublist: TxSenderSchedRef

  for (_,nonceList) in xp.txDB.incAccount:
    for item in nonceList.incNonce:
      if not initOk or lastSender != item.sender:
        initOk = true
        lastSender = item.sender
        lastNonce = item.tx.nonce
        lastSublist = xp.txDB.bySender.eq(item.sender).value.data
      elif lastNonce + 1 == item.tx.nonce:
        lastNonce = item.tx.nonce
      else:
        return err(txInfoVfyNonceChain)

      # verify bucket boundary conditions
      case item.status:
      of txItemPending:
        discard
      of txItemStaged:
        if lastSublist.eq(txItemPending).eq(item.tx.nonce - 1).isOk:
          return err(txInfoVfyNonceChain)
      of txItemPacked:
        if lastSublist.eq(txItemPending).eq(item.tx.nonce - 1).isOk:
          return err(txInfoVfyNonceChain)
        if lastSublist.eq(txItemStaged).eq(item.tx.nonce - 1).isOk:
          return err(txInfoVfyNonceChain)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
