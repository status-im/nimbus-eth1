# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  std/tables,
  results,
  "."/[aristo_desc, aristo_filter, aristo_get, aristo_layers, aristo_hashify]

func isTop*(tx: AristoTxRef): bool
func level*(db: AristoDbRef): int

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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

  # Verify `tx` argument
  if db.txRef == tx:
    if db.top.txUid != tx.txUid:
      return err(TxArgStaleTx)
  elif db.stack.len <= tx.level:
    return err(TxArgStaleTx)
  elif db.stack[tx.level].txUid != tx.txUid:
    return err(TxArgStaleTx)

  # Provide new empty stack layer
  let stackLayer = block:
    let rc = db.getIdgBE()
    if rc.isOk:
      LayerRef(
        delta: LayerDeltaRef(),
        final: LayerFinalRef(vGen: rc.value))
    elif rc.error == GetIdgNotFound:
      LayerRef.init()
    else:
      return err(rc.error)

  # Set up clone associated to `db`
  let txClone = ? db.fork(noToplayer = true)
  txClone.top = db.layersCc tx.level      # Provide tx level 1 stack
  txClone.stack = @[stackLayer]           # Zero level stack
  txClone.roFilter = db.roFilter          # No need to copy (done when updated)
  txClone.backend = db.backend
  txClone.top.txUid = 1
  txClone.txUidGen = 1

  # Install transaction similar to `tx` on clone
  txClone.txRef = AristoTxRef(
    db:    txClone,
    txUid: 1,
    level: 1)

  if not dontHashify:
    txClone.hashify().isOkOr:
      discard txClone.forget()
      return err(error[1])

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
    let dbClone = ? db.fork(noToplayer = true)

    dbClone.top = db.layersCc      # Is a deep copy
    dbClone.roFilter = db.roFilter # No need to copy contents when updated
    dbClone.backend = db.backend

    if not dontHashify:
      dbClone.hashify().isOkOr:
        discard dbClone.forget()
        return err(error[1])
    return ok(dbClone)

  db.txRef.forkTx dontHashify

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
  if db.level != db.stack.len:
    return err(TxStackGarbled)

  db.stack.add db.top
  db.top = LayerRef(
    delta: LayerDeltaRef(),
    final: db.top.final.dup,
    txUid: db.getTxUid)

  db.txRef = AristoTxRef(
    db:     db,
    txUid:  db.top.txUid,
    parent: db.txRef,
    level:  db.stack.len)

  ok db.txRef


proc rollback*(
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


proc commit*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  let db = ? tx.getDbDescFromTopTx()
  db.hashify().isOkOr:
    return err(error[1])

  # Pop layer from stack and merge database top layer onto it
  let merged = block:
    if db.top.delta.sTab.len == 0 and
       db.top.delta.kMap.len == 0:
      # Avoid `layersMergeOnto()`
      db.top.delta = db.stack[^1].delta
      db.stack.setLen(db.stack.len-1)
      db.top
    else:
      let layer = db.stack[^1]
      db.stack.setLen(db.stack.len-1)
      db.top.layersMergeOnto layer[]
      layer

  # Install `merged` stack top layer and update stack
  db.top = merged
  db.txRef = tx.parent
  if 0 < db.stack.len:
    db.txRef.txUid = db.getTxUid
    db.top.txUid = db.txRef.txUid

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
  ##     if db.topTx.isErr: break
  ##     tx = db.topTx.value
  ##
  let db = ? tx.getDbDescFromTopTx()

  if commit:
    # For commit, hashify the current layer if requested and install it
    db.hashify().isOkOr:
      return err(error[1])

  db.top.txUid = 0
  db.stack.setLen(0)
  db.txRef = AristoTxRef(nil)
  ok()

# ------------------------------------------------------------------------------
# Public functions: save database
# ------------------------------------------------------------------------------

proc stow*(
    db: AristoDbRef;                  # Database
    persistent = false;               # Stage only unless `true`
    chunkedMpt = false;               # Partial data (e.g. from `snap`)
      ): Result[void,AristoError] =
  ## If there is no backend while the `persistent` argument is set `true`,
  ## the function returns immediately with an error. The same happens if there
  ## is a pending transaction.
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

  db.hashify().isOkOr:
    return err(error[1])

  let fwd = db.fwdFilter(db.top, chunkedMpt).valueOr:
    return err(error[1])

  if fwd.isValid:
    # Merge `top` layer into `roFilter`
    db.merge(fwd).isOkOr:
      return err(error[1])
    db.top = LayerRef(
      delta: LayerDeltaRef(),
      final: LayerFinalRef())
    if db.roFilter.isValid:
      db.top.final.vGen = db.roFilter.vGen
    else:
      let rc = db.getIdgUBE()
      if rc.isOk:
        db.top.final.vGen = rc.value
      else:
        # It is OK if there was no `Idg`. Otherwise something serious happened
        # and there is no way to recover easily.
        doAssert rc.error == GetIdgNotFound

  if persistent:
    ? db.resolveBackendFilter()
    db.roFilter = FilterRef(nil)

  # Delete/clear top
  db.top = LayerRef(
    delta: LayerDeltaRef(),
    final: LayerFinalRef(vGen: db.vGen),
    txUid: db.top.txUid)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
