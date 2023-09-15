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
  std/[sequtils, tables],
  results,
  "."/[aristo_desc, aristo_get, aristo_vid],
  ./aristo_desc/desc_backend,
  ./aristo_filter/[
    filter_fifos, filter_helpers, filter_merge, filter_reverse, filter_siblings]

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func bulk*(filter: FilterRef): int =
  ## Some measurement for the size of the filter calculated as the length of
  ## the `sTab[]` table plus the lengthof the `kMap[]` table. This can be used
  ## to set a threshold when to flush the staging area to the backend DB to
  ## be used in `stow()`.
  ##
  ## The `filter` argument may be `nil`, i.e. `FilterRef(nil).bulk == 0`
  if filter.isNil: 0 else: filter.sTab.len + filter.kMap.len

func bulk*(layer: LayerRef): int =
  ## Variant of `bulk()` for layers rather than filters.
  ##
  ## The `layer` argument may be `nil`, i.e. `LayerRef(nil).bulk == 0`
  if layer.isNil: 0 else: layer.sTab.len + layer.kMap.len

# ------------------------------------------------------------------------------
# Public functions, construct filters
# ------------------------------------------------------------------------------

proc fwdFilter*(
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
    let rc = db.getLayerStateRoots(layer, chunkedMpt)
    if rc.isOK:
      (rc.value.be, rc.value.fg)
    elif rc.error == FilPrettyPointlessLayer:
      return ok FilterRef(nil)
    else:
      return err((VertexID(1), rc.error))

  ok FilterRef(
    src:  srcRoot,
    sTab: layer.sTab,
    kMap: layer.kMap.pairs.toSeq.mapIt((it[0],it[1].key)).toTable,
    vGen: layer.vGen.vidReorg, # Compact recycled IDs
    trg:  trgRoot)

# ------------------------------------------------------------------------------
# Public functions, apply/install filters
# ------------------------------------------------------------------------------

proc merge*(
    db: AristoDbRef;                   # Database
    filter: FilterRef;                 # Filter to apply to database
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

  db.roFilter = ? db.merge(filter, db.roFilter, ubeRootKey)
  ok()


proc canResolveBackendFilter*(db: AristoDbRef): bool =
  ## Check whether the read-only filter can be merged into the backend
  not db.backend.isNil and db.isCentre


proc resolveBackendFilter*(
    db: AristoDbRef;
    reCentreOk = false;
      ): Result[void,AristoError] =
  ## Resolve the backend filter into the physical backend database.
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
  if db.backend.isNil:
    return err(FilBackendMissing)

  let parent = db.getCentre
  if db != parent:
    if not reCentreOk:
      return err(FilBackendRoMode)
    ? db.reCentre
  defer: discard parent.reCentre

  # Blind or missing filter
  if db.roFilter.isNil:
    return ok()

  let ubeRootKey = block:
    let rc = db.getKeyUBE VertexID(1)
    if rc.isOk:
      rc.value
    elif rc.error == GetKeyNotFound:
      VOID_HASH_KEY
    else:
      return err(rc.error)

  let updateSiblings = ? UpdateSiblingsRef.init db
  defer: updateSiblings.rollback()

  # Figure out how to save the reverse filter on a cascades slots queue
  let
    be = db.backend
    backLogOk = not be.filters.isNil           # otherwise disabled
    revFilter = updateSiblings.rev

  # Compile instruction for updating filters on the cascaded fifos
  var instr = FifoInstr()
  block getInstr:
    if not backLogOk:                          # Ignore reverse filter
      break getInstr
    if db.roFilter.isValid:
      let ovLap = be.getFilterOverlap db.roFilter
      if 0 < ovLap:
        instr = ? be.fifosDelete ovLap         # Revert redundant entries
        break getInstr
    instr = ? be.fifosStore updateSiblings.rev # Store reverse filter

  # Save structural and other table entries
  let txFrame = be.putBegFn()
  be.putVtxFn(txFrame, db.roFilter.sTab.pairs.toSeq)
  be.putKeyFn(txFrame, db.roFilter.kMap.pairs.toSeq)
  be.putIdgFn(txFrame, db.roFilter.vGen)
  if backLogOk:
    be.putFilFn(txFrame, instr.put)
    be.putFqsFn(txFrame, instr.scd.state)
  ? be.putEndFn txFrame

  # Update dudes and this descriptor
  ? updateSiblings.update().commit()

  # Finally update slot queue scheduler state (as saved)
  if backLogOk:
    be.filters.state = instr.scd.state

  ok()


proc forkBackLog*(
    db: AristoDbRef;
    episode: int;
      ): Result[AristoDbRef,AristoError] =
  ## Construct a new descriptor on the `db` backend which enters it through a
  ## set of backend filters from the casacded filter fifos. The filter used is
  ## addressed as `episode`, where the most recend backward filter has episode
  ## `0`, the next older has episode `1`, etc.
  ##
  ## Use `aristo_filter.forget()` directive to clean up this descriptor.
  ##
  let be = db.backend
  if be.isNil:
    return err(FilBackendMissing)
  if episode < 0:
    return err(FilNegativeEpisode)
  let
    instr = ? be.fifosFetch(backSteps = episode+1)
    clone = ? db.fork(rawToplayer = true)
  clone.top.vGen = instr.fil.vGen
  clone.roFilter = instr.fil
  ok clone

proc forkBackLog*(
    db: AristoDbRef;
    fid: FilterID;
    earlierOK = false;
      ): Result[AristoDbRef,AristoError] =
  ## ..
  let be = db.backend
  if be.isNil:
    return err(FilBackendMissing)

  let fip = ? be.getFilterFromFifo(fid, earlierOK)
  db.forkBackLog fip.inx

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
