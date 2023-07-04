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
  std/[sets, tables],
  chronicles,
  eth/common,
  stew/results,
  "."/[aristo_delete, aristo_desc, aristo_get, aristo_hashify,
       aristo_hike, aristo_init, aristo_layer, aristo_merge, aristo_nearby]

logScope:
  topics = "aristo-tx"

type
  AristoTxRef* = ref object
    ## This descriptor replaces the `AristoDbRef` one for transaction based
    ## database operations and management.
    parent: AristoTxRef                  ## Parent transaction (if any)
    db: AristoDbRef                      ## Database access

# ------------------------------------------------------------------------------
# Public functions: Constructor/destructor
# ------------------------------------------------------------------------------

proc to*(
    db: AristoDbRef;                     # `init()` result
    T: type AristoTxRef;                 # Type discriminator
      ): T =
  ## Embed the database descritor `db` into the transaction based one. After
  ## this operation, the argument descriptor should not be used anymore.
  ##
  ## The function will return a new transaction descriptor unless the stack of
  ## the argument `db` is already filled (e.g. using `push()` on the `db`.)
  if db.stack.len == 0:
    return AristoTxRef(db: db)

proc to*(
    rc: Result[AristoDbRef,AristoError]; # `init()` result
    T: type AristoTxRef;                 # Type discriminator
      ): Result[T, AristoError] =
  ## Variant of `to()` which passes on any constructor errors.
  ##
  ## Example:
  ## ::
  ##   let rc = AristoDbRef.init(BackendRocksDB,"/var/tmp/rdb").to(AristoTxRef)
  ##   ...
  ##   let tdb = rc.value
  ##   ...
  ##
  if rc.isErr:
    return err(rc.error)
  let tdb = rc.value.to(AristoTxRef)
  if tdb.isNil:
    return err(TxDbStackNonEmpty)
  ok tdb

proc done*(
    tdb: AristoTxRef;                    # Database, transaction wrapper
    flush = false;                       # Delete persistent data (if supported)
      ): Result[void,AristoError]
      {.discardable.} =
  ## Database and transaction handle destructor. The `flush` argument is passed
  ## on to the database backend destructor. When used in the `BackendRocksDB`
  ## database, a `true` value for `flush` will wipe the entire database from
  ## the hard disc.
  ##
  ## Note that the function argument `tdb` must not have any pending open
  ## transaction layers, i.e. `tdb.isBase()` must return `true`.
  if not tdb.parent.isNil or tdb.db.isNil:
    return err(TxBaseHandleExpected)
  tdb.db.finish flush
  ok()

# ------------------------------------------------------------------------------
# Public functions: Classifiers
# ------------------------------------------------------------------------------

proc isBase*(tdb: AristoTxRef): bool =
  ## The function returns `true` if the argument handle `tdb` is the one that
  ## was returned from the `to()` constructor. A handle where this function
  ## returns `true` is called a *base level* handle.
  ##
  ## A *base level* handle may be a valid argument for the `begin()` function
  ## but not for either `commit()` ot `rollback()`.
  tdb.parent.isNil and not tdb.db.isNil

proc isTop*(tdb: AristoTxRef): bool =
  ## If the function returns `true` for the argument handle `tdb`, then this
  ## handle  can be used on any of the following functions.
  not tdb.parent.isNil and not tdb.db.isNil

# ------------------------------------------------------------------------------
# Public functions: Transaction frame
# ------------------------------------------------------------------------------

proc begin*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
      ): Result[AristoTxRef,(VertexID,AristoError)] =
  ## Starts a new transaction. If successful, the function will return a new
  ## handle (or descriptor) which replaces the argument handle `tdb`. This
  ## argument handle `tdb` is rendered invalid for as long as the new
  ## transaction handle is valid. While valid, this new handle is called a
  ## *top level* handle.
  ##
  ## If the argument `tdb` is a *base level*  or a *top level* handle, this
  ## function succeeds. Otherwise it will return the error
  ## `TxValidHandleExpected`.
  ##
  ## Example:
  ## ::
  ##   proc doSomething(tdb: AristoTxRef) =
  ##     let tx = tdb.begin.value   # will crash on failure
  ##     defer: tx.rollback()
  ##     ...
  ##     tx.commit()
  ##
  if tdb.db.isNil:
    return err((VertexID(0),TxValidHandleExpected))

  tdb.db.push()

  let pTx = AristoTxRef(parent: tdb, db: tdb.db)
  tdb.db = AristoDbRef(nil)
  ok pTx


