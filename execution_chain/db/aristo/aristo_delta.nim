# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
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
  results,
  ./aristo_desc/desc_backend,
  ./aristo_desc

# ------------------------------------------------------------------------------
# Public functions, save to backend
# ------------------------------------------------------------------------------

proc deltaPersistentOk*(db: AristoDbRef): bool =
  ## Check whether the read-only filter can be merged into the backend
  not db.backend.isNil


proc deltaPersistent*(
    db: AristoDbRef;                   # Database
    nxtFid = 0u64;                     # Next filter ID (if any)
      ): Result[void,AristoError] =
  ## Resolve (i.e. move) txRef into the physical backend database.
  ##
  ## This needs write permission on the backend DB for the descriptor argument
  ## `db` (see the function `aristo_desc.isCentre()`.) If the argument flag
  ## `reCentreOk` is passed `true`, write permission will be temporarily
  ## acquired when needed.
  ##
  ## When merging the current backend filter, its reverse will be is stored
  ## on other non-centre descriptors so there is no visible database change
  ## for these.
  ##
  let be = db.backend
  if be.isNil:
    return err(FilBackendMissing)

  # Blind or missing filter
  if db.txRef.isNil:
    # Add a blind storage frame. This will do no harm if `Aristo` runs
    # standalone. Yet it is needed if a `Kvt` is tied to `Aristo` and has
    # triggered a save cyle already which is to be completed here.
    #
    # There is no need to add a blind frame on any error return. If there
    # is a `Kvt` tied to `Aristo`, then it must somehow run in sync and an
    # error occuring here must have been detected earlier when (implicitely)
    # registering `Kvt`. So that error should be considered a defect.
    ? be.putEndFn(? be.putBegFn())
    return ok()

  let lSst = SavedState(
    key:  emptyRoot,                       # placeholder for more
    serial: nxtFid)

  # Store structural single trie entries
  let writeBatch = ? be.putBegFn()
  for rvid, vtx in db.txRef.layer.sTab:
    db.txRef.layer.kMap.withValue(rvid, key) do:
      be.putVtxFn(writeBatch, rvid, vtx, key[])
    do:
      be.putVtxFn(writeBatch, rvid, vtx, default(HashKey))

  be.putTuvFn(writeBatch, db.txRef.layer.vTop)
  be.putLstFn(writeBatch, lSst)
  ? be.putEndFn writeBatch                       # Finalise write batch

  # Copy back updated payloads
  for accPath, vtx in db.txRef.layer.accLeaves:
    db.accLeaves.put(accPath, vtx)

  for mixPath, vtx in db.txRef.layer.stoLeaves:
    db.stoLeaves.put(mixPath, vtx)

  # Done with txRef, all saved to backend
  db.txRef.layer.cTop = db.txRef.layer.vTop
  db.txRef.layer.sTab.clear()
  db.txRef.layer.kMap.clear()
  db.txRef.layer.accLeaves.clear()
  db.txRef.layer.stoLeaves.clear()

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
