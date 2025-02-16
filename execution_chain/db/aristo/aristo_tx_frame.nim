# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Transaction frames helper
## ======================================
##
{.push raises: [].}

import
  results,
  ./[aristo_desc, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc txFrameBegin*(db: AristoDbRef, parent: AristoTxRef): Result[AristoTxRef,AristoError] =
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

  let parent = if parent == nil:
    db.txRef
  else:
    parent

  let
    vTop = parent.vTop

  ok AristoTxRef(
    db:     db,
    parent: parent,
    vTop:   vTop,
    cTop:   vTop)

proc baseTxFrame*(db: AristoDbRef): AristoTxRef=
  db.txRef

proc rollback*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## Given a *top level* handle, this function discards all database operations
  ## performed for this transaction.
  # TODO Everyone using this txref should repoint their parent field

  tx.vTop = tx.cTop # Yes, it is cTop
  tx.cTop = tx.cTop

  ok()

proc commit*(
    tx: AristoTxRef;                  # Top transaction on database
      ): Result[void,AristoError] =
  ## This function pushes all changes done in this frame to its parent
  ##
  # TODO Everyone using this txref should repoint their parent field
  doAssert tx.parent != nil, "should not commit the base tx"

  # A rollback after commit should reset to the new vTop!
  tx.cTop = tx.vTop

  mergeAndReset(tx.parent, tx)

  ok()

proc txFramePersist*(
    db: AristoDbRef;                  # Database
    batch: PutHdlRef;
    nxtSid = 0u64;                    # Next state ID (aka block number)
      ) =
  ## Persistently store data onto backend database. If the system is running
  ## without a database backend, the function returns immediately with an
  ## error.
  ##
  ## The function merges all data staged in `txFrame` and merges it onto the
  ## backend database. `txFrame` becomes the new `baseTxFrame`.
  ##
  ## Any parent frames of `txFrame` become invalid after this operation.
  ##
  ## If the argument `nxtSid` is passed non-zero, it will be the ID for the
  ## next recovery journal record. If non-zero, this ID must be greater than
  ## all previous IDs (e.g. block number when stowing after block execution.)
  ##
  let be = db.backend
  doAssert not be.isNil, "Persisting to backend requires ... a backend!"

  let lSst = SavedState(
    key:  emptyRoot,                       # placeholder for more
    serial: nxtSid)

  # Store structural single trie entries
  for rvid, vtx in db.txRef.sTab:
    db.txRef.kMap.withValue(rvid, key) do:
      be.putVtxFn(batch, rvid, vtx, key[])
    do:
      be.putVtxFn(batch, rvid, vtx, default(HashKey))

  be.putTuvFn(batch, db.txRef.vTop)
  be.putLstFn(batch, lSst)

  # TODO above, we only prepare the changes to the database but don't actually
  #      write them to disk - the code below that updates the frame should
  #      really run after things have been written (to maintain sync betweeen
  #      in-memory and on-disk state)

  # Copy back updated payloads
  for accPath, vtx in db.txRef.accLeaves:
    db.accLeaves.put(accPath, vtx)

  for mixPath, vtx in db.txRef.stoLeaves:
    db.stoLeaves.put(mixPath, vtx)

  # Done with txRef, all saved to backend
  db.txRef.cTop = db.txRef.vTop
  db.txRef.sTab.clear()
  db.txRef.kMap.clear()
  db.txRef.accLeaves.clear()
  db.txRef.stoLeaves.clear()


# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