proc rollback*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
      ): Result[AristoTxRef,(VertexID,AristoError)]
      {.discardable.} =
  ## Given a *top level* handle, this function discards all database operations
  ## performed through this handle and returns the previous one which becomes
  ## either the *top level* or the *base level* handle, again.
  ##
  if tdb.db.isNil or tdb.parent.isNil:
    return err((VertexID(0),TxTopHandleExpected))

  block:
    let rc = tdb.db.pop(merge = false)
    if rc.isErr:
      return err(rc.error)

  let pTx = tdb.parent
  pTx.db = tdb.db

  tdb.parent = AristoTxRef(nil)
  tdb.db = AristoDbRef(nil)
  ok pTx


proc commit*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
    hashify = false;                   # Always calc Merkle hashes if `true`
      ): Result[AristoTxRef,(VertexID,AristoError)]
      {.discardable.} =
  ## Given a *top level* handle, this function accepts all database operations
  ## performed through this handle and merges it to the previous layer. It
  ## returns this previous layer which becomes either the *top level* or the
  ## *base level* handle, again.
  ##
  ## If the function return value is a *base level* handle, all the accumulated
  ## prevoius database operations will have been hashified and successfully
  ## stored on the persistent database.
  ##
  ## If the argument `hashify` is set `true`, the function will always hashify
  ## (i.e. calculate Merkle hashes) regardless of whether it is stored on the
  ## backend.
  ##
  if tdb.db.isNil or tdb.parent.isNil:
    return err((VertexID(0),TxTopHandleExpected))

  block:
    let rc = tdb.db.pop(merge = true)
    if rc.isErr:
      return err(rc.error)

  let pTx = tdb.parent
  pTx.db = tdb.db

  # Hashify and save (if any)
  if hashify or pTx.parent.isNil:
    let rc = tdb.db.hashify()
    if rc.isErr:
      return err(rc.error)
  if pTx.parent.isNil:
    let rc = tdb.db.save()
    if rc.isErr:
      return err(rc.error)

  tdb.db = AristoDbRef(nil)
  tdb.parent = AristoTxRef(nil)
  ok pTx


proc collapse*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
    commit: bool;                      # Commit is `true`, otherwise roll back
      ): Result[AristoTxRef,(VertexID,AristoError)] =
  ## Variation of `commit()` or `rollback()` performing the equivalent of
  ## ::
  ##   while tx.isTop:
  ##     let rc =
  ##       if commit: tx.commit()
  ##       else: tx.rollback()
  ##     ...
  ##     tx = rc.value
  ##
  if tdb.db.isNil or tdb.parent.isNil:
    return err((VertexID(0),TxTopHandleExpected))

  # Get base layer
  var pTx = tdb.parent
  while not pTx.parent.isNil:
    pTx = pTx.parent
  pTx.db = tdb.db

  # Hashify and save, or complete rollback
  if commit:
    block:
      let rc = tdb.db.hashify()
      if rc.isErr:
        return err(rc.error)
    block:
      let rc = tdb.db.save()
      if rc.isErr:
        return err(rc.error)
  else:
    let rc = tdb.db.retool(flushStack = true)
    if rc.isErr:
      return err((VertexID(0),rc.error))

  tdb.db = AristoDbRef(nil)
  tdb.parent = AristoTxRef(nil)
  ok pTx

# ------------------------------------------------------------------------------
# Public functions: DB manipulations
# ------------------------------------------------------------------------------

proc put*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
    leaf: LeafTiePayload;              # Leaf item to add to the database
      ): Result[bool,AristoError] =
  ## Add leaf entry to transaction layer.
  if tdb.db.isNil or tdb.parent.isNil:
    return err(TxTopHandleExpected)

  let report = tdb.db.merge @[leaf]
  if report.error != AristoError(0):
    return err(report.error)

  ok(0 < report.merged)


proc del*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
    leaf: LeafTie;                     # `Patricia Trie` path root-to-leaf
      ): Result[void,(VertexID,AristoError)] =
  ## Delete leaf entry from transaction layer.
  if tdb.db.isNil or tdb.parent.isNil:
    return err((VertexID(0),TxTopHandleExpected))

  tdb.db.delete leaf


