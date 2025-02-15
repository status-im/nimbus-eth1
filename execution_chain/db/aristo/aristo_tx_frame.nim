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

proc txFrameBegin*(db: AristoDbRef, parent: AristoTxRef): AristoTxRef =
  let parent = if parent == nil:
    db.txRef
  else:
    parent

  let
    vTop = parent.layer.vTop
    layer = LayerRef(vTop: vTop)

  AristoTxRef(
    db:     db,
    parent: parent,
    layer: layer)

proc baseTxFrame*(db: AristoDbRef): AristoTxRef=
  db.txRef

proc dispose*(
    tx: AristoTxRef;
      ) =
  tx[].reset()

proc checkpoint*(
    tx: AristoTxRef;
    blockNumber: uint64;
      ) =
  tx.blockNumber = Opt.some(blockNumber)

proc txFramePersist*(
    db: AristoDbRef;                  # Database
    batch: PutHdlRef;
    txFrame: AristoTxRef;
      ) =

  if txFrame == db.txRef and txFrame.layer.sTab.len == 0:
    # No changes in frame - no `checkpoint` requirement - nothing to do here
    return

  let be = db.backend
  doAssert not be.isNil, "Persisting to backend requires ... a backend!"

  let lSst = SavedState(
    key:  emptyRoot,                       # placeholder for more
    serial: txFrame.blockNumber.expect("`checkpoint` before persisting frame"))

  # Squash all changes up to the base
  if txFrame != db.txRef:
    # Consolidate the changes from the old to the new base going from the
    # bottom of the stack to avoid having to cascade each change through
    # the full stack
    assert txFrame.parent != nil
    for frame in txFrame.stack():
      if frame == db.txRef:
        continue
      mergeAndReset(db.txRef.layer[], frame.layer[])
      db.txRef.blockNumber = frame.blockNumber

      frame.dispose() # This will also dispose `txFrame` itself!

    # Put the now-merged contents in txFrame and make it the new base
    swap(db.txRef[], txFrame[])
    db.txRef = txFrame

  # Store structural single trie entries
  for rvid, vtx in txFrame.layer.sTab:
    txFrame.layer.kMap.withValue(rvid, key) do:
      be.putVtxFn(batch, rvid, vtx, key[])
    do:
      be.putVtxFn(batch, rvid, vtx, default(HashKey))

  be.putTuvFn(batch, txFrame.layer.vTop)
  be.putLstFn(batch, lSst)

  # TODO above, we only prepare the changes to the database but don't actually
  #      write them to disk - the code below that updates the frame should
  #      really run after things have been written (to maintain sync betweeen
  #      in-memory and on-disk state)

  # Copy back updated payloads
  for accPath, vtx in txFrame.layer.accLeaves:
    db.accLeaves.put(accPath, vtx)

  for mixPath, vtx in txFrame.layer.stoLeaves:
    db.stoLeaves.put(mixPath, vtx)

  txFrame.layer.sTab.clear()
  txFrame.layer.kMap.clear()
  txFrame.layer.accLeaves.clear()
  txFrame.layer.stoLeaves.clear()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
