# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction interface
## ==================================
##
{.push raises: [].}

import
  std/[options, sequtils, tables],
  results,
  "."/[aristo_desc, aristo_filter]

type
  AristoTxAction* = proc() {.gcsafe, raises: [CatchableError].}

const
  TxUidLocked = high(uint) div 2
    ## The range of valid transactions of is roughly `high(int)`. For
    ## normal transactions, the lower range is applied while for restricted
    ## transactions used with `execute()` below, the higher range is used.

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc backup(db: AristoDbRef): AristoDbRef =
  AristoDbRef(
    top:      db.top,      # ref
    stack:    db.stack,    # sequence of refs
    txRef:    db.txRef,    # ref
    txUidGen: db.txUidGen) # number

proc restore(db: AristoDbRef, backup: AristoDbRef) =
  db.top =      backup.top
  db.stack =    backup.stack
  db.txRef =    backup.txRef
  db.txUidGen = backup.txUidGen

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getTxUid(db: AristoDbRef): uint =
  if db.txUidGen < TxUidLocked:
    if db.txUidGen == TxUidLocked - 1:
      db.txUidGen = 0
  else:
    if db.txUidGen == high(uint):
      db.txUidGen = TxUidLocked
  db.txUidGen.inc
  db.txUidGen

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

proc txTop*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
  ## Getter, returns top level transaction if there is any.
  if db.txRef.isNil:
    err(TxNoPendingTx)
  else:
    ok(db.txRef)

proc isTop*(tx: AristoTxRef): bool =
  ## Getter, returns `true` if the argument `tx` referes to the current top
  ## level transaction.
  tx.db.txRef == tx and tx.db.top.txUid == tx.txUid

proc level*(tx: AristoTxRef): int =
  ## Getter, non-negaitve transaction nesting level
  var tx = tx
  while tx.parent != AristoTxRef(nil):
    tx = tx.parent
    result.inc

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc to*(tx: AristoTxRef; T: type[AristoDbRef]): T =
  ## Getter, retrieves the parent database descriptor
  tx.db

proc rebase*(tx: AristoTxRef): Result[void,AristoError] =
  ## Revert transaction stack to an earlier point in time.
  if not tx.isTop():
    let
      db = tx.db
      inx = tx.stackInx
    if db.stack.len <= inx or db.stack[inx].txUid != tx.txUid:
      return err(TxArgStaleTx)
    # Roll back to some earlier layer.
    db.top = db.stack[inx]
    db.stack.setLen(inx)
  ok()

proc exec*(
    tx: AristoTxRef;
    action: AristoTxAction;
      ): Result[void,AristoError]
      {.gcsafe, raises: [CatchableError].} =
  ## Execute function argument `action()` on a transaction `tx` which might
  ## refer to an earlier one. There are some restrictions on the database
  ## `tx` referres to which might have been captured by the `action` closure.
  ##
  ## Restrictions:
  ## * For the argument transaction `tx`, the expressions `tx.commit()` or
  ##   `tx.rollack()` will throw an `AssertDefect` error.
  ## * The `ececute()` call must not be nested. Doing otherwise will throw an
  ##   `AssertDefect` error.
  ## * Changes on the database referred to by `tx` can be staged but not saved
  ##   persistently with the `stow()` directive.
  ##
  ## After return, the state of the underlying database will not have changed.
  ## Any transactions left open by the `action()` call will have been discarded.
  ##
  ## So these restrictions amount to sort of a temporary *read-only* mode for
  ## the underlying database.
  ##
  if TxUidLocked <= tx.txUid:
    return err(TxExecNestingAttempt)

  # Move current DB to a backup copy
  let
    db = tx.db
    saved = db.backup

  # Install transaction layer
  if not tx.isTop():
    if db.stack.len <= tx.stackInx:
      return err(TxArgStaleTx)
    db.top[] = db.stack[tx.stackInx][] # deep copy

  db.top.txUid = TxUidLocked
  db.stack = @[AristoLayerRef()]
  db.txUidGen = TxUidLocked
  db.txRef = AristoTxRef(db: db, txUid: TxUidLocked, stackInx: 1)

  # execute action
  action()

  # restore
  db.restore saved
  ok()

# ------------------------------------------------------------------------------
# Public functions: Transaction frame
# ------------------------------------------------------------------------------

proc txBegin*(db: AristoDbRef): AristoTxRef =
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
  db.stack.add db.top.dup # push (save and use top later)
  db.top.txUid = db.getTxUid()

  db.txRef = AristoTxRef(
    db:       db,
    txUid:    db.top.txUid,
    parent:   db.txRef,
    stackInx: db.stack.len)
  db.txRef


