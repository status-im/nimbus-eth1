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
  ../tx_desc,
  ../tx_gauge,
  ../tx_info,
  ../tx_item,
  ../tx_tabs,
  ./tx_classify,
  chronicles,
  eth/[common, keys]

logScope:
  topics = "tx-pool add transaction"

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

# core/tx_pool.go(848): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(854): func (pool *TxPool) AddLocals(txs []..
# core/tx_pool.go(864): func (pool *TxPool) AddRemotes(txs []..
# core/tx_pool.go(883): func (pool *TxPool) AddRemotes(txs []..
# core/tx_pool.go(889): func (pool *TxPool) addTxs(txs []*types.Transaction, ..
proc addTx*(xp: TxPoolRef; tx: var Transaction; local: bool;  info = "")
    {.gcsafe,raises: [Defect,CatchableError].} =
  ## Queue a transaction. Thetransaction is tested and moved to either of
  ## the `queued` or `pending` waiting queues, or into the waste basket.
  var
    status = txItemQueued
    vetted = txInfoOk

  # Leave this frame with `continue`, or proceeed with error
  block txErrorFrame:
    var
      itemID = tx.itemID
      item: TxItemRef

    # Create tx ID and check for dups
    if xp.txDB.byItemID.hasKey(itemID):
      vetted = txInfoErrAlreadyKnown
      break txErrorFrame

    # Create tx wrapper with meta data (status may be changed, later)
    block:
      let rc = tx.newTxItemRef(itemID, local, status, info)
      if rc.isErr:
        vetted = txInfoErrInvalidSender
        break txErrorFrame
      item = rc.value

    # Verify transaction
    vetted = xp.classifyTxValid(item)
    if vetted != txInfoOk:
      break txErrorFrame

    # Update initial state
    if xp.classifyTxPending(item):
      status = txItemPending
      item.status = status

    # Insert into database
    let rc = xp.txDB.insert(item)
    if rc.isErr:
      vetted = rc.error
      break txErrorFrame

    # All done, this time
    validTxMeter(1)
    return

    # Error processing below

  # store tx in waste basket
  xp.txDB.reject(tx, vetted, local, status, info)

  # update gauge
  case vetted:
  of txInfoErrAlreadyKnown:
    knownTxMeter(1)
  of txInfoErrInvalidSender:
    invalidTxMeter(1)
  else:
    unspecifiedErrorMeter(1)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
