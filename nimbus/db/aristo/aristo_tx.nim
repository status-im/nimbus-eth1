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
  std/options,
  results,
  ./aristo_tx/[tx_fork, tx_frame, tx_stow],
  "."/[aristo_desc, aristo_get]

# ------------------------------------------------------------------------------
# Public functions, getters
# ------------------------------------------------------------------------------

func txTop*(db: AristoDbRef): Result[AristoTxRef,AristoError] =
  ## Getter, returns top level transaction if there is any.
  db.txFrameTop()

func isTop*(tx: AristoTxRef): bool =
  ## Getter, returns `true` if the argument `tx` referes to the current top
  ## level transaction.
  tx.txFrameIsTop()

func level*(tx: AristoTxRef): int =
  ## Getter, positive nesting level of transaction argument `tx`
  tx.txFrameLevel()

func level*(db: AristoDbRef): int =
  ## Getter, non-negative nesting level (i.e. number of pending transactions)
  db.txFrameLevel()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

func to*(tx: AristoTxRef; T: type[AristoDbRef]): T =
  ## Getter, retrieves the parent database descriptor from argument `tx`
  tx.db


proc forkTx*(
    db: AristoDbRef;
    backLevel: int;                   # Backward location of transaction
    dontHashify = false;              # Process/fix MPT hashes
      ): Result[AristoDbRef,AristoError] =
  ## Fork a new descriptor obtained from parts of the argument database
  ## as described by arguments `db` and `backLevel`.
  ##
  ## If the argument `backLevel` is non-negative, the forked descriptor will
  ## provide the database view where the first `backLevel` transaction layers
  ## are stripped and the remaing layers are squashed into a single transaction.
  ##
  ## If `backLevel` is `-1`, a database descriptor with empty transaction
  ## layers will be provided where the `roFilter` between database and
  ## transaction layers are kept in place.
  ##
  ## If `backLevel` is `-2`, a database descriptor with empty transaction
  ## layers will be provided without an `roFilter`.
  ##
  ## The returned database descriptor will always have transaction level one.
  ## If there were no transactions that could be squashed, an empty
  ## transaction is added.
  ##
  ## If the arguent flag `dontHashify` is passed `true`, the forked descriptor
  ## will *NOT* be hashified right after construction.
  ##
  ## Use `aristo_desc.forget()` to clean up this descriptor.
  ##
  # Fork top layer (with or without pending transaction)?
  if backLevel == 0:
    return db.txForkTop dontHashify

  # Fork bottom layer (=> 0 < db.stack.len)
  if backLevel == db.stack.len:
    return db.txForkBase dontHashify

  # Inspect transaction stack
  if 0 < backLevel:
    var tx = db.txRef
    if tx.isNil or db.stack.len < backLevel:
      return err(TxLevelTooDeep)

    # Fetch tx of level `backLevel` (seed to skip some items)
    for _ in 0 ..< backLevel:
      tx = tx.parent
      if tx.isNil:
        return err(TxStackGarbled)
    return tx.txFork dontHashify

  # Plain fork, include `roFilter`
  if backLevel == -1:
    let xb = ? db.fork(noFilter=false)
    discard xb.txFrameBegin()
    return ok(xb)

  # Plain fork, unfiltered backend
  if backLevel == -2:
    let xb = ? db.fork(noFilter=true)
    discard xb.txFrameBegin()
    return ok(xb)

  err(TxLevelUseless)


