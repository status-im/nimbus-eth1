# nimbus-eth1
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie filter management
## =============================================
##

import
  std/[options, sequtils, sets, tables],
  results,
  ./aristo_desc/aristo_types_backend,
  "."/[aristo_desc, aristo_get, aristo_vid]

type
  StateRootPair = object
    be: HashKey
    fg: HashKey

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc getLayerStateRoots(
    db: AristoDbRef;
    layer: AristoLayerRef;
    chunkedMpt: bool;
      ): Result[StateRootPair,AristoError] =
  ## Get the Merkle hash key for target state root to arrive at after this
  ## reverse filter was applied.
  var spr: StateRootPair

  spr.be = block:
    let rc = db.getKeyBE VertexID(1)
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err(rc.error)

  block:
    spr.fg = layer.kMap.getOrVoid(VertexID 1).key
    if spr.fg.isValid:
      return ok(spr)

  if chunkedMpt:
    let vid = layer.pAmk.getOrVoid HashLabel(root: VertexID(1), key: spr.be)
    if vid == VertexID(1):
      spr.fg = spr.be
      return ok(spr)

  if layer.sTab.len == 0 and
     layer.kMap.len == 0 and
     layer.pAmk.len == 0:
    return err(FilPrettyPointlessLayer)

  err(FilStateRootMismatch)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc merge(
    db: AristoDbRef;
    upper: AristoFilterRef;                    # Src filter, `nil` is ok
    lower: AristoFilterRef;                    # Trg filter, `nil` is ok
    beStateRoot: HashKey;                      # Merkle hash key
      ): Result[AristoFilterRef,(VertexID,AristoError)] =
  ## Merge argument `upper` into the `lower` filter instance.
  ##
  ## Comparing before and after merge
  ## ::
  ##   current                     | merged
  ##   ----------------------------+--------------------------------
  ##   trg2 --upper-- (src2==trg1) |
  ##                               | trg2 --newFilter-- (src1==trg0)
  ##   trg1 --lower-- (src1==trg0) |
  ##                               |
  ##   trg0 --beStateRoot          | trg0 --beStateRoot
  ##                               |
  ##
  # Degenerate case: `upper` is void
  if lower.isNil or lower.vGen.isNone:
    if upper.isNil or upper.vGen.isNone:
      # Even more degenerate case when both filters are void
      return ok AristoFilterRef(
        src: beStateRoot,
        trg: beStateRoot,
        vGen: none(seq[VertexID]))
    if upper.src != beStateRoot:
      return err((VertexID(1),FilStateRootMismatch))
    return ok(upper)

  # Degenerate case: `upper` is non-trivial and `lower` is void
  if upper.isNil or upper.vGen.isNone:
    if lower.src != beStateRoot:
      return err((VertexID(0), FilStateRootMismatch))
    return ok(lower)

  # Verify stackability
  if upper.src != lower.trg or
     lower.src != beStateRoot:
    return err((VertexID(0), FilStateRootMismatch))

  # There is no need to deep copy table vertices as they will not be modified.
  let newFilter = AristoFilterRef(
    src:  lower.src,
    sTab: lower.sTab,
    kMap: lower.kMap,
    vGen: upper.vGen,
    trg:  upper.trg)

  for (vid,vtx) in upper.sTab.pairs:
    if vtx.isValid or not newFilter.sTab.hasKey vid:
      newFilter.sTab[vid] = vtx
    elif newFilter.sTab.getOrVoid(vid).isValid:
      let rc = db.getVtxUBE vid
      if rc.isOk:
        newFilter.sTab[vid] = vtx # VertexRef(nil)
      elif rc.error == GetVtxNotFound:
        newFilter.sTab.del vid
      else:
        return err((vid,rc.error))

  for (vid,key) in upper.kMap.pairs:
    if key.isValid or not newFilter.kMap.hasKey vid:
      newFilter.kMap[vid] = key
    elif newFilter.kMap.getOrVoid(vid).isValid:
      let rc = db.getKeyUBE vid
      if rc.isOk:
        newFilter.kMap[vid] = key # VOID_HASH_KEY
      elif rc.error == GetKeyNotFound:
        newFilter.kMap.del vid
      else:
        return err((vid,rc.error))

  ok newFilter


# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func bulk*(filter: AristoFilterRef): int =
  ## Some measurement for the size of the filter calculated as the length of
  ## the `sTab[]` table plus the lengthof the `kMap[]` table. This can be used
  ## to set a threshold when to flush the staging area to the backend DB to
  ## be used in `stow()`.
  ##
  ## The `filter` argument may be `nil`, i.e. `AristoFilterRef(nil).bulk == 0`
  if filter.isNil: 0 else: filter.sTab.len + filter.kMap.len

func bulk*(layer: AristolayerRef): int =
  ## Variant of `bulk()` for layers rather than filters.
  ##
  ## The `layer` argument may be `nil`, i.e. `AristoLayerRef(nil).bulk == 0`
  if layer.isNil: 0 else: layer.sTab.len + layer.kMap.len

# ------------------------------------------------------------------------------
# Public functions, construct filters
# ------------------------------------------------------------------------------

proc fwdFilter*(
    db: AristoDbRef;
    layer: AristoLayerRef;
    chunkedMpt = false;
      ): Result[AristoFilterRef,(VertexID,AristoError)] =
  ## Assemble forward delta, i.e. changes to the backend equivalent to applying
  ## the current top layer.
  ##
  ## Typically, the `layer` layer would reflect a change of the MPT but there
  ## is the case of partial MPTs sent over the network when synchronising (see
  ## `snap` protocol.) In this case, the state root might not see a change on
  ## the `layer` layer which would result in an error unless the argument
  ## `extendOK` is set `true`
  ##
  ## This delta is taken against the current backend including optional
  ## read-only filter.
  ##
  # Register the Merkle hash keys of the MPT where this reverse filter will be
  # applicable: `be => fg`
  let (srcRoot, trgRoot) = block:
    let rc = db.getLayerStateRoots(layer, chunkedMpt)
    if rc.isOK:
      (rc.value.be, rc.value.fg)
    elif rc.error == FilPrettyPointlessLayer:
      return ok AristoFilterRef(vGen: none(seq[VertexID]))
    else:
      return err((VertexID(1), rc.error))

  ok AristoFilterRef(
    src:  srcRoot,
    sTab: layer.sTab,
    kMap: layer.kMap.pairs.toSeq.mapIt((it[0],it[1].key)).toTable,
    vGen: some(layer.vGen.vidReorg), # Compact recycled IDs
    trg:  trgRoot)


proc revFilter*(
    db: AristoDbRef;
    filter: AristoFilterRef;
      ): Result[AristoFilterRef,(VertexID,AristoError)] =
  ## Assemble reverse filter for the `filter` argument, i.e. changes to the
  ## backend that reverse the effect of applying the this read-only filter.
  ##
  ## This read-only filter is calculated against the current unfiltered
  ## backend (excluding optionally installed read-only filter.)
  ##
  # Register MPT state roots for reverting back
  let rev = AristoFilterRef(
    src: filter.trg,
    trg: filter.src)

  # Get vid generator state on backend
  block:
    let rc = db.getIdgUBE()
    if rc.isErr:
      return err((VertexID(0), rc.error))
    rev.vGen = some rc.value

  # Calculate reverse changes for the `sTab[]` structural table
  for vid in filter.sTab.keys:
    let rc = db.getVtxUBE vid
    if rc.isOk:
      rev.sTab[vid] = rc.value
    elif rc.error == GetVtxNotFound:
      rev.sTab[vid] = VertexRef(nil)
    else:
      return err((vid,rc.error))

  # Calculate reverse changes for the `kMap` sequence.
  for vid in filter.kMap.keys:
    let rc = db.getKeyUBE vid
    if rc.isOk:
      rev.kMap[vid] = rc.value
    elif rc.error == GetKeyNotFound:
      rev.kMap[vid] = VOID_HASH_KEY
    else:
      return err((vid,rc.error))

  ok(rev)

# ------------------------------------------------------------------------------
# Public functions, apply/install filters
# ------------------------------------------------------------------------------

proc merge*(
    db: AristoDbRef;
    filter: AristoFilterRef;
      ): Result[void,(VertexID,AristoError)] =
  ## Merge the argument `filter` into the read-only filter layer. Note that
  ## this function has no control of the filter source. Having merged the
  ## argument `filter`, all the `top` and `stack` layers should be cleared.
  let ubeRootKey = block:
    let rc = db.getKeyUBE VertexID(1)
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err((VertexID(1),rc.error))

  db.roFilter = block:
    let rc = db.merge(filter, db.roFilter, ubeRootKey)
    if rc.isErr:
      return err(rc.error)
    rc.value

  ok()