proc get*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
    leaf: LeafTie;                     # `Patricia Trie` path root-to-leaf
      ): Result[PayloadRef,(VertexID,AristoError)] =
  ## Get leaf entry from database filtered through the transaction layer.
  if tdb.db.isNil or tdb.parent.isNil:
    return err((VertexID(0),TxTopHandleExpected))

  let hike = leaf.hikeUp tdb.db
  if hike.error != AristoError(0):
    let vid = if hike.legs.len == 0: VertexID(0) else: hike.legs[^1].wp.vid
    return err((vid,hike.error))

  ok hike.legs[^1].wp.vtx.lData


proc key*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
    vid: VertexID;
      ): Result[HashKey,(VertexID,AristoError)] =
  ## Get the Merkle hash key for the argument vertex ID `vid`. This function
  ## hashifies (i.e. calculates Merkle hashe keys) unless available on the
  ## requested vertex ID.
  ##
  if tdb.db.isNil or tdb.parent.isNil:
    return err((VertexID(0),TxTopHandleExpected))

  if tdb.db.top.kMap.hasKey vid:
    block:
      let key = tdb.db.top.kMap.getOrVoid(vid).key
      if key.isValid:
        return ok(key)
    let rc = tdb.db.hashify()
    if rc.isErr:
      return err(rc.error)
    block:
      let key = tdb.db.top.kMap.getOrVoid(vid).key
      if key.isValid:
        return ok(key)
    return err((vid,TxCacheKeyFetchFail))

  block:
    let rc = tdb.db.getKeyBackend vid
    if rc.isOk:
      return ok(rc.value)

  return err((vid,TxBeKeyFetchFail))

proc rootKey*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
      ): Result[HashKey,(VertexID,AristoError)] =
  ## Get the Merkle hash key for the main state root (with vertex ID `1`.)
  tdb.key VertexID(1)


proc changeLog*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
    clear = false;                     # Delete history
      ): seq[AristoChangeLogRef] =
  ## Get the save history, i.e. the changed states before the database was
  ## updated on disc. If the argument `chear` is set `true`, the history log
  ## on the descriptor is cleared.
  ##
  ## The argument `tdb` must be a *top level* descriptor, i.e. `tdb.isTop()`
  ## returns `true`. Otherwise the function `changeLog()` always returns an
  ## empty list.
  ##
  if tdb.db.isNil or tdb.parent.isNil:
    return
  result = tdb.db.history
  if clear:
    tdb.db.history.setlen(0)

# ------------------------------------------------------------------------------
# Public functions: DB traversal
# ------------------------------------------------------------------------------

proc right*(
    lty: LeafTie;                       # Some `Patricia Trie` path
    tdb: AristoTxRef;                  # Database, transaction wrapper
      ): Result[LeafTie,(VertexID,AristoError)] =
  ## Finds the next leaf to the right (if any.) For details see
  ## `aristo_nearby.right()`.
  if tdb.db.isNil or tdb.parent.isNil:
    return err((VertexID(0),TxTopHandleExpected))
  lty.right tdb.db

proc left*(
    lty: LeafTie;                       # Some `Patricia Trie` path
    tdb: AristoTxRef;                  # Database, transaction wrapper
      ): Result[LeafTie,(VertexID,AristoError)] =
  ## Finds the next leaf to the left (if any.) For details see
  ## `aristo_nearby.left()`.
  if tdb.db.isNil or tdb.parent.isNil:
    return err((VertexID(0),TxTopHandleExpected))
  lty.left tdb.db

# ------------------------------------------------------------------------------
# Public helpers, miscellaneous
# ------------------------------------------------------------------------------

proc level*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
      ): (int,int) =
  ## This function returns the nesting level of the transaction and the length
  ## of the internal stack. Both values must be equal (otherwise there would
  ## be an internal error.)
  ##
  ## The argument `tdb` must be a *top level* or *base level* descriptor, i.e.
  ## `tdb.isTop() or tdb.isBase()` evaluate `true`. Otherwise `(-1,-1)` is
  ## returned.
  ##
  if tdb.db.isNil:
    return (-1,-1)

  if tdb.parent.isNil:
    return (0, tdb.db.stack.len)

  # Count base layer
  var
    count = 1
    pTx = tdb.parent
  while not pTx.parent.isNil:
    count.inc
    pTx = pTx.parent

  (count, tdb.db.stack.len)

proc db*(
    tdb: AristoTxRef;                  # Database, transaction wrapper
      ): AristoDbRef =
  ## Getter, provides access to the Aristo database cache and backend.
  ##
  ## The getter directive returns a valid object reference if the argument
  ## `tdb` is a *top level* or *base level* descriptor, i.e.
  ## `tdb.isTop() or tdb.isBase()` evaluate `true`.
  ##
  tdb.db

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
