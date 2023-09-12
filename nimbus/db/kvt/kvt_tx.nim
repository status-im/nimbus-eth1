# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Kvt DB -- Transaction interface
## ===============================
##
{.push raises: [].}

import
  std/[sequtils, tables],
  results,
  ./kvt_desc/desc_backend,
  ./kvt_desc

func isTop*(tx: KvtTxRef): bool

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func getDbDescFromTopTx(tx: KvtTxRef): Result[KvtDbRef,KvtError] =
  if not tx.isTop():
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

func txTop*(db: KvtDbRef): Result[KvtTxRef,KvtError] =
  ## Getter, returns top level transaction if there is any.
  if db.txRef.isNil:
    err(TxNoPendingTx)
  else:
    ok(db.txRef)

func isTop*(tx: KvtTxRef): bool =
  ## Getter, returns `true` if the argument `tx` referes to the current top
  ## level transaction.
  tx.db.txRef == tx and tx.db.top.txUid == tx.txUid

func level*(tx: KvtTxRef): int =
  ## Getter, positive nesting level of transaction argument `tx`
  tx.level

func level*(db: KvtDbRef): int =
  ## Getter, non-negative nesting level (i.e. number of pending transactions)
  if not db.txRef.isNil:
    result = db.txRef.level

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(tx: KvtTxRef; T: type[KvtDbRef]): T =
  ## Getter, retrieves the parent database descriptor from argument `tx`
  tx.db

# ------------------------------------------------------------------------------
# Public functions: Transaction frame
# ------------------------------------------------------------------------------

proc txBegin*(db: KvtDbRef): Result[KvtTxRef,KvtError] =
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
  if db.level != db.stack.len:
    return err(TxStackGarbled)

  db.stack.add db.top.dup # push (save and use top later)
  db.top.txUid = db.getTxUid()

  db.txRef = KvtTxRef(
    db:     db,
    txUid:  db.top.txUid,
    parent: db.txRef,
    level:  db.stack.len)

  ok db.txRef

proc rollback*(
    tx: KvtTxRef;                     # Top transaction on database
      ): Result[void,KvtError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  let db = ? tx.getDbDescFromTopTx()

  # Roll back to previous layer.
  db.top = db.stack[^1]
  db.stack.setLen(db.stack.len-1)

  db.txRef = tx.parent
  ok()


proc commit*(
    tx: KvtTxRef;                     # Top transaction on database
      ): Result[void,KvtError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  let db = ? tx.getDbDescFromTopTx()

  # Keep top and discard layer below
  db.top.txUid = db.stack[^1].txUid
  db.stack.setLen(db.stack.len-1)

  db.txRef = tx.parent
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
  let db = ? tx.getDbDescFromTopTx()

  # If commit, then leave the current layer and clear the stack, oterwise
  # install the stack bottom.
  if not commit:
    db.stack[0].swap db.top

  db.top.txUid = 0
  db.stack.setLen(0)
  ok()

# ------------------------------------------------------------------------------
# Public functions: save database
# ------------------------------------------------------------------------------

proc stow*(
    db: KvtDbRef;                     # Database
      ): Result[void,KvtError] =
  ## The function saves the data from the top layer cache into the
  ## backend database.
  ##
  ## If there is no backend the function returns immediately with an error.
  ## The same happens if there is a pending transaction.
  ##
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)

  let be = db.backend
  if be.isNil:
    return err(TxBackendNotWritable)

  # Save structural and other table entries
  let txFrame = be.putBegFn()
  be.putKvpFn(txFrame, db.top.tab.pairs.toSeq)
  ? be.putEndFn txFrame

  # Delete or clear stack and clear top
  db.stack.setLen(0)
  db.top = LayerRef(txUid: db.top.txUid)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
