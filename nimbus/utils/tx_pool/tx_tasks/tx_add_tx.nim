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
  ../../keyed_queue,
  ../tx_desc,
  ../tx_gauge,
  ../tx_info,
  ../tx_item,
  ../tx_tabs,
  ./tx_classify,
  ./tx_recover_item,
  chronicles,
  eth/[common, keys]

logScope:
  topics = "tx-pool add transaction"

{.push raises: [Defect].}

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc supersede(xp: TxPoolRef; item: TxItemRef): Result[void,TxInfo]
    {.gcsafe,raises: [Defect,CatchableError].} =

  var current: TxItemRef

  block:
    let rc = xp.txDB.bySender.eq(item.sender).any.eq(item.tx.nonce)
    if rc.isErr:
      return err(txInfoErrUnspecified)
    current = rc.value.data

  # verify whether replacing is allowed, at all
  let bumpPrice = (current.tx.gasPrice * xp.priceBump.GasInt + 99) div 100
  if item.tx.gasPrice < current.tx.gasPrice + bumpPrice:
    return err(txInfoErrReplaceUnderpriced)

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

proc addTx*(xp: TxPoolRef; item: TxItemRef)
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Add a transaction item. It is tested and stored in either of the `pending`
  ## or `staged` buckets, or disposed into the waste basket.
  let
    param = TxClassify(
      gasLimit: xp.dbHead.trgGasLimit,
      baseFee: xp.dbHead.baseFee)
  var
    vetted = txInfoOk

  # Leave this frame with `return`, or proceeed with error
  block txErrorFrame:
    # Create tx ID and check for dups
    if xp.txDB.byItemID.hasKey(item.itemID):
      vetted = txInfoErrAlreadyKnown
      break txErrorFrame

    # Verify transaction
    if not xp.classifyTxValid(item,param):
      vetted = txInfoErrBasicValidatorFailed
      break txErrorFrame

    # Update initial state bucket
    item.status =
        if xp.classifyTxStaged(item,param): txItemStaged
        else:                               txItemPending

    # Insert into database
    block:
      let rc = xp.txDB.insert(item)
      if rc.isOK:
        validTxMeter(1)
        return
      vetted = rc.error

    # need to replace tx with same <sender/nonce> as the new item
    if vetted == txInfoErrSenderNonceIndex:
      let rc = xp.supersede(item)
      if rc.isOK:
        validTxMeter(1)
        return
      vetted = rc.error

    # Error processing below

  # Error => store in waste basket
  xp.txDB.reject(item.tx, vetted, item.status, item.info)

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
proc addTx*(xp: TxPoolRef; tx: var Transaction; info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Add a transaction. It is tested and stored into either of the `pending`
  ## or `staged` buckets, or disposed o the waste basket.

  # Create tx item wrapper, preferably recovered from waste basket
  let rc = xp.recoverItem(tx, txItemPending, info)
  if rc.isOk:
    xp.addTx(rc.value)
    return

  # Error => store tx in waste basket
  xp.txDB.reject(tx, rc.error, txItemPending, info)

  # update gauge
  case rc.error:
  of txInfoErrAlreadyKnown:
    knownTxMeter(1)
  of txInfoErrInvalidSender:
    invalidTxMeter(1)
  else:
    unspecifiedErrorMeter(1)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
