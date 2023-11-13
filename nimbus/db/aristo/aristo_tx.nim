# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
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
  std/[sequtils, tables],
  results,
  "."/[aristo_desc, aristo_filter, aristo_get, aristo_hashify]

type
  DoSpanPrepFn =
    proc(db: AristoDbRef; flg: bool): Result[void,AristoError] {.gcsafe.}

  DoSpanExecFn =
    proc(db: AristoDbRef) {.gcsafe.}

func isTop*(tx: AristoTxRef): bool
func level*(db: AristoDbRef): int

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func fromVae(err: (VertexID,AristoError)): AristoError =
  ## Map error pair to error reason component
  err[1]

func getDbDescFromTopTx(tx: AristoTxRef): Result[AristoDbRef,AristoError] =
  if not tx.isTop():
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
# Private functions: Single descriptor transaction frame
# ------------------------------------------------------------------------------

proc txBeginPrepImpl(db: AristoDbRef): Result[void,AristoError] =
  ## Starts a new transaction.
  ##
  if db.level != db.stack.len:
    return err(TxStackGarbled)
  ok()

proc txBeginExecImpl(db: AristoDbRef) =
  ## Starts a new transaction.
  ##
  db.stack.add db.top.dup # push (save and use top later)
  db.top.txUid = db.getTxUid()

  db.txRef = AristoTxRef(
    db:     db,
    txUid:  db.top.txUid,
    parent: db.txRef,
    level:  db.stack.len)

# ---------------

proc rollbackImpl(db: AristoDbRef) =
  ## Roll back to previous layer.
  ##
  db.top = db.stack[^1]
  db.stack.setLen(db.stack.len-1)
  db.txRef = db.txRef.parent          # `db.txRef` needs to be checked by caller

# ---------------

proc commitPrepImpl(
    db: AristoDbRef;                  # Top transaction on database
    dontHashify: bool;                # Process/fix MPT hashes
      ): Result[void,AristoError] =
  ## Commit transaction layer.
  ##
  if db.top.dirty and not dontHashify:
    discard ? db.hashify().mapErr fromVae
  ok()

proc commitExecImpl(db: AristoDbRef) =
  ## Commit transaction layer.
  ##
  # Keep top and discard layer below
  db.top.txUid = db.stack[^1].txUid
  db.stack.setLen(db.stack.len-1)
  db.txRef = db.txRef.parent          # `db.txRef` needs to be checked by caller

# ---------------