proc findTx*(
    db: AristoDbRef;
    vid: VertexID;                    # Pivot vertex (typically `VertexID(1)`)
    key: HashKey;                     # Hash key of pivot vertex
      ): Result[int,AristoError] =
  ## Find the transaction where the vertex with ID `vid` exists and has the
  ## Merkle hash key `key`. If there is no transaction available, search in
  ## the filter and then in the backend.
  ##
  ## If the above procedure succeeds, an integer indicating the transaction
  ## level integer is returned:
  ##
  ## * `0` -- top level, current layer
  ## * `1`, `2`, ... -- some transaction level further down the stack
  ## * `-1` -- the filter between transaction stack and database backend
  ## * `-2` -- the databse backend
  ##
  ## A successful return code might be used for the `forkTx()` call for
  ## creating a forked descriptor that provides the pair `(vid,key)`.
  ##
  if not vid.isValid or
     not key.isValid:
    return err(TxArgsUseless)

  if db.txRef.isNil:
    # Try `(vid,key)` on top layer
    let topKey = db.top.delta.kMap.getOrVoid vid
    if topKey == key:
      return ok(0)

  else:
    # Find `(vid,key)` on transaction layers
    for (n,tx,layer,error) in db.txRef.txFrameWalk:
      if error != AristoError(0):
        return err(error)
      if layer.delta.kMap.getOrVoid(vid) == key:
        return ok(n)

    # Try bottom layer
    let botKey = db.stack[0].delta.kMap.getOrVoid vid
    if botKey == key:
      return ok(db.stack.len)

  # Try `(vid,key)` on roFilter
  if not db.roFilter.isNil:
    let roKey = db.roFilter.kMap.getOrVoid vid
    if roKey == key:
      return ok(-1)

  # Try `(vid,key)` on unfiltered backend
  block:
    let beKey = db.getKeyUbe(vid).valueOr: VOID_HASH_KEY
    if beKey == key:
      return ok(-2)

  err(TxNotFound)

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
  db.txFrameBegin()

proc rollback*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transactio. The previous transaction is returned if
  ## there was any.
  ##
  tx.txFrameRollback()

proc commit*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. The
  ## previous transaction is returned if there was any.
  ##
  tx.txFrameCommit()

proc collapse*(
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
  tx.txFrameCollapse commit

# ------------------------------------------------------------------------------
# Public functions: save to database
# ------------------------------------------------------------------------------

proc persist*(
    db: AristoDbRef;                  # Database
    nxtFid = none(FilterID);          # Next filter ID (zero is OK)
    chunkedMpt = false;               # Partial data (e.g. from `snap`)
      ): Result[void,AristoError] =
  ## Persistently store data onto backend database. If the system is running
  ## without a database backend, the function returns immediately with an
  ## error. The same happens if there is a pending transaction.
  ##
  ## The function merges all staged data from the top layer cache onto the
  ## backend stage area. After that, the top layer cache is cleared.
  ##
  ## Finally, the staged data are merged into the physical backend database
  ## and the staged data area is cleared. Wile performing this last step,
  ## the recovery journal is updated (if available.)
  ##
  ## If the argument `nxtFid` is passed non-zero, it will be the ID for the
  ## next recovery journal record. If non-zero, this ID must be greater than
  ## all previous IDs (e.g. block number when stowing after block execution.)
  ##
  ## Staging the top layer cache might fail with a partial MPT when it is
  ## set up from partial MPT chunks as it happens with `snap` sync processing.
  ## In this case, the `chunkedMpt` argument must be set `true` (see alse
  ## `fwdFilter()`.)
  ##
  db.txStow(nxtFid, persistent=true, chunkedMpt=chunkedMpt)

proc stow*(
    db: AristoDbRef;                  # Database
    chunkedMpt = false;               # Partial data (e.g. from `snap`)
      ): Result[void,AristoError] =
  ## This function is similar to `persist()` stopping short of performing the
  ## final step storing on the persistent database. It fails if there is a
  ## pending transaction.
  ##
  ## The function merges all staged data from the top layer cache onto the
  ## backend stage area and leaves it there. This function can be seen as
  ## a sort of a bottom level transaction `commit()`.
  ##
  ## Staging the top layer cache might fail with a partial MPT when it is
  ## set up from partial MPT chunks as it happens with `snap` sync processing.
  ## In this case, the `chunkedMpt` argument must be set `true` (see alse
  ## `fwdFilter()`.)
  ##
  db.txStow(nxtFid=none(FilterID), persistent=false, chunkedMpt=chunkedMpt)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
