# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Transaction Pool Tasklet: Add Transaction
## =========================================
##

import
  std/[tables],
  ../tx_desc,
  ../tx_gauge,
  ../tx_info,
  ../tx_item,
  ../tx_tabs,
  ./tx_classify,
  ./tx_recover,
  chronicles,
  eth/[common, keys],
  stew/[keyed_queue, sorted_set],
  ../../eip4844

{.push raises: [].}

type
  TxAddStats* = tuple ##\
    ## Status code returned from the `addTxs()` function

    stagedIndicator: bool ##\
      ## If `true`, this value indicates that at least one item was added to\
      ## the `staged` bucket (which suggest a re-run of the packer.)

    topItems: seq[TxItemRef] ##\
      ## For each sender where txs were added to the bucket database or waste\
      ## basket, this list keeps the items with the highest nonce (handy for\
      ## chasing nonce gaps after a back-move of the block chain head.)

  NonceList = ##\
    ## Temporary sorter list
    SortedSet[AccountNonce,TxItemRef]

  AccountNonceTab = ##\
    ## Temporary sorter table
    Table[EthAddress,NonceList]

logScope:
  topics = "tx-pool add transaction"

# ------------------------------------------------------------------------------
# Private helper
# ------------------------------------------------------------------------------

proc getItemList(tab: var AccountNonceTab; key: EthAddress): var NonceList
    {.gcsafe,raises: [KeyError].} =
  if not tab.hasKey(key):
    tab[key] = NonceList.init
  tab[key]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc supersede(xp: TxPoolRef; item: TxItemRef): Result[void,TxInfo]
    {.gcsafe,raises: [CatchableError].} =

  var current: TxItemRef

  block:
    let rc = xp.txDB.bySender.eq(item.sender).sub.eq(item.tx.nonce)
    if rc.isErr:
      return err(txInfoErrUnspecified)
    current = rc.value.data

  # verify whether replacing is allowed, at all
  let bumpPrice = (current.tx.gasPrice * xp.priceBump.GasInt + 99) div 100
  if item.tx.gasPrice < current.tx.gasPrice + bumpPrice:
    discard  # return err(txInfoErrReplaceUnderpriced)

  # make space, delete item
  if not xp.txDB.dispose(current, txInfoSenderNonceSuperseded):
    return err(txInfoErrVoidDisposal)

  # try again
  block:
    let rc = xp.txDB.insert(item)
    if rc.isErr:
      return err(rc.error)

  return ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc addTx*(xp: TxPoolRef; item: TxItemRef): bool
    {.discardable,gcsafe,raises: [CatchableError].} =
  ## Add a transaction item. It is tested and stored in either of the `pending`
  ## or `staged` buckets, or disposed into the waste basket. The function
  ## returns `true` if the item was added to the `staged` bucket.

  var
    # stagedItemAdded = false -- notused
    vetted = txInfoOk

  # Leave this frame with `return`, or proceeed with error
  block txErrorFrame:
    # Create tx ID and check for dups
    if xp.txDB.byItemID.hasKey(item.itemID):
      vetted = txInfoErrAlreadyKnown
      break txErrorFrame

    # Verify transaction
    if not xp.classifyValid(item):
      vetted = txInfoErrBasicValidatorFailed
      break txErrorFrame

    # Update initial state bucket
    item.status =
        if xp.classifyActive(item): txItemStaged
        else:                       txItemPending

    # Insert into database
    block:
      let rc = xp.txDB.insert(item)
      if rc.isOk:
        validTxMeter(1)
        return item.status == txItemStaged
      vetted = rc.error

    # need to replace tx with same <sender/nonce> as the new item
    if vetted == txInfoErrSenderNonceIndex:
      let rc = xp.supersede(item)
      if rc.isOk:
        validTxMeter(1)
        return
      vetted = rc.error

  # Error processing => store in waste basket
  xp.txDB.reject(item, vetted)

  # update gauge
  case vetted:
  of txInfoErrAlreadyKnown:
    knownTxMeter(1)
  of txInfoErrInvalidSender:
    invalidTxMeter(1)
  else:
    unspecifiedErrorMeter(1)


# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
# core/tx_pool.go(889): func (pool *TxPool) addTxs(txs []*types.Transaction, ..
proc addTxs*(xp: TxPoolRef;
             txs: openArray[PooledTransaction]; info = ""): TxAddStats
    {.discardable,gcsafe,raises: [CatchableError].} =
  ## Add a list of transactions. The list is sorted after nonces and txs are
  ## tested and stored into either of the `pending` or `staged` buckets, or
  ## disposed o the waste basket. The function returns the tuple
  ## `(staged-indicator,top-items)` as explained below.
  ##
  ## *stagedIndicator*
  ##   If `true`, this value indicates that at least one item was added to
  ##   the `staged` bucket (which suggest a re-run of the packer.)
  ##
  ## *topItems*
  ##   For each sender where txs were added to the bucket database or waste
  ##   basket, this list keeps the items with the highest nonce (handy for
  ##   chasing nonce gaps after a back-move of the block chain head.)
  ##
  var accTab: AccountNonceTab

  for tx in txs.items:
    var reason: TxInfo

    if tx.tx.txType == TxEip4844:
      let res = tx.validateBlobTransactionWrapper()
      if res.isErr:
        # move item to waste basket
        reason = txInfoErrInvalidBlob
        xp.txDB.reject(tx, reason, txItemPending, res.error)
        invalidTxMeter(1)
        continue

    # Create tx item wrapper, preferably recovered from waste basket
    let rcTx = xp.recoverItem(tx, txItemPending, info)
    if rcTx.isErr:
      reason = rcTx.error
    else:
      let
        item = rcTx.value
        rcInsert = accTab.getItemList(item.sender).insert(item.tx.nonce)
      if rcInsert.isErr:
        reason = txInfoErrSenderNonceIndex
      else:
        rcInsert.value.data = item # link that item
        continue

    # move item to waste basket
    xp.txDB.reject(tx, reason, txItemPending, info)

    # update gauge
    case reason:
    of txInfoErrAlreadyKnown:
      knownTxMeter(1)
    of txInfoErrInvalidSender:
      invalidTxMeter(1)
    else:
      unspecifiedErrorMeter(1)

  # Add sorted transaction items
  for itemList in accTab.mvalues:
    var
      rc = itemList.ge(AccountNonce.low)
      lastItem: TxItemRef # => nil

    while rc.isOk:
      let (nonce,item) = (rc.value.key,rc.value.data)
      if xp.addTx(item):
        result.stagedIndicator = true

      # Make sure that there is at least one item per sender, prefereably
      # a non-error item.
      if item.reject == txInfoOk or lastItem.isNil:
        lastItem = item
      rc = itemList.gt(nonce)

    # return the last one in the series
    if not lastItem.isNil:
      result.topItems.add lastItem

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