proc collapseCommitPrepImpl(
    db: AristoDbRef;
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[void,AristoError] =
  # For commit, hashify the current layer, otherwise the stack bottom layer.
  # install the stack bottom.
  if db.top.dirty and not dontHashify:
    discard ? db.hashify().mapErr fromVae
  ok()

proc collapseRollbackPrepImpl(
    db: AristoDbRef;
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[void,AristoError] =
  # Rollback hashify the current layer, otherwise the stack bottom layer.
  # install the stack bottom.
  if db.top.dirty and not dontHashify:
    db.stack[0].swap db.top
    defer: db.stack[0].swap db.top
    discard ? db.hashify().mapErr fromVae
  ok()


proc collapseCommitExecImpl(db: AristoDbRef) =
  # If commit, then leave the current layer and clear the stack, oterwise
  # install the stack bottom.
  db.top.txUid = 0
  db.stack.setLen(0)
  db.txRef = AristoTxRef(nil)

proc collapseRollbackExecImpl(db: AristoDbRef) =
  db.stack[0].swap db.top
  db.top.txUid = 0
  db.stack.setLen(0)
  db.txRef = AristoTxRef(nil)

# ---------------

proc doSpan(
    db: AristoDbRef;                  # Top transaction on database
    prepFn = DoSpanPrepFn(nil);       # Optional preparation layer
    prepFlag = false;                 # `prepFn` argument
    execFn: DoSpanExecFn;             # Mandatory execution layer
      ): Result[void,AristoError]
      {.gcsafe.} =
  ## Common execution framework for `rollbackImpl()` or `commitImpl()` over
  ## all descriptors in the transaction span.
  ##
  if not prepFn.isNil:
    var
      revert: Table[AristoDbRef,LayerRef]
    defer:
      # Restore previous layer
      for (dude,top) in revert.pairs:
        dude.top = top

    for dude in db.txSpan:
      if dude.stack.len == 0 or
         dude.stack.len != dude.txRef.level or
         dude.top.txUid != dude.txRef.txUid:
        return err(TxStackGarbled)
      let keep = db.top
      ? dude.prepFn prepFlag            # Preparation function
      revert[dude] = keep
    revert.clear                        # Done, no restoring

  for dude in db.txSpan:
    dude.execFn()                       # Commit function

  if db.level == 0:
    db.txSpanClear()

  ok()

proc doThisPrep(
    db: AristoDbRef;                  # Top transaction on database
    prepFn = DoSpanPrepFn(nil);       # Mandatory preparation layer function
    prepFlag = false;                 # `prepFn` argument
      ): Result[void,AristoError]
      {.gcsafe.} =
  ## ..
  let
    keep = db.top
    rc = db.prepFn prepFlag
  if rc.isErr:
    db.top = keep
    return err(rc.error)
  ok()

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func txTop*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
  ## Getter, returns top level transaction if there is any.
  if db.txRef.isNil:
    err(TxNoPendingTx)
  else:
    ok(db.txRef)

func isTop*(tx: AristoTxRef): bool =
  ## Getter, returns `true` if the argument `tx` referes to the current top
  ## level transaction.
  tx.db.txRef == tx and tx.db.top.txUid == tx.txUid

func level*(tx: AristoTxRef): int =
  ## Getter, positive nesting level of transaction argument `tx`
  tx.level

func level*(db: AristoDbRef): int =
  ## Getter, non-negative nesting level (i.e. number of pending transactions)
  if not db.txRef.isNil:
    result = db.txRef.level

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(tx: AristoTxRef; T: type[AristoDbRef]): T =
  ## Getter, retrieves the parent database descriptor from argument `tx`
  tx.db

proc forkTx*(
    tx: AristoTxRef;                  # Transaction descriptor
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[AristoDbRef,AristoError] =
  ## Clone a transaction into a new DB descriptor accessing the same backend
  ## database (if any) as the argument `db`. The new descriptor is linked to
  ## the transaction parent and is fully functional as a forked instance (see
  ## comments on `aristo_desc.reCentre()` for details.)
  ##
  ## Input situation:
  ## ::
  ##   tx -> db0   with tx is top transaction, tx.level > 0
  ##
  ## Output situation:
  ## ::
  ##   tx  -> db0 \
  ##               >  share the same backend
  ##   tx1 -> db1 /
  ##
  ## where `tx.level > 0`, `db1.level == 1` and `db1` is returned. The
  ## transaction `tx1` can be retrieved via `db1.txTop()`.
  ##
  ## The new DB descriptor will contain a copy of the argument transaction
  ## `tx` as top layer of level 1 (i.e. this is he only transaction.) Rolling
  ## back will end up at the backend layer (incl. backend filter.)
  ##
  ## If the arguent flag `dontHashify` is passed `true`, the clone descriptor
  ## will *NOT* be hashified right after construction.
  ##
  ## Use `aristo_desc.forget()` to clean up this descriptor.
  ##
  let db = tx.db

  # Provide new top layer
  var topLayer: LayerRef
  if db.txRef == tx:
    topLayer = db.top.dup
  elif tx.level < db.stack.len:
    topLayer = db.stack[tx.level].dup
  else:
    return err(TxArgStaleTx)
  if topLayer.txUid != tx.txUid:
    return err(TxArgStaleTx)
  topLayer.txUid = 1

  # Provide new empty stack layer
  let stackLayer = block:
    let rc = db.getIdgBE()
    if rc.isOk:
      LayerRef(vGen: rc.value)
    elif rc.error == GetIdgNotFound:
      LayerRef()
    else:
      return err(rc.error)

  let txClone = ? db.fork(rawToplayer = true)

  # Set up clone associated to `db`
  txClone.top = topLayer          # is a deep copy
  txClone.stack = @[stackLayer]
  txClone.roFilter = db.roFilter  # no need to copy contents (done when updated)
  txClone.backend = db.backend
  txClone.txUidGen = 1

  # Install transaction similar to `tx` on clone
  txClone.txRef = AristoTxRef(
    db:    txClone,
    txUid: 1,
    level: 1)

  if db.top.dirty and not dontHashify:
    let rc = txClone.hashify()
    if rc.isErr:
      discard txClone.forget()
      return err(rc.error.fromVae)

  ok(txClone)


proc forkTop*(
    db: AristoDbRef;
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[AristoDbRef,AristoError] =
  ## Variant of `forkTx()` for the top transaction if there is any. Otherwise
  ## the top layer is cloned, only.
  ##
  ## Use `aristo_desc.forget()` to clean up this descriptor.
  ##
  if db.txRef.isNil:
    let dbClone = ? db.fork(rawToplayer = true)

    dbClone.top = db.top.dup       # is a deep copy
    dbClone.roFilter = db.roFilter # no need to copy contents when updated
    dbClone.backend = db.backend

    if db.top.dirty and not dontHashify:
      let rc = dbClone.hashify()
      if rc.isErr:
        discard dbClone.forget()
        return err(rc.error.fromVae)
    return ok(dbClone)

  db.txRef.forkTx dontHashify


proc exec*(
    tx: AristoTxRef;
    action: AristoDbAction;
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[void,AristoError] =
  ## Execute function argument `action()` on a temporary `tx.forkTx()`
  ## transaction clone database. After return, the temporary database gets
  ## destroyed.
  ##
  ## If the arguent flag `dontHashify` is passed `true`, the clone database
  ## will *NOT* be hashified right after construction.
  ##
  let db = ? tx.forkTx dontHashify
  db.action()
  ? db.forget()
  ok()

# ------------------------------------------------------------------------------
# Public functions: Transaction frame
# ------------------------------------------------------------------------------

proc txBegin*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
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
  if not db.inTxSpan:
    ? db.txBeginPrepImpl()
    db.txBeginExecImpl()

  elif not db.isCentre:
    return err(TxSpanOffCentre)

  else:
    for dude in db.txSpan:
      ? dude.txBeginPrepImpl()   # Only check, no need to restore
    for dude in db.txSpan:
      dude.txBeginExecImpl()

  ok db.txRef

proc txBeginSpan*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
  ## Start a new transaction simultaneously on all descriptors accessing the
  ## same backend.
  ##
  ## This function must be run on the centre argument descriptor `db` (see
  ## comments on `aristo_desc.reCentre()` for details.) This function is
  ## effective only when there is no transaction opened, yet. Sub-transactions
  ## are handled by `txBegin()` accordingly.
  ##
  ## When starting sub-transactions outside a transaction span, these
  ## transactions are handled independently.
  ##
  ## Example:
  ## ::
  ##    let
  ##      tx = db.txBeginSpan    # includes all forked descriptors
  ##      ty = db.txBegin        # includes all forked descriptors
  ##
  ##      tmpDb = tx.forkTx      # outside transaction span
  ##      tz = tmpDb.txBegin     # outside transaction span
  ##
  if not db.isCentre:
    return err(TxSpanOffCentre)

  if 0 < db.nForked:
    if db.level == 0:
      if 0 < db.nTxSpan:
        return err(TxGarbledSpan)
      db.forked.toSeq.txSpanSet

  db.txBegin


proc rollback*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  let db = ? tx.getDbDescFromTopTx()
  if not db.inTxSpan:
    db.rollbackImpl()
    return ok()

  if not db.isCentre:
    return err(TxSpanOffCentre)

  db.doSpan(execFn = rollbackImpl)


proc commit*(
    tx: AristoTxRef;                  # Top transaction on database
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  ## Unless the argument `dontHashify` is set `true`, the function will process
  ## Merkle Patricia Treee hashes unless there was no change to this layer.
  ## This may produce additional errors (see `hashify()`.)
  ##
  let db = ? tx.getDbDescFromTopTx()
  if not db.inTxSpan:
    ? db.doThisPrep(commitPrepImpl, dontHashify)
    db.commitExecImpl()
    return ok()

  if not db.isCentre:
    return err(TxSpanOffCentre)

  db.doSpan(
    prepFn   = commitPrepImpl,
    prepFlag = dontHashify,
    execFn   = commitExecImpl)


proc collapse*(
    tx: AristoTxRef;                  # Top transaction on database
    commit: bool;                     # Commit if `true`, otherwise roll back
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[void,AristoError] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   while true:
  ##     discard tx.commit() # ditto for rollback()
  ##     if db.topTx.isErr: break
  ##     tx = db.topTx.value
  ##
  ## The `dontHashify` flag is treated as described for `commit()`
  ##
  let db = ? tx.getDbDescFromTopTx()
  if not db.inTxSpan:
    if commit:
      ? db.doThisPrep(collapseCommitPrepImpl, dontHashify)
      db.collapseCommitExecImpl()
    else:
      ? db.doThisPrep(collapseRollbackPrepImpl, dontHashify)
      db.collapseRollbackExecImpl()
    return ok()

  if not db.isCentre:
    return err(TxSpanOffCentre)

  if commit:
    db.doSpan(
      prepFn   = collapseCommitPrepImpl,
      prepFlag = dontHashify,
      execFn   = collapseCommitExecImpl)
  else:
    db.doSpan(
      prepFn   = collapseRollbackPrepImpl,
      prepFlag = dontHashify,
      execFn   = collapseRollbackExecImpl)

# ------------------------------------------------------------------------------
# Public functions: save database
# ------------------------------------------------------------------------------

proc stow*(
    db: AristoDbRef;                  # Database
    persistent = false;               # Stage only unless `true`
    dontHashify = false;              # Process/fix MPT hashes
    chunkedMpt = false;               # Partial data (e.g. from `snap`)
      ): Result[void,AristoError] =
  ## If there is no backend while the `persistent` argument is set `true`,
  ## the function returns immediately with an error. The same happens if there
  ## is a pending transaction.
  ##
  ## The `dontHashify` is treated as described for `commit()`.
  ##
  ## The function then merges the data from the top layer cache into the
  ## backend stage area. After that, the top layer cache is cleared.
  ##
  ## Staging the top layer cache might fail withh a partial MPT when it is
  ## set up from partial MPT chunks as it happens with `snap` sync processing.
  ## In this case, the `chunkedMpt` argument must be set `true` (see alse
  ## `fwdFilter`.)
  ##
  ## If the argument `persistent` is set `true`, all the staged data are merged
  ## into the physical backend database and the staged data area is cleared.
  ##
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)
  if persistent and not db.canResolveBackendFilter():
    return err(TxBackendNotWritable)

  if db.top.dirty and not dontHashify:
    discard ? db.hashify().mapErr fromVae

  let fwd = ? db.fwdFilter(db.top, chunkedMpt).mapErr fromVae

  if fwd.isValid:
    # Merge `top` layer into `roFilter`
    ? db.merge(fwd).mapErr fromVae
    db.top = LayerRef(vGen: db.roFilter.vGen)

  if persistent:
    ? db.resolveBackendFilter()
    db.roFilter = FilterRef(nil)

  # Delete or clear stack and clear top
  db.stack.setLen(0)
  db.top = LayerRef(vGen: db.top.vGen, txUid: db.top.txUid)

  ok()

proc stow*(
    db: AristoDbRef;                  # Database
    stageLimit: int;                  # Policy based persistent storage
    dontHashify = false;              # Process/fix MPT hashes
    chunkedMpt = false;               # Partial data (e.g. from `snap`)
      ): Result[void,AristoError] =
  ## Variant of `stow()` with the `persistent` argument replaced by
  ## `stageLimit < max(db.roFilter.bulk, db.top.bulk)`.
  db.stow(
    persistent = (stageLimit < max(db.roFilter.bulk, db.top.bulk)),
    dontHashify = dontHashify,
    chunkedMpt = chunkedMpt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
