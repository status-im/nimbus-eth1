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

type
  TxPoolCallBackRecursion* = object of Defect
    ## Attempt to recurse a call back function

  TxPoolAlgoSelectorFlags* = enum ##\
    ## Algorithm strategy selector symbols for staging transactions

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
      ## When packing, do not exceed `xp.dbHead.trgGasLimit`, otherwise another
      ## block exceeding the `xp.dbHead.trgGasLimit` is accepted if it stays
      ## within the `xp.dbHead.trgMaxLimit`

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


  TxPoolEthBlock* = tuple      ## Sub-entry for `TTxPoolParam`
    blockHeader: BlockHeader   ## Cached header for new block
    blockItems: seq[TxItemRef] ## List opf transactions for new block
    blockSize: GasInt          ## Summed up `gasLimit` entries of `blockItems[]`

  TxPoolPrice = tuple          ## Sub-entry for `TxPoolParam`
    curPrice: GasPrice         ## Value to hold and track
    prvPrice: GasPrice         ## Previous value for derecting changes

  TxPoolParam* = tuple         ## Getter/setter accessible parameters
    minFee: TxPoolPrice        ## Gas price enforced by the pool, `gasFeeCap`
    minTip: TxPoolPrice        ## Desired tip-per-tx target, `estimatedGasTip`
    minPlGas: TxPoolPrice      ## Desired pre-London min `gasPrice`
    blockCache: TxPoolEthBlock ## Cached header for new block

    dirtyStaged: bool          ## Staged bucket needs update
    dirtyPacked: bool          ## Stage bucket needs update

    algoSelect: set[TxPoolAlgoSelectorFlags] ## Packer strategy symbols


  TxPoolRef* = ref object of RootObj ##\
    ## Transaction pool descriptor
    startDate: Time            ## Start date (read-only)

    dbHead: TxDbHeadRef        ## block chain state
    byJob: TxJobRef            ## Job batch list
    txDB: TxTabsRef            ## Transaction lists & tables

    lifeTime*: times.Duration  ## Maximum life time of a tx in the system
    priceBump*: uint           ## Min precentage price when superseding
    param: TxPoolParam         ## Getter/setter accessible parameters

const
  txPoolLifeTime = ##\
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

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc init(xp: TxPoolRef; db: BaseChainDB)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Constructor, returns new tx-pool descriptor.
  xp.startDate = getTime().utc.toTime

  xp.dbHead = TxDbHeadRef.init(db)
  xp.txDB = TxTabsRef.init(xp.dbHead.baseFee)
  xp.byJob = TxJobRef.init

  xp.lifeTime = txPoolLifeTime
  xp.priceBump = txPriceBump

  xp.param.reset
  xp.param.minFee.curPrice = txMinFeePrice
  xp.param.minTip.curPrice = txMinTipPrice
  xp.param.algoSelect = txPoolAlgoStrategy

# ------------------------------------------------------------------------------
# Private functions, generic getter/setter
# ------------------------------------------------------------------------------

proc getPoolPrice(xp: TxPoolRef; param: var TxPoolPrice): GasPrice {.inline.} =
  ## Generic getter
  param.curPrice

proc setPoolPrice(xp: TxPoolRef;
                  param: var TxPoolPrice; val: GasPrice) {.inline.} =
  ## Generic setter
  if param.curPrice != val:
    param.prvPrice = param.curPrice
    param.curPrice = val

proc poolPriceChanged(xp: TxPoolRef; param: var TxPoolPrice): bool {.inline.} =
  ## Returns `true` if there was a change, and resets the change detector.
  if param.prvPrice != param.curPrice:
    param.prvPrice = param.curPrice
    result = true

# ------------------------------------------------------------------------------
# Public functions, constructor
# ------------------------------------------------------------------------------

proc init*(T: type TxPoolEthBlock): T {.inline.}=
  ## Syntactic sugar for reset value to be used in setter
  discard

