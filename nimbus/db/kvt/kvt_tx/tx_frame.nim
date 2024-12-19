# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Transaction frames helper
## ===================================
##
{.push raises: [].}

import
  results,
  ../[kvt_desc, kvt_layers]


# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: KvtDbRef, parent: KvtTxRef): Result[KvtTxRef,KvtError] =
  ## Starts a new transaction.
  ##
  ## Example:
  ## ::
  ##   proc doSomething(db: KvtDbRef) =
  ##     let tx = db.begin
  ##     defer: tx.rollback()
  ##     ... continue using db ...
  ##     tx.commit()
  ##

  let parent = if parent == nil: db.txRef else: parent
  ok KvtTxRef(
    db:     db,
    layer: LayerRef(),
    parent: parent,
  )

proc baseTxFrame*(db: KvtDbRef): KvtTxRef =
  db.txRef

proc rollback*(
    tx: KvtTxRef;                     # Top transaction on database
      ): Result[void,KvtError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##

  tx.layer = LayerRef()
  ok()

proc commit*(
    tx: KvtTxRef;                     # Top transaction on database
      ): Result[void,KvtError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  doAssert tx.parent != nil, "don't commit base tx"

  mergeAndReset(tx.parent.layer[], tx.layer[])

  ok()

proc collapse*(
    tx: KvtTxRef;                     # Top transaction on database
    commit: bool;                     # Commit if `true`, otherwise roll back
      ): Result[void,KvtError] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   while true:
  ##     discard tx.commit() # ditto for rollback()
  ##     if db.topTx.isErr: break
  ##     tx = db.topTx.value
  ##
  # let db = ? tx.getDbDescFromTopTx()

  # if commit:
  #   db.top = db.layersCc
  # else:
  #   db.top = db.stack[0]
  #   # db.top.txUid = 0

  # # Clean up
  # db.stack.setLen(0)
  # db.txRef = KvtTxRef(nil)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
