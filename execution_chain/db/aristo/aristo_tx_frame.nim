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

import std/strformat, results, ./[aristo_desc, aristo_fetch, aristo_layers]

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc isKeyframe(txFrame: AristoTxRef): bool =
  txFrame == txFrame.db.txRef

proc buildSnapshot(txFrame: AristoTxRef, minLevel: int) =
  # Starting from the previous snapshot, build a snapshot that includes all
  # ancestor changes as well as the changes in txFrame itself
  for frame in txFrame.stack(stopAtSnapshot = true):
    if frame != txFrame:
      # Keyframes keep their snapshot insted of it being transferred to the new
      # frame - right now, only the base frame is a keyframe but this support
      # could be extended for example to epoch boundary frames which are likely
      # to become new bases.
      let isKeyframe = txFrame.isKeyframe()

      if frame.snapshot.level.isSome() and not isKeyframe:
        # `frame` has a snapshot only in the first iteration of the for loop
        txFrame.snapshot = move(frame.snapshot)

        # Verify that https://github.com/nim-lang/Nim/issues/23759 is not present
        assert frame.snapshot.vtx.len == 0 and frame.snapshot.level.isNone()

        if txFrame.snapshot.level != Opt.some(minLevel):
          # When recycling an existing snapshot, some of its content may have
          # already been persisted to disk (since it was made base on the
          # in-memory frames at the time of its creation).
          # Annoyingly, there's no way to remove items while iterating but even
          # with the extra seq, move + remove turns out to be faster than
          # creating a new table - specially when the ratio between old and
          # and current items favors current items.
          template delIfIt(tbl: var Table, body: untyped) =
            var toRemove = newSeqOfCap[typeof(tbl).A](tbl.len div 2)
            for k, it {.inject.} in tbl:
              if body:
                toRemove.add k
            for k in toRemove:
              tbl.del(k)

          txFrame.snapshot.vtx.delIfIt(it[2] < minLevel)
          txFrame.snapshot.acc.delIfIt(it[1] < minLevel)
          txFrame.snapshot.sto.delIfIt(it[1] < minLevel)

      if frame.snapshot.level.isSome() and isKeyframe:
        txFrame.snapshot.vtx = initTable[RootedVertexID, VtxSnapshot](
          max(1024, max(frame.sTab.len, frame.snapshot.vtx.len))
        )

        txFrame.snapshot.acc = initTable[Hash32, (AccLeafRef, int)](
          max(1024, max(frame.accLeaves.len, frame.snapshot.acc.len))
        )

        txFrame.snapshot.sto = initTable[Hash32, (StoLeafRef, int)](
          max(1024, max(frame.stoLeaves.len, frame.snapshot.sto.len))
        )

        for k, v in frame.snapshot.vtx:
          if v[2] >= minLevel:
            txFrame.snapshot.vtx[k] = v

        for k, v in frame.snapshot.acc:
          if v[1] >= minLevel:
            txFrame.snapshot.acc[k] = v

        for k, v in frame.snapshot.sto:
          if v[1] >= minLevel:
            txFrame.snapshot.sto[k] = v

    # Copy changes into snapshot but keep the diff - the next builder might
    # steal the snapshot!
    txFrame.snapshot.copyFrom(frame)

  txFrame.snapshot.level = Opt.some(minLevel)

proc txFrameBegin*(db: AristoDbRef, parent: AristoTxRef): AristoTxRef =
  let parent = if parent == nil: db.txRef else: parent
  AristoTxRef(db: db, parent: parent, vTop: parent.vTop, level: parent.level + 1)

proc dispose*(tx: AristoTxRef) =
  tx[].reset()

proc checkpoint*(tx: AristoTxRef, blockNumber: uint64, skipSnapshot: bool) =
  tx.blockNumber = Opt.some(blockNumber)

  if not skipSnapshot:
    # Snapshots are expensive, therefore we only do it at checkpoints (which
    # presumably have gone through enough validation)
    tx.buildSnapshot(tx.db.txRef.level)

proc clearSnapshot*(txFrame: AristoTxRef) =
  if not txFrame.isKeyframe():
    txFrame.snapshot.reset()

