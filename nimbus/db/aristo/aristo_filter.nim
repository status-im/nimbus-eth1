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

  db.roFilter = block:
    let rc = db.merge(filter, db.roFilter, ubeRootKey)
    if rc.isErr:
      return err(rc.error)
    rc.value

  ok()


proc canResolveBE*(db: AristoDbRef): bool =
  ## Check whether the read-only filter can be merged into the backend
  not db.backend.isNil and db.isCentre


proc resolveBE*(db: AristoDbRef): Result[void,(VertexID,AristoError)] =
  ## Resolve the backend filter into the physical backend. This requires that
  ## the argument `db` descriptor has write permission for the backend (see
  ## the function `aristo_desc.isCentre()`.)
  ##
  ## For any associated descriptors working on the same backend, their backend
  ## filters will be updated so that the change of the backend DB remains
  ## unnoticed.
  ##
  ## Unless the disabled (see `newAristoDbRef()`, reverse filters are stored
  ## on a cascaded fifo table so that recent database states can be reverted.
  ##
  if db.backend.isNil:
    return err((VertexID(0),FilBackendMissing))
  if not db.isCentre:
    return err((VertexID(0),FilBackendRoMode))

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
      return err((VertexID(1),rc.error))

  let updateSiblings = block:
    let rc = UpdateSiblingsRef.init db
    if rc.isErr:
      return err((VertexID(0),rc.error))
    rc.value
  defer: updateSiblings.rollback()

  # Figure out how to save the reverse filter on a cascades slots queue
  let be = db.backend
  var instr: FifoInstr
  if not be.filters.isNil:
    let rc = be.store updateSiblings.rev
    if rc.isErr:
      return err((VertexID(0),rc.error))
    instr = rc.value

  # Save structural and other table entries
  let txFrame = be.putBegFn()
  be.putVtxFn(txFrame, db.roFilter.sTab.pairs.toSeq)
  be.putKeyFn(txFrame, db.roFilter.kMap.pairs.toSeq)
  be.putIdgFn(txFrame, db.roFilter.vGen)
  if not be.filters.isNil:
    be.putFilFn(txFrame, instr.put)
    be.putFqsFn(txFrame, instr.scd.state)
  let w = be.putEndFn txFrame
  if w != AristoError(0):
    return err((VertexID(0),w))

  # Update dudes
  block:
    let rc = updateSiblings.update().commit()
    if rc.isErr:
      return err((VertexID(0),rc.error))

  # Update slot queue scheduler state (as saved)
  if not be.filters.isNil:
    be.filters.state = instr.scd.state

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
