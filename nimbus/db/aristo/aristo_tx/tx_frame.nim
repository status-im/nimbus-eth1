# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction frames helper
## ======================================
##
{.push raises: [].}

import
  results,
  ".."/[aristo_desc, aristo_layers]

func txFrameIsTop*(tx: AristoTxRef): bool

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func getDbDescFromTopTx(tx: AristoTxRef): Result[AristoDbRef,AristoError] =
  if not tx.txFrameIsTop():
    return err(TxNotTopTx)
  let db = tx.db
  if tx.level != db.stack.len:
    return err(TxStackGarbled)
  ok db

proc getTxUid(db: AristoDbRef): uint =
  if db.txUidGen == high(uint):
    db.txUidGen = 0
  db.txUidGen.inc
  db.txUidGen

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func txFrameTop*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
  ## Getter, returns top level transaction if there is any.
  if db.txRef.isNil:
    err(TxNoPendingTx)
  else:
    ok(db.txRef)

func txFrameIsTop*(tx: AristoTxRef): bool =
  ## Getter, returns `true` if the argument `tx` referes to the current top
  ## level transaction.
  tx.db.txRef == tx and tx.db.top.txUid == tx.txUid

func txFrameLevel*(tx: AristoTxRef): int =
  ## Getter, positive nesting level of transaction argument `tx`
  tx.level

func txFrameLevel*(db: AristoDbRef): int =
  ## Getter, non-negative nesting level (i.e. number of pending transactions)
  if not db.txRef.isNil:
    result = db.txRef.level

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
  ## Starts a new transaction.
  ##
  ## Example:
  ## ::
  ##   proc doSomething(db: AristoDbRef) =
  ##     let tx = db.begin
  ##     defer: tx.rollback()
  ##     ... continue using db ...
  ##     tx.commit()
  ##
  if db.txFrameLevel != db.stack.len:
    return err(TxStackGarbled)

  let vTop = db.top.vTop
  db.stack.add db.top
  db.top = LayerRef(
    vTop:  vTop,
    txUid: db.getTxUid)

  db.txRef = AristoTxRef(
    db:     db,
    txUid:  db.top.txUid,
    parent: db.txRef,
    level:  db.stack.len)

  ok db.txRef


proc txFrameRollback*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  let db = ? tx.getDbDescFromTopTx()

  # Roll back to previous layer.
  db.top = db.stack[^1]
  db.stack.setLen(db.stack.len-1)

  db.txRef = db.txRef.parent
  ok()


proc txFrameCommit*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  let db = ? tx.getDbDescFromTopTx()

  # Pop layer from stack and merge database top layer onto it
  let merged = db.stack.pop()
  if not merged.isEmpty():
    # No need to update top if we popped an empty layer
    if not db.top.isEmpty():
      # Only call `layersMergeOnto()` if layer is empty
      db.top.layersMergeOnto merged[]

    # Install `merged` stack top layer and update stack
    db.top = merged

  db.txRef = tx.parent
  if 0 < db.stack.len:
    db.txRef.txUid = db.getTxUid
    db.top.txUid = db.txRef.txUid
  ok()


proc txFrameCollapse*(
    tx: AristoTxRef;                  # Top transaction on database
    commit: bool;                     # Commit if `true`, otherwise roll back
      ): Result[void,AristoError] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   while true:
  ##     discard tx.commit() # ditto for rollback()
  ##     if db.txTop.isErr: break
  ##     tx = db.txTop.value
  ##
  let db = ? tx.getDbDescFromTopTx()

  db.top.txUid = 0
  db.stack.setLen(0)
  db.txRef = AristoTxRef(nil)
  ok()

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator txFrameWalk*(tx: AristoTxRef): (int,AristoTxRef,LayerRef,AristoError) =
  ## Walk down the transaction stack chain.
  let db = tx.db
  var tx = tx

  block body:
    # Start at top layer if tx refers to that
    if tx.level == db.stack.len:
      if tx.txUid != db.top.txUid:
        yield (-1,tx,db.top,TxStackGarbled)
        break body

      # Yield the top level
      yield (0,tx,db.top,AristoError(0))

    # Walk down the transaction stack
    for level in (tx.level-1).countDown(1):
      tx = tx.parent
      if tx.isNil or tx.level != level:
        yield (-1,tx,LayerRef(nil),TxStackGarbled)
        break body

      var layer = db.stack[level]
      if tx.txUid != layer.txUid:
        yield (-1,tx,layer,TxStackGarbled)
        break body

      yield (db.stack.len-level,tx,layer,AristoError(0))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
