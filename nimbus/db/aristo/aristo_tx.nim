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
  std/options,
  results,
  "."/[aristo_desc, aristo_filter, aristo_hashify]

func isTop*(tx: AristoTxRef): bool

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func getDbDescFromTopTx(tx: AristoTxRef): Result[AristoDbRef,AristoError] =
  if not tx.isTop():
    return err(TxNotTopTx)
  let db = tx.db
  if tx.level != db.stack.len:
    return err(TxStackUnderflow)
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

proc rebase*(
    tx: AristoTxRef;                  # Some transaction on database
      ): Result[void,AristoError] =
  ## Revert transaction stack to an earlier point in time.
  if not tx.isTop():
    let
      db = tx.db
      inx = tx.level
    if db.stack.len <= inx or db.stack[inx].txUid != tx.txUid:
      return err(TxArgStaleTx)
    # Roll back to some earlier layer.
    db.top = db.stack[inx]
    db.stack.setLen(inx)
  ok()

# ------------------------------------------------------------------------------
# Public functions: Transaction frame
# ------------------------------------------------------------------------------

proc txBegin*(db: AristoDbRef): Result[AristoTxRef,(VertexID,AristoError)] =
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
    return err((VertexID(0),TxStackGarbled))

  db.stack.add db.top.dup # push (save and use top later)
  db.top.txUid = db.getTxUid()

  db.txRef = AristoTxRef(
    db:     db,
    txUid:  db.top.txUid,
    parent: db.txRef,
    level:  db.stack.len)

  ok db.txRef


proc rollback*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,(VertexID,AristoError)] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  let db = block:
    let rc = tx.getDbDescFromTopTx()
    if rc.isErr:
      return err((VertexID(0),rc.error))
    rc.value

  # Roll back to previous layer.
  db.top = db.stack[^1]
  db.stack.setLen(db.stack.len-1)

  db.txRef = tx.parent
  ok()


proc commit*(
    tx: AristoTxRef;                  # Top transaction on database
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[void,(VertexID,AristoError)] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  ## Unless the argument `dontHashify` is set `true`, the function will process
  ## Merkle Patricia Treee hashes unless there was no change to this layer.
  ## This may produce additional errors (see `hashify()`.)
  let db = block:
    let rc = tx.getDbDescFromTopTx()
    if rc.isErr:
      return err((VertexID(0),rc.error))
    rc.value

  if db.top.dirty and not dontHashify:
    let rc = db.hashify()
    if rc.isErr:
      return err(rc.error)

  # Keep top and discard layer below
  db.top.txUid = db.stack[^1].txUid
  db.stack.setLen(db.stack.len-1)

  db.txRef = tx.parent
  ok()


proc collapse*(
    tx: AristoTxRef;                  # Top transaction on database
    commit: bool;                     # Commit if `true`, otherwise roll back
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[void,(VertexID,AristoError)] =
  ## Iterated application of `commit()` or `rollback()` performing the
  ## something similar to
  ## ::
  ##   while true:
  ##     discard tx.commit() # ditto for rollback()
  ##     if db.topTx.isErr: break
  ##     tx = db.topTx.value
  ##
  ## The `dontHashify` is treated as described for `commit()`
  let db = block:
    let rc = tx.getDbDescFromTopTx()
    if rc.isErr:
      return err((VertexID(0),rc.error))
    rc.value

  # If commit, then leave the current layer and clear the stack, oterwise
  # install the stack bottom.
  if not commit:
    db.stack[0].swap db.top

  if db.top.dirty and not dontHashify:
    let rc = db.hashify()
    if rc.isErr:
      if not commit:
        db.stack[0].swap db.top # restore
      return err(rc.error)

  db.top.txUid = 0
  db.stack.setLen(0)
  ok()

# ------------------------------------------------------------------------------
# Public functions: save database
# ------------------------------------------------------------------------------

proc stow*(
    db: AristoDbRef;                  # Database
    persistent = false;               # Stage only unless `true`
    dontHashify = false;              # Process/fix MPT hashes
    chunkedMpt = false;               # Partial data (e.g. from `snap`)
      ): Result[void,(VertexID,AristoError)] =
  ## If there is no backend while the `persistent` argument is set `true`,
  ## the function returns immediately with an error.The same happens if there
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
    return err((VertexID(0),TxPendingTx))
  if 0 < db.stack.len:
    return err((VertexID(0),TxStackGarbled))
  if persistent and not db.canResolveBE():
    return err((VertexID(0),TxRoBackendOrMissing))

  if db.top.dirty and not dontHashify:
    let rc = db.hashify()
    if rc.isErr:
      return err(rc.error)

  let fwd = block:
    let rc = db.fwdFilter(db.top, chunkedMpt)
    if rc.isErr:
      return err(rc.error)
    rc.value

  if fwd.vGen.isSome: # Otherwise this layer is pointless
    block:
      # Merge `top` layer into `roFilter`
      let rc = db.merge fwd
      if rc.isErr:
        return err(rc.error)
      db.top = AristoLayerRef(vGen: db.roFilter.vGen.unsafeGet)

  if persistent:
    let rc = db.resolveBE()
    if rc.isErr:
      return err(rc.error)
    db.roFilter = AristoFilterRef(nil)

  # Delete or clear stack and clear top
  db.stack.setLen(0)
  db.top = AristoLayerRef(vGen: db.top.vGen, txUid: db.top.txUid)

  ok()

proc stow*(
    db: AristoDbRef;                  # Database
    stageLimit: int;                  # Policy based persistent storage
    dontHashify = false;              # Process/fix MPT hashes
    chunkedMpt = false;               # Partial data (e.g. from `snap`)
      ): Result[void,(VertexID,AristoError)] =
  ## Variant of `stow()` with the `persistent` argument replaced by
  ## `stageLimit < max(db.roFilter.bulk, db.top.bulk)`.
  db.stow(
    persistent = (stageLimit < max(db.roFilter.bulk, db.top.bulk)),
    dontHashify = dontHashify,
    chunkedMpt = chunkedMpt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