proc canResolveBE*(db: AristoDbRef): bool =
  ## Check whether the read-only filter can be merged into the backend
  if not db.backend.isNil:
    if db.dudes.isNil or db.dudes.rwOk:
      return true


proc resolveBE*(db: AristoDbRef): Result[void,(VertexID,AristoError)] =
  ## Resolve the backend filter into the physical backend. This requires that
  ## the argument `db` descriptor has read-write permission for the backend
  ## (see also the below function `ackqRwMode()`.)
  ##
  ## For any associated descriptors working on the same backend, their backend
  ## filters will be updated so that the change of the backend DB remains
  ## unnoticed.
  if not db.canResolveBE():
    return err((VertexID(1),FilRoBackendOrMissing))

  # Blind or missing filter
  if db.roFilter.isNil:
    return ok()
  if db.roFilter.vGen.isNone:
    db.roFilter = AristoFilterRef(nil)
    return ok()

  let ubeRootKey = block:
    let rc = db.getKeyUBE VertexID(1)
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err((VertexID(1),rc.error))

  # Filters rollback helper
  var roFilters: seq[(AristoDbRef,AristoFilterRef)]
  proc rollback() =
    for (d,f) in roFilters:
      d.roFilter = f

  # Update dudes
  if not db.dudes.isNil:
    # Calculate reverse filter from current filter
    let rev = block:
      let rc = db.revFilter db.roFilter
      if rc.isErr:
        return err(rc.error)
      rc.value

    # Update distributed filters. Note that the physical backend database
    # has not been updated, yet. So the new root key for the backend will
    # be `db.roFilter.trg`.
    for dude in db.dudes.roDudes.items:
      let rc = db.merge(dude.roFilter, rev, db.roFilter.trg)
      if rc.isErr:
        rollback()
        return err(rc.error)
      roFilters.add (dude, dude.roFilter)
      dude.roFilter = rc.value

  # Save structural and other table entries
  let
    be = db.backend
    txFrame = be.putBegFn()
  be.putVtxFn(txFrame, db.roFilter.sTab.pairs.toSeq)
  be.putKeyFn(txFrame, db.roFilter.kMap.pairs.toSeq)
  be.putIdgFn(txFrame, db.roFilter.vGen.unsafeGet)
  let w = be.putEndFn txFrame
  if w != AristoError(0):
    rollback()
    return err((VertexID(0),w))

  ok()


proc ackqRwMode*(db: AristoDbRef): Result[void,AristoError] =
  ## Re-focus the `db` argument descriptor to backend read-write permission.
  if not db.dudes.isNil and not db.dudes.rwOk:
    # Steal dudes list, make the rw-parent a read-only dude
    let parent = db.dudes.rwDb
    db.dudes = parent.dudes
    parent.dudes = AristoDudesRef(rwOk: false, rwDb: db)

    # Exclude self
    db.dudes.roDudes.excl db

    # Update dudes
    for w in db.dudes.roDudes:
      # Let all other dudes refer to this one
      w.dudes.rwDb = db

    # Update dudes list (parent was alredy updated)
    db.dudes.roDudes.incl parent
    return ok()

  err(FilNotReadOnlyDude)


proc dispose*(db: AristoDbRef): Result[void,AristoError] =
  ## Terminate usage of the `db` argument descriptor with backend read-only
  ## permission.
  ##
  ## This type of descriptoy should always be terminated after use. Otherwise
  ## it would always be udated when running `resolveBE()` which costs
  ## unnecessary computing ressources. Also, the read-only backend filter
  ## copies might grow big when it could be avoided.
  if not db.isNil and
     not db.dudes.isNil and
     not db.dudes.rwOk:
    # Unlink argument `db`
    db.dudes.rwDb.dudes.roDudes.excl db

    # Unlink more so it would not do harm if used wrongly
    db.stack.setlen(0)
    db.backend = AristoBackendRef(nil)
    db.txRef = AristoTxRef(nil)
    db.dudes = AristoDudesRef(nil)
    return ok()

  err(FilNotReadOnlyDude)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
