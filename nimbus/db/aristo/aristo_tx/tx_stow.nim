# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction stow/save helper
## =========================================
##
{.push raises: [].}

import
  std/tables,
  results,
  ../aristo_delta/delta_merge,
  ".."/[aristo_desc, aristo_get, aristo_delta, aristo_layers]

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getBeStateRoot(
    db: AristoDbRef;
      ): Result[HashKey,AristoError] =
  ## Get the Merkle hash key for the current backend state root and check
  ## validity of top layer.
  const rvid = (VertexID(1), VertexID(1))
  let srcRoot = block:
    let rc = db.getKeyBE rvid
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err(rc.error)

  if db.top.delta.kMap.getOrVoid(rvid).isValid:
    return ok(srcRoot)

  elif not db.top.delta.kMap.hasKey(rvid) and
       not db.top.delta.sTab.hasKey(rvid):
    # This layer is unusable, need both: vertex and key
    return err(TxPrettyPointlessLayer)

  ok(srcRoot)

  #elif not db.top.delta.sTab.getOrVoid(VertexID 1).isValid:
  #  # Root key and vertex have been deleted
  #  return ok(srcRoot)
  #
  #elif chunkedMpt and srcRoot == db.top.delta.kMap.getOrVoid VertexID(1):
  #  # FIXME: this one needs to be double checked with `snap` sunc preload
  #  return ok(srcRoot)
  #
  #err(TxStateRootMismatch)


proc topMerge(db: AristoDbRef; src: HashKey): Result[void,AristoError] =
  ## Merge the `top` layer into the read-only balacer layer.
  let ubeRoot = block:
    const rvid = (VertexID(1), VertexID(1))
    let rc = db.getKeyUbe rvid
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err(rc.error)

  # This one will return the `db.top.delta` if `db.balancer.isNil`
  db.balancer = db.deltaMerge(db.top.delta, db.balancer, ubeRoot).valueOr:
    return err(error[1])

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txStow*(
    db: AristoDbRef;                  # Database
    nxtSid: uint64;                   # Next state ID (aka block number)
    persistent: bool;                 # Stage only unless `true`
      ): Result[void,AristoError] =
  ## Worker for `stow()` and `persist()` variants.
  ##
  if not db.txRef.isNil:
    return err(TxPendingTx)
  if 0 < db.stack.len:
    return err(TxStackGarbled)
  if persistent and not db.deltaPersistentOk():
    return err(TxBackendNotWritable)

  # Verify database consistency and get `src` field for update
  let rc = db.getBeStateRoot()
  if rc.isErr and rc.error != TxPrettyPointlessLayer:
    return err(rc.error)

  # Move/merge/install `top` layer onto `balancer`
  if rc.isOk:
    db.topMerge(rc.value).isOkOr:
      return err(error)

    # New empty top layer (probably with `snap` proofs and `vTop` carry over)
    db.top = LayerRef(
      delta: LayerDeltaRef())
    if db.balancer.isValid:
      db.top.delta.vTop = db.balancer.vTop
    else:
      let rc = db.getTuvUbe()
      if rc.isOk:
        db.top.delta.vTop = rc.value
      else:
        # It is OK if there was no `vTop`. Otherwise something serious happened
        # and there is no way to recover easily.
        doAssert rc.error == GetTuvNotFound

  elif db.top.delta.sTab.len != 0 and
       not db.top.delta.sTab.getOrVoid((VertexID(1), VertexID(1))).isValid:
    # Currently, a `VertexID(1)` root node is required
    return err(TxAccRootMissing)

  if persistent:
    # Merge/move `balancer` into persistent tables
    ? db.deltaPersistent nxtSid

  # New empty top layer (probably with `snap` proofs carry over)
  db.top = LayerRef(
    delta: LayerDeltaRef(vTop: db.vTop),
    txUid: db.top.txUid)
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