proc rollback*(tx: AristoTxRef): Result[void,AristoError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  ## This function will throw a `AssertionDefect` exception unless `tx` is the
  ## top level transaction descriptor and the layer stack was not maipulated
  ## externally.
  if not tx.isTop():
    return err(TxNotTopTx)
  if tx.txUid == TxUidLocked:
    return err(TxExecBaseTxLocked)

  let db = tx.db
  if db.stack.len == 0:
    return err(TxStackUnderflow)

  # Roll back to previous layer.
  db.top = db.stack[^1]
  db.stack.setLen(db.stack.len-1)

  db.txRef = tx.parent
  ok()

proc commit*(tx: AristoTxRef): Result[void,AristoError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  ## This function will throw a `AssertionDefect` exception unless `tx` is the
  ## top level transaction descriptor and the layer stack was not maipulated
  ## externally.
  if not tx.isTop():
    return err(TxNotTopTx)
  if tx.txUid == TxUidLocked:
    return err(TxExecBaseTxLocked)

  let db = tx.db
  if db.stack.len == 0:
    return err(TxStackUnderflow)

  # Keep top and discard layer below
  db.top.txUid = db.stack[^1].txUid
  db.stack.setLen(db.stack.len-1)

  db.txRef = tx.parent
  ok()


proc collapse*(
    tx: AristoTxRef;                  # Database, transaction wrapper
    commit: bool;                     # Commit is `true`, otherwise roll back
      ): Result[void,AristoError] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   if tx.isTop():
  ##     while true:
  ##       discard tx.commit() # ditto for rollback()
  ##       if db.topTx.isErr: break
  ##       tx = db.topTx.value
  ##
  if not tx.isTop():
    return err(TxNotTopTx)
  if tx.txUid == TxUidLocked:
    return err(TxExecBaseTxLocked)

  # Get the first transaction
  var txBase = tx
  while txBase.parent != AristoTxRef(nil):
    txBase = txBase.parent

  let
    db = tx.db
    inx = txBase.stackInx-1

  if commit:
    # If commit, then leave the current layer and clear the stack
    db.top.txUid = 0
  else:
    # Otherwise revert to previous layer from stack
    db.top = db.stack[inx]

  db.stack.setLen(inx)
  ok()

# ------------------------------------------------------------------------------
# Public functions: save database
# ------------------------------------------------------------------------------

proc stow*(
    db: AristoDbRef;
    stageOnly = true;
    extendOK = false;
      ): Result[void,AristoError] =
  ## If there is no backend while the `stageOnly` is set `true`, the function
  ## returns immediately with an error.The same happens if the backend is
  ## locked due to an `exec()` call while `stageOnly` is set.
  ##
  ## Otherwise, the data changes from the top layer cache are merged into the
  ## backend stage area. After that, the top layer cache is cleared.
  ##
  ## If the argument `stageOnly` is set `true`, all the staged data are merged
  ## into the backend database. The staged data area is cleared.
  ##
  if not db.txRef.isNil and
     TxUidLocked <= db.txRef.txUid and
     not stageOnly:
    return err(TxExecDirectiveLocked)

  let be = db.backend
  if be.isNil and not stageOnly:
    return err(TxBackendMissing)

  let fwd = block:
    let rc = db.fwdFilter(db.top, extendOK)
    if rc.isErr:
      return err(rc.error[1])
    rc.value

  if fwd.vGen.isSome: # Otherwise this layer is pointless
    block:
      let rc = db.merge fwd
      if rc.isErr:
        return err(rc.error[1])
      rc.value

    if not stageOnly:
      # Save structural and other table entries
      let txFrame = be.putBegFn()
      be.putVtxFn(txFrame, db.roFilter.sTab.pairs.toSeq)
      be.putKeyFn(txFrame, db.roFilter.kMap.pairs.toSeq)
      be.putIdgFn(txFrame, db.roFilter.vGen.unsafeGet)
      let w = be.putEndFn txFrame
      if w != AristoError(0):
        return err(w)

      db.roFilter = AristoFilterRef(nil)

  # Delete or clear stack and clear top
  db.stack.setLen(0)
  db.top = AristoLayerRef(vGen: db.top.vGen, txUid: db.top.txUid)

  ok()

proc stow*(
    db: AristoDbRef;
    stageLimit: int;
    extendOK = false;
      ): Result[void,AristoError] =
  ## Variant of `stow()` with the `stageOnly` argument replaced by
  ## `stageLimit <= max(db.roFilter.bulk, db.top.bulk)`.
  let w = max(db.roFilter.bulk, db.top.bulk)
  db.stow(stageOnly=(stageLimit <= w), extendOK=extendOK)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