proc persist*(
    db: AristoDbRef, batch: PutHdlRef, txFrame: AristoTxRef, stateRoot: Opt[Hash32]
) =
  if txFrame == db.txRef and txFrame.isEmpty():
    # No changes in frame - no `checkpoint` requirement - nothing to do here
    return

  let lSst = SavedState(
    vTop: txFrame.vTop,
    serial: txFrame.blockNumber.expect("`checkpoint` before persisting frame"),
  )

  let oldLevel = db.txRef.level
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
        if (bottom.snapshot.vtx.len + bottom.snapshot.acc.len + bottom.snapshot.sto.len) ==
            0:
          bottom.snapshot.level.reset()
        else:
          # Incoming snapshots already have sTab baked in - make sure we don't
          # overwrite merged data from more recent layers with this old version
          bottom.sTab.reset()
          bottom.kMap.reset()
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
  else:
    if txFrame.snapshot.level.isSome():
      # Clear out redundant copy so we don't write it twice, below
      txFrame.sTab.reset()
      txFrame.kMap.reset()

  # Store structural single trie entries
  assert txFrame.snapshot.vtx.len == 0 or txFrame.sTab.len == 0,
    "Either snapshot or sTab should have been cleared as part of merging"

  # Check / update the state root, now that we've flattened the state
  if stateRoot.isSome():
    # State root sanity check is performed to verify, before writing to disk,
    # that optimistically checked blocks indeed end up being stored with a
    # consistent state root.
    # TODO State root checking cost is amortized by performing it only at the
    #      end of a batch of blocks - is there something better the client can
    #      do than shutting down? Either it's a bug or consensus finalized an
    #      invalid block, both of which require attention.
    let frameRoot = txFrame.fetchStateRoot().expect("State root to be readable")
    if frameRoot != stateRoot[]:
      raiseAssert &"""State root sanity check failed, bug?
Expected: {stateRoot[]}, got: {frameRoot}
Either the consensus client gave invalid information about finalized blocks or
something else needs attention! Shutting down to preserve the database - restart
with --debug-eager-state-root."""

  for rvid, item in txFrame.snapshot.vtx:
    if item[2] >= oldLevel:
      db.putVtxFn(batch, rvid, item[0], item[1])

  for rvid, vtx in txFrame.sTab:
    txFrame.kMap.withValue(rvid, key):
      db.putVtxFn(batch, rvid, vtx, key[])
    do:
      db.putVtxFn(batch, rvid, vtx, default(HashKey))

  db.putLstFn(batch, lSst)

  # TODO above, we only prepare the changes to the database but don't actually
  #      write them to disk - the code below that updates the frame should
  #      really run after things have been written (to maintain sync betweeen
  #      in-memory and on-disk state)

  # Copy back updated payloads into the shared database LRU caches.

  # Copy cached values from the snapshot
  for accPath, v in txFrame.snapshot.acc:
    # if v[0] == nil:
    db.accLeaves.del(accPath)
    # else:
    #   discard db.accLeaves.update(accPath, v[0])

  for mixPath, v in txFrame.snapshot.sto:
    # if v[0] == nil:
    db.stoLeaves.del(mixPath)
    # else:
    #   discard db.stoLeaves.update(mixPath, v[0])

  # Copy cached values from the txFrame
  for accPath, vtx in txFrame.accLeaves:
    # if vtx == nil:
    db.accLeaves.del(accPath)
    # else:
    #   discard db.accLeaves.update(accPath, vtx)

  for mixPath, vtx in txFrame.stoLeaves:
    # if vtx == nil:
    db.stoLeaves.del(mixPath)
    # else:
    #   discard db.stoLeaves.update(mixPath, vtx)

  txFrame.snapshot.vtx.clear()
  txFrame.snapshot.acc.clear()
  txFrame.snapshot.sto.clear()
  # Since txFrame is now the base, it contains all changes and therefore acts
  # as a snapshot
  txFrame.snapshot.level = Opt.some(txFrame.level)
  txFrame.sTab.clear()
  txFrame.kMap.clear()
  txFrame.accLeaves.clear()
  txFrame.stoLeaves.clear()
  txFrame.blockNumber.reset()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
