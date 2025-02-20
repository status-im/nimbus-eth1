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

import results, ./[aristo_desc, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc buildSnapshot(txFrame: AristoTxRef, minLevel: int) =
  # Starting from the previous snapshot, build a snapshot that includes all
  # ancestor changes as well as the changes in txFrame itself
  for frame in txFrame.stack(stopAtSnapshot = true):
    if frame != txFrame:
      # Keyframes keep their snapshot insted of it being transferred to the new
      # frame - right now, only the base frame is a keyframe but this support
      # could be extended for example to epoch boundary frames which are likely
      # to become new bases.
      let isKeyframe = frame == frame.db.txRef

      if frame.snapshotLevel.isSome() and not isKeyframe:
        # `frame` has a snapshot only in the first iteration of the for loop
        txFrame.snapshot = move(frame.snapshot)
        txFrame.snapshotLevel = frame.snapshotLevel

        assert frame.snapshot.len == 0 # https://github.com/nim-lang/Nim/issues/23759
        frame.snapshotLevel.reset() # in case there was a snapshot in txFrame already

        if txFrame.snapshotLevel != Opt.some(minLevel):
          # When recycling an existing snapshot, some of its content may have
          # already been persisted to disk (since it was made base on the
          # in-memory frames at the time of its creation).
          # Annoyingly, there's no way to remove items while iterating but even
          # with the extra seq, move + remove turns out to be faster than
          # creating a new table - specially when the ratio between old and
          # and current items favors current items.
          var toRemove = newSeqOfCap[RootedVertexID](txFrame.snapshot.len div 2)
          for rvid, v in txFrame.snapshot:
            if v[2] < minLevel:
              toRemove.add rvid
          for rvid in toRemove:
            txFrame.snapshot.del(rvid)

      if frame.snapshotLevel.isSome() and isKeyframe:
        txFrame.snapshot = initTable[RootedVertexID, Snapshot](
          max(1024, max(frame.sTab.len, frame.snapshot.len))
        )

        for k, v in frame.snapshot:
          if v[2] >= minLevel:
            txFrame.snapshot[k] = v

    # Copy changes into snapshot but keep the diff - the next builder might
    # steal the snapshot!
    txFrame.snapshot.copyFrom(frame)

  txFrame.snapshotLevel = Opt.some(minLevel)

proc txFrameBegin*(db: AristoDbRef, parent: AristoTxRef): AristoTxRef =
  let parent = if parent == nil: db.txRef else: parent
  AristoTxRef(db: db, parent: parent, vTop: parent.vTop, level: parent.level + 1)

proc baseTxFrame*(db: AristoDbRef): AristoTxRef =
  db.txRef

proc dispose*(tx: AristoTxRef) =
  tx[].reset()

proc checkpoint*(tx: AristoTxRef, blockNumber: uint64, skipSnapshot: bool) =
  tx.blockNumber = Opt.some(blockNumber)

  if not skipSnapshot:
    # Snapshots are expensive, therefore we only do it at checkpoints (which
    # presumably have gone through enough validation)
    tx.buildSnapshot(tx.db.txRef.level)

proc persist*(db: AristoDbRef, batch: PutHdlRef, txFrame: AristoTxRef) =
  if txFrame == db.txRef and txFrame.isEmpty():
    # No changes in frame - no `checkpoint` requirement - nothing to do here
    return

  let lSst = SavedState(
    key: emptyRoot, # placeholder for more
    serial: txFrame.blockNumber.expect("`checkpoint` before persisting frame"),
  )

  if txFrame != db.txRef:
    # Consolidate the changes from the old to the new base going from the
    # bottom of the stack to avoid having to cascade each change through
    # the full stack
    assert txFrame.parent != nil

    var bottom: AristoTxRef

    for frame in txFrame.stack(stopAtSnapshot = true):
      if bottom == nil:
        # db.txRef always is a snapshot, therefore we're guaranteed to end up
        # here
        bottom = frame

        # If there is no snapshot, consolidate changes into sTab/kMap instead
        # which caters to the scenario where changes from multiple blocks
        # have already been written to sTab and the changes can moved into
        # the bottom.
        if bottom.snapshot.len == 0:
          bottom.snapshotLevel.reset()
        continue

      doAssert not bottom.isNil, "should have found db.txRef at least"
      mergeAndReset(bottom, frame)

      frame.dispose() # This will also dispose `txFrame` itself!

    # Put the now-merged contents in txFrame and make it the new base
    swap(bottom[], txFrame[])
    db.txRef = txFrame

    if txFrame.parent != nil:
      # Can't use rstack here because dispose will break the parent chain
      for frame in txFrame.parent.stack():
        frame.dispose()

      txFrame.parent = nil

  # Store structural single trie entries
  for rvid, item in txFrame.snapshot:
    db.putVtxFn(batch, rvid, item[0], item[1])

  for rvid, vtx in txFrame.sTab:
    txFrame.kMap.withValue(rvid, key):
      db.putVtxFn(batch, rvid, vtx, key[])
    do:
      db.putVtxFn(batch, rvid, vtx, default(HashKey))

  db.putTuvFn(batch, txFrame.vTop)
  db.putLstFn(batch, lSst)

  # TODO above, we only prepare the changes to the database but don't actually
  #      write them to disk - the code below that updates the frame should
  #      really run after things have been written (to maintain sync betweeen
  #      in-memory and on-disk state)

  # Copy back updated payloads
  for accPath, vtx in txFrame.accLeaves:
    db.accLeaves.put(accPath, vtx)

  for mixPath, vtx in txFrame.stoLeaves:
    db.stoLeaves.put(mixPath, vtx)

  txFrame.snapshot.clear()
  # Since txFrame is now the base, it contains all changes and therefore acts
  # as a snapshot
  txFrame.snapshotLevel = Opt.some(txFrame.level)
  txFrame.sTab.clear()
  txFrame.kMap.clear()
  txFrame.accLeaves.clear()
  txFrame.stoLeaves.clear()
  txFrame.blockNumber.reset()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
