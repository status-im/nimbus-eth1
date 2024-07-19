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

import std/tables, results, ".."/[kvt_desc, kvt_layers]

func txFrameIsTop*(tx: KvtTxRef): bool

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func getDbDescFromTopTx(tx: KvtTxRef): Result[KvtDbRef, KvtError] =
  if not tx.txFrameIsTop():
    return err(TxNotTopTx)
  let db = tx.db
  if tx.level != db.stack.len:
    return err(TxStackUnderflow)
  ok db

proc getTxUid(db: KvtDbRef): uint =
  if db.txUidGen == high(uint):
    db.txUidGen = 0
  db.txUidGen.inc
  db.txUidGen

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func txFrameTop*(db: KvtDbRef): Result[KvtTxRef, KvtError] =
  ## Getter, returns top level transaction if there is any.
  if db.txRef.isNil:
    err(TxNoPendingTx)
  else:
    ok(db.txRef)

func txFrameIsTop*(tx: KvtTxRef): bool =
  ## Getter, returns `true` if the argument `tx` referes to the current top
  ## level transaction.
  tx.db.txRef == tx and tx.db.top.txUid == tx.txUid

func txFrameLevel*(tx: KvtTxRef): int =
  ## Getter, positive nesting level of transaction argument `tx`
  tx.level

func txFrameLevel*(db: KvtDbRef): int =
  ## Getter, non-negative nesting level (i.e. number of pending transactions)
  if not db.txRef.isNil:
    result = db.txRef.level

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: KvtDbRef): Result[KvtTxRef, KvtError] =
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
  if db.txFrameLevel != db.stack.len:
    return err(TxStackGarbled)

  db.stack.add db.top
  db.top = LayerRef(txUid: db.getTxUid)
  db.txRef =
    KvtTxRef(db: db, txUid: db.top.txUid, parent: db.txRef, level: db.stack.len)

  ok db.txRef

proc txFrameRollback*(
    tx: KvtTxRef, # Top transaction on database
): Result[void, KvtError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  let db = ?tx.getDbDescFromTopTx()

  # Roll back to previous layer.
  db.top = db.stack[^1]
  db.stack.setLen(db.stack.len - 1)

  db.txRef = tx.parent
  ok()

proc txFrameCommit*(
    tx: KvtTxRef, # Top transaction on database
): Result[void, KvtError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  let db = ?tx.getDbDescFromTopTx()

  # Replace the top two layers by its merged version
  let merged = db.stack[^1]
  for (key, val) in db.top.sTab.pairs:
    merged.sTab[key] = val

  # Install `merged` layer
  db.top = merged
  db.stack.setLen(db.stack.len - 1)
  db.txRef = tx.parent
  if 0 < db.stack.len:
    db.txRef.txUid = db.getTxUid
    db.top.txUid = db.txRef.txUid

  ok()

proc txFrameCollapse*(
    tx: KvtTxRef, # Top transaction on database
    commit: bool, # Commit if `true`, otherwise roll back
): Result[void, KvtError] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   while true:
  ##     discard tx.commit() # ditto for rollback()
  ##     if db.topTx.isErr: break
  ##     tx = db.topTx.value
  ##
  let db = ?tx.getDbDescFromTopTx()

  if commit:
    db.top = db.layersCc
  else:
    db.top = db.stack[0]
    db.top.txUid = 0

  # Clean up
  db.stack.setLen(0)
  db.txRef = KvtTxRef(nil)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
