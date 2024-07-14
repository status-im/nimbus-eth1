# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Delta filter management
## ====================================
##

import
  std/tables,
  eth/common,
  results,
  ./aristo_desc,
  ./aristo_desc/desc_backend,
  ./aristo_delta/delta_siblings

# ------------------------------------------------------------------------------
# Public functions, save to backend
# ------------------------------------------------------------------------------

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
  let be = db.backend
  if be.isNil:
    return err(FilBackendMissing)

  # Blind or missing filter
  if db.balancer.isNil:
    return ok()

  # Make sure that the argument `db` is at the centre so the backend is in
  # read-write mode for this peer.
  let parent = db.getCentre
  if db != parent:
    if not reCentreOk:
      return err(FilBackendRoMode)
    ? db.reCentre()
  # Always re-centre to `parent` (in case `reCentreOk` was set)
  defer: discard parent.reCentre()

  # Initialise peer filter balancer.
  let updateSiblings = ? UpdateSiblingsRef.init db
  defer: updateSiblings.rollback()

  let lSst = SavedState(
    key:  EMPTY_ROOT_HASH,                       # placeholder for more
    serial: nxtFid)

  # Store structural single trie entries
  let writeBatch = ? be.putBegFn()
  for rvid, vtx in db.balancer.sTab:
    be.putVtxFn(writeBatch, rvid, vtx)
  for rvid, key in db.balancer.kMap:
    be.putKeyFn(writeBatch, rvid, key)
  be.putTuvFn(writeBatch, db.balancer.vTop)
  be.putLstFn(writeBatch, lSst)
  ? be.putEndFn writeBatch                       # Finalise write batch

  # Copy back updated payloads
  for accPath, pyl in db.balancer.accLeaves:
    let accKey = accPath.to(AccountKey)
    if not db.accLeaves.lruUpdate(accKey, pyl):
      discard db.accLeaves.lruAppend(accKey, pyl, accLruSize)

  # Update dudes and this descriptor
  ? updateSiblings.update().commit()
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