proc init*(T: type TxPoolRef; db: BaseChainDB): T
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Ditto
  new result
  result.init(db)

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc startDate*(xp: TxPoolRef): Time {.inline.} =
  ## Getter
  xp.startDate

proc txDB*(xp: TxPoolRef): TxTabsRef {.inline.} =
  ## Getter, pool database
  xp.txDB

proc byJob*(xp: TxPoolRef): TxJobRef {.inline.} =
  ## Getter, job queue
  xp.byJob

proc dbHead*(xp: TxPoolRef): TxDbHeadRef {.inline.} =
  ## Getter, block chain DB
  xp.dbHead

proc blockCache*(xp: TxPoolRef): TxPoolEthBlock {.inline.} =
  ## Getter, cached pieces of a block
  xp.param.blockCache

proc dirtyStaged*(xp: TxPoolRef): bool {.inline.} =
  ## Getter, `staged` bucket needs update
  xp.param.dirtyStaged

proc dirtyPacked*(xp: TxPoolRef): bool {.inline.} =
  ## Getter, `packed` bucket needs update
  xp.param.dirtyPacked

proc minFeePrice*(xp: TxPoolRef): GasPrice
    {.inline,gcsafe,raises: [Defect,CatchableError].} =
  ## Getter, synchronised access
  xp.getPoolPrice(xp.param.minFee)

proc minFeePriceChanged*(xp: TxPoolRef): bool {.inline.} =
  ## Returns `true` if there was a `nimFeePrice` change and resets
  ## the change detection.
  xp.poolPriceChanged(xp.param.minFee)

proc minTipPrice*(xp: TxPoolRef): GasPrice {.inline.} =
  ## Getter, synchronised access
  xp.getPoolPrice(xp.param.minTip)

proc minTipPriceChanged*(xp: TxPoolRef): bool {.inline.} =
  ## Returns `true` if there was a `nimTipPrice` change and resets
  ## the change detection.
  xp.poolPriceChanged(xp.param.minTip)

proc minPlGasPrice*(xp: TxPoolRef): GasPrice {.inline.} =
  ## Getter, synchronised access
  xp.getPoolPrice(xp.param.minPlGas)

proc minPlGasPriceChanged*(xp: TxPoolRef): bool {.inline.} =
  ## Returns `true` if there was a `nimTipPrice` change and resets
  ## the change detection.
  xp.poolPriceChanged(xp.param.minPlGas)

proc algoSelect*(xp: TxPoolRef): set[TxPoolAlgoSelectorFlags] {.inline.} =
  ## Returns the set of algorithm strategy symbols for labelling items
  ## as`packed`
  xp.param.algoSelect

# ------------------------------------------------------------------------------
# Public functions, setters
# ------------------------------------------------------------------------------

proc `blockCache=`*(xp: TxPoolRef; val: TxPoolEthBlock) {.inline.} =
  ## Setter
  xp.param.blockCache = val

proc `dirtyStaged=`*(xp: TxPoolRef; val: bool) {.inline.} =
  ## Setter
  xp.param.dirtyStaged = val

proc `dirtyPacked=`*(xp: TxPoolRef; val: bool) {.inline.} =
  ## Setter
  xp.param.dirtyPacked = val

proc `minFeePrice=`*(xp: TxPoolRef; val: GasPrice) {.inline.} =
  ## Setter, synchronised access
  xp.setPoolPrice(xp.param.minFee,val)

proc `minTipPrice=`*(xp: TxPoolRef; val: GasPrice) {.inline.} =
  ## Setter, synchronised access
  xp.setPoolPrice(xp.param.minTip,val)

proc `minPlGasPrice=`*(xp: TxPoolRef; val: GasPrice) {.inline.} =
  ## Setter, synchronised access
  xp.setPoolPrice(xp.param.minPlGas,val)

proc `algoSelect=`*(xp: TxPoolRef;
                    val: set[TxPoolAlgoSelectorFlags]){.inline.} =
  ## Install a set of algorithm strategy symbols for labelling items as`packed`
  xp.param.algoSelect = val

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
