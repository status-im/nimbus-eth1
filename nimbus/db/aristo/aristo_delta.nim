# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Filter and journal management
## ==========================================
##

import
  std/[options, sequtils, sets, tables],
  eth/common,
  results,
  "."/[aristo_desc, aristo_get, aristo_vid],
  ./aristo_desc/desc_backend,
  ./aristo_delta/[delta_state_root, delta_merge, delta_siblings]

# ------------------------------------------------------------------------------
# Public functions, construct filters
# ------------------------------------------------------------------------------

proc deltaFwd*(
    db: AristoDbRef;                   # Database
    layer: LayerRef;                   # Layer to derive filter from
    chunkedMpt = false;                # Relax for snap/proof scenario
     ): Result[FilterRef,(VertexID,AristoError)] =
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
    let rc = db.getLayerStateRoots(layer.delta, chunkedMpt)
    if rc.isOK:
      (rc.value.be, rc.value.fg)
    elif rc.error == FilPrettyPointlessLayer:
      return ok FilterRef(nil)
    else:
      return err((VertexID(1), rc.error))

  ok FilterRef(
    src:  srcRoot,
    sTab: layer.delta.sTab,
    kMap: layer.delta.kMap,
    vGen: layer.final.vGen.vidReorg, # Compact recycled IDs
    trg:  trgRoot)

# ------------------------------------------------------------------------------
# Public functions, apply/install filters
# ------------------------------------------------------------------------------

proc deltaMerge*(
    db: AristoDbRef;                   # Database
    filter: FilterRef;                 # Filter to apply to database
      ): Result[void,(VertexID,AristoError)] =
  ## Merge the argument `filter` into the read-only filter layer. Note that
  ## this function has no control of the filter source. Having merged the
  ## argument `filter`, all the `top` and `stack` layers should be cleared.
  ##
  let ubeRoot = block:
    let rc = db.getKeyUbe VertexID(1)
    if rc.isOk:
      rc.value.to(Hash256)
    elif rc.error == GetKeyNotFound:
      EMPTY_ROOT_HASH
    else:
      return err((VertexID(1),rc.error))

  db.roFilter = ? db.merge(filter, db.roFilter, ubeRoot)
  if db.roFilter.src == db.roFilter.trg:
    # Under normal conditions, the root keys cannot be the same unless the
    # database is empty. This changes if there is a fixed root vertex as
    # used with the `snap` sync protocol boundaty proof. In that case, there
    # can be no history chain and the filter is just another cache.
    if VertexID(1) notin db.top.final.pPrf:
      db.roFilter = FilterRef(nil)

  ok()


proc deltaPersistentOk*(db: AristoDbRef): bool =
  ## Check whether the read-only filter can be merged into the backend
  not db.backend.isNil and db.isCentre


proc deltaPersistent*(
    db: AristoDbRef;                   # Database
    nxtFid = 0u64;                     # Next filter ID (if any)
    reCentreOk = false;
      ): Result[void,AristoError] =
  ## Resolve (i.e. move) the backend filter into the physical backend database.
  ##
  ## This needs write permission on the backend DB for the argument `db`
  ## descriptor (see the function `aristo_desc.isCentre()`.) With the argument
  ## flag `reCentreOk` passed `true`, write permission will be temporarily
  ## acquired when needed.
  ##
  ## When merging the current backend filter, its reverse will be is stored as
  ## back log on the filter fifos (so the current state can be retrieved.)
  ## Also, other non-centre descriptors are updated so there is no visible
  ## database change for these descriptors.
  ##
  ## Caveat: This function will delete entries from the cascaded fifos if the
  ##         current backend filter is the reverse compiled from the top item
  ##         chain from the cascaded fifos as implied by the function
  ##         `forkBackLog()`, for example.
  ##
  let be = db.backend
  if be.isNil:
    return err(FilBackendMissing)

  # Blind or missing filter
  if db.roFilter.isNil:
    return ok()

  # Make sure that the argument `db` is at the centre so the backend is in
  # read-write mode for this peer.
  let parent = db.getCentre
  if db != parent:
    if not reCentreOk:
      return err(FilBackendRoMode)
    db.reCentre
  # Always re-centre to `parent` (in case `reCentreOk` was set)
  defer: parent.reCentre

  # Initialise peer filter balancer.
  let updateSiblings = ? UpdateSiblingsRef.init db
  defer: updateSiblings.rollback()

  let lSst = SavedState(
    src: db.roFilter.src,
    trg: db.roFilter.trg,
    serial: nxtFid)

  # Store structural single trie entries
  let writeBatch = be.putBegFn()
  be.putVtxFn(writeBatch, db.roFilter.sTab.pairs.toSeq)
  be.putKeyFn(writeBatch, db.roFilter.kMap.pairs.toSeq)
  be.putIdgFn(writeBatch, db.roFilter.vGen)
  be.putLstFn(writeBatch, lSst)
  ? be.putEndFn writeBatch                       # Finalise write batch

  # Update dudes and this descriptor
  ? updateSiblings.update().commit()
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
