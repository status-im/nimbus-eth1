# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: AristoDbRef, parent: AristoTxRef): Result[AristoTxRef,AristoError] =
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

  let parent = if parent == nil:
    db.txRef
  else:
    parent

  let
    vTop = parent.layer.vTop
    layer = LayerRef(vTop:  vTop, cTop: vTop)

  ok AristoTxRef(
    db:     db,
    parent: parent,
    layer: layer)

proc baseTxFrame*(db: AristoDbRef): AristoTxRef=
  db.txRef

proc rollback*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  # TODO Everyone using this txref should repoint their parent field

  let vTop = tx.layer[].cTop
  tx.layer[] = Layer(vTop: vTop, cTop: vTop)

  ok()


proc commit*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## This function pushes all changes done in this frame to its parent
  ##
  # TODO Everyone using this txref should repoint their parent field
  doAssert tx.parent != nil, "should not commit the base tx"

  # A rollback after commit should reset to the new vTop!
  tx.layer[].cTop = tx.layer[].vTop

  mergeAndReset(tx.parent.layer[], tx.layer[])
  ok()


proc collapse*(
    tx: AristoTxRef;                  # Top transaction on database
    commit: bool;                     # Commit if `true`, otherwise roll back
      ): Result[void,AristoError] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   while true:
  ##     discard tx.commit() # ditto for rollback()
  ##     if db.txFrameTop.isErr: break
  ##     tx = db.txFrameTop.value
  ##
  # let db = ? tx.getDbDescFromTopTx()

  # db.top.txUid = 0
  # db.stack.setLen(0)
  # db.txRef = AristoTxRef(nil)
  ok()

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator walk*(tx: AristoTxRef): (int,AristoTxRef,LayerRef,AristoError) =
  ## Walk down the transaction stack chain.
  let db = tx.db
  # var tx = tx

  # block body:
  #   # Start at top layer if tx refers to that
  #   if tx.level == db.stack.len:
  #     if tx.txUid != db.top.txUid:
  #       yield (-1,tx,db.top,TxStackGarbled)
  #       break body

  #     # Yield the top level
  #     yield (0,tx,db.top,AristoError(0))

  #   # Walk down the transaction stack
  #   for level in (tx.level-1).countdown(1):
  #     tx = tx.parent
  #     if tx.isNil or tx.level != level:
  #       yield (-1,tx,LayerRef(nil),TxStackGarbled)
  #       break body

  #     var layer = db.stack[level]
  #     if tx.txUid != layer.txUid:
  #       yield (-1,tx,layer,TxStackGarbled)
  #       break body

  #     yield (db.stack.len-level,tx,layer,AristoError(0))

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
