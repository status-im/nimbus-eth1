# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
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
  ../../db/db_chain,
  ./tx_dbhead,
  ./tx_info,
  ./tx_item,
  ./tx_job,
  ./tx_tabs,
  ./tx_tabs/tx_sender, # for verify()
  eth/[common, keys]

{.push raises: [Defect].}

type
  TxPoolCallBackRecursion* = object of Defect
    ## Attempt to recurse a call back function

  TxPoolFlags* = enum ##\
    ## Processing strategy selector symbols

    algoPacked1559MinFee ##\
      ## Include tx items which have at least this `maxFee`, other items
      ## are considered underpriced.
      ##
      ## This is post-London only strategy only applicable to post-London
      ## transactions.

    algoPacked1559MinTip ##\
      ## Include tx items which have a tip at least this `estimatedGasTip`.
      ##
      ## This is post-London effecticve strategy with some legacy fall
      ## back mode (see implementation of `estimatedGasTip`.)

    algoPackedPlMinPrice ##\
      ## Tx items are included where the gas proce is at least this `gasPrice`,
      ## other items are considered underpriced.
      ##
      ## This is a legacy pre-London strategy to apply instead of
      ## `stage1559MinTip`.

    # -----------

    algoPackTrgGasLimitMax ##\
      ## If unset, the packer must not exceed `xp.dbHead.trgGasLimit` when
      ## collecting txs for a new block. Otherwise another tx exceeding the
      ## `xp.dbHead.trgGasLimit` is accepted if it stays within the
      ## `xp.dbHead.trgMaxLimit`.

    algoPackTryHarder ##\
      ## When packing, do not stop at the first failure to add another block,
      ## rather ignore that error and keep on trying for all blocks

    # -----------

    algoAutoDisposeUnpacked ##\
      ## Automatically dispose *pending* or *staged* txs that were queued
      ## at least `lifeTime` ago.

    algoAutoDisposePacked ##\
      ## Automatically dispose *packed* txs that were queued
      ## at least `lifeTime` ago.

    algoAutoUpdateBuckets ##\
      ## Automatically update buckets if the `dirtyBuckets` flag is set. For
      ## the `packed` bucket this means that txs that do not fit the boundary
      ## conditions anymore are moved out into one of the other buckets. The
      ## `dirtyBuckets` flag will be reset after processing.

    algoAutoTxsPacker ##\
      ## Automatically pack transactions if the `xp.stagedItems` flag is set.
      ## This flag will be reset after processing.


  TxPoolParam* = tuple          ## Getter/setter accessible parameters
    minFeePrice: GasPrice       ## Gas price enforced by the pool, `gasFeeCap`
    minTipPrice: GasPrice       ## Desired tip-per-tx target, `estimatedGasTip`
    minPlGasPrice: GasPrice     ## Desired pre-London min `gasPrice`
    stagedItems: bool           ## Some items were staged (since last check)
    dirtyBuckets: bool          ## Buckets need to be updated
    doubleCheck: seq[TxItemRef] ## Check items after moving block chain head
    algoFlags: set[TxPoolFlags] ## Packer strategy symbols


  TxPoolRef* = ref object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time             ## Start date (read-only)

    dbHead: TxDbHeadRef         ## block chain state
    byJob: TxJobRef             ## Job batch list
    txDB: TxTabsRef             ## Transaction lists & tables

    lifeTime*: times.Duration   ## Maximum life time of a tx in the system
    priceBump*: uint            ## Min precentage price when superseding

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
  txPoolAlgoStrategy = {algoPacked1559MinTip,
                         algoPacked1559MinFee,
                         algoPackedPlMinPrice,
                         algoAutoDisposeUnpacked}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc init(xp: TxPoolRef; db: BaseChainDB)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor, returns new tx-pool descriptor.
  xp.startDate = getTime().utc.toTime

  xp.dbHead = TxDbHeadRef.init(db)
  xp.txDB = TxTabsRef.init
  xp.byJob = TxJobRef.init

  xp.lifeTime = txItemLifeTime
  xp.priceBump = txPriceBump

  xp.param.reset
  xp.param.minFeePrice = txMinFeePrice
  xp.param.minTipPrice = txMinTipPrice
  xp.param.algoFlags = txPoolAlgoStrategy

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxPoolRef; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Ditto
  new result
  result.init(db)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc startDate*(xp: TxPoolRef): Time =
  ## Getter
  xp.startDate

proc txDB*(xp: TxPoolRef): TxTabsRef =
  ## Getter, pool database
  xp.txDB

proc byJob*(xp: TxPoolRef): TxJobRef =
  ## Getter, job queue
  xp.byJob

proc dbHead*(xp: TxPoolRef): TxDbHeadRef =
  ## Getter, block chain DB
  xp.dbHead

proc pDirtyBuckets*(xp: TxPoolRef): bool =
  ## Getter, buckets need update
  xp.param.dirtyBuckets

proc pStagedItems*(xp: TxPoolRef): bool =
  ## Getter, some updates since last check
  xp.param.stagedItems

proc pDoubleCheck*(xp: TxPoolRef): seq[TxItemRef] =
  ## Getter, cached block chain head was moved back
  xp.param.doubleCheck

proc pMinFeePrice*(xp: TxPoolRef): GasPrice =
  ## Getter
  xp.param.minFeePrice

proc pMinTipPrice*(xp: TxPoolRef): GasPrice =
  ## Getter
  xp.param.minTipPrice

proc pMinPlGasPrice*(xp: TxPoolRef): GasPrice =
  ## Getter
  xp.param.minPlGasPrice

proc pAlgoFlags*(xp: TxPoolRef): set[TxPoolFlags] =
  ## Returns the set of algorithm strategy symbols for labelling items
  ## as`packed`
  xp.param.algoFlags

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `pDirtyBuckets=`*(xp: TxPoolRef; val: bool) =
  ## Setter
  xp.param.dirtyBuckets = val

proc `pStagedItems=`*(xp: TxPoolRef; val: bool) =
  ## Setter
  xp.param.stagedItems = val

proc pDoubleCheckAdd*(xp: TxPoolRef; val: seq[TxItemRef]) =
  ## Pseudo setter
  xp.param.doubleCheck.add val

proc pDoubleCheckFlush*(xp: TxPoolRef) =
  ## Pseudo setter
  xp.param.doubleCheck.setLen(0)

proc `pMinFeePrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter
  xp.param.minFeePrice = val

proc `pMinTipPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter
  xp.param.minTipPrice = val

proc `pMinPlGasPrice=`*(xp: TxPoolRef; val: GasPrice) =
  ## Setter
  xp.param.minPlGasPrice = val

proc `pAlgoFlags=`*(xp: TxPoolRef; val: set[TxPoolFlags]) =
  ## Install a set of algorithm strategy symbols for labelling items as`packed`
  xp.param.algoFlags = val

# ------------------------------------------------------------------------------
# Public functions, heplers (debugging only)
# ------------------------------------------------------------------------------

proc verify*(xp: TxPoolRef): Result[void,TxInfo]
    {.gcsafe, raises: [Defect,CatchableError].} =
  ## Verify descriptor and subsequent data structures.

  block:
    let rc = xp.byJob.verify
    if rc.isErr:
      return rc
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

  for item in xp.txDB.bySender.walkItems:
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
