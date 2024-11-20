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

func txLevel*(tx: AristoTxRef): int =
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
      ): Result[AristoDbRef,AristoError] =
  ## Fork a new descriptor obtained from parts of the argument database
  ## as described by arguments `db` and `backLevel`.
  ##
  ## If the argument `backLevel` is non-negative, the forked descriptor will
  ## provide the database view where the first `backLevel` transaction layers
  ## are stripped and the remaing layers are squashed into a single transaction.
  ##
  ## If `backLevel` is `-1`, a database descriptor with empty transaction
  ## layers will be provided where the `balancer` between database and
  ## transaction layers are kept in place.
  ##
  ## If `backLevel` is `-2`, a database descriptor with empty transaction
  ## layers will be provided without a `balancer`.
  ##
  ## The returned database descriptor will always have transaction level one.
  ## If there were no transactions that could be squashed, an empty
  ## transaction is added.
  ##
  ## Use `aristo_desc.forget()` to clean up this descriptor.
  ##
  # Fork top layer (with or without pending transaction)?
  if backLevel == 0:
    return db.txForkTop()

  # Fork bottom layer (=> 0 < db.stack.len)
  if backLevel == db.stack.len:
    return db.txForkBase()

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
    return tx.txFork()

  # Plain fork, include `balancer`
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
    rvid: RootedVertexID;             # Pivot vertex (typically `VertexID(1)`)
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
  if not rvid.isValid or
     not key.isValid:
    return err(TxArgsUseless)

  if db.txRef.isNil:
    # Try `(vid,key)` on top layer
    let topKey = db.top.kMap.getOrVoid rvid
    if topKey == key:
      return ok(0)

  else:
    # Find `(vid,key)` on transaction layers
    for (n,tx,layer,error) in db.txRef.txFrameWalk:
      if error != AristoError(0):
        return err(error)
      if layer.kMap.getOrVoid(rvid) == key:
        return ok(n)

    # Try bottom layer
    let botKey = db.stack[0].kMap.getOrVoid rvid
    if botKey == key:
      return ok(db.stack.len)

  # Try `(vid,key)` on balancer
  if not db.balancer.isNil:
    let roKey = db.balancer.kMap.getOrVoid rvid
    if roKey == key:
      return ok(-1)

  # Try `(vid,key)` on unfiltered backend
  block:
    let beKey = db.getKeyUbe(rvid, {}).valueOr: (VOID_HASH_KEY, nil)
    if beKey[0] == key:
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
    nxtSid = 0u64;                    # Next state ID (aka block number)
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
  ## If the argument `nxtSid` is passed non-zero, it will be the ID for the
  ## next recovery journal record. If non-zero, this ID must be greater than
  ## all previous IDs (e.g. block number when stowing after block execution.)
  ##
  db.txStow(nxtSid, persistent=true)

proc stow*(
    db: AristoDbRef;                  # Database
      ): Result[void,AristoError] =
  ## This function is similar to `persist()` stopping short of performing the
  ## final step storing on the persistent database. It fails if there is a
  ## pending transaction.
  ##
  ## The function merges all staged data from the top layer cache onto the
  ## backend stage area and leaves it there. This function can be seen as
  ## a sort of a bottom level transaction `commit()`.
  ##
  db.txStow(nxtSid=0u64, persistent=false)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
