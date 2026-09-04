# nimbus-eth1
# Copyright (c) 2023-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [], gcsafe.}

import
  std/[atomics, strformat],
  chronicles,
  results,
  eth/common/[base_rlp, hashes_rlp],
  ./[aristo_desc, aristo_get, aristo_layers, aristo_blobify, aristo_serialise],
  ./aristo_desc/desc_backend,
  ../../concurrency/[queue, shared_types]

export aristo_desc, chronicles, base_rlp, hashes_rlp, shared_types

type
  WriteBatch* = object
    writer*: PutHdlRef
    count*: int
    depth*: int
    prefix*: uint64
    tasksCompleted*: int
    tasksTotal*: int

  ConcurrentVertexBufQueue* = ConcurrentQueue[3, (RootedVertexID, VertexBuf)]

  KeyWriteBuf* = SharedSeq[(RootedVertexID, HashKey, uint32)]

proc `=copy`(
    dest: var WriteBatch, src: WriteBatch
) {.error: "Copying WriteBatch is forbidden".} =
  discard

# Keep write batch size _around_ 1mb, give or take some overhead - this is a
# tradeoff between efficiency and memory usage with diminishing returns the
# larger it is..
const batchSize = 32 * 1024 * 1024 div (sizeof(RootedVertexID) + sizeof(VertexBuf))

func progress(batch: WriteBatch, parallel: static bool): string =
  when parallel:
    # Return the number of completed sub tasks out of the total. The total is usually 16
    # but may be less depending on how many sub-tries need to have hashkeys computed.
    &"{batch.tasksCompleted}/{batch.tasksTotal}"
  else:
    # Return an approximation on how much of the keyspace has been covered by
    # looking at the path prefix that we're currently processing
    &"{(float(batch.prefix) / float(uint64.high)) * 100:02.2f}%"

func enter(batch: var WriteBatch, nibble: uint8) =
  batch.depth += 1
  if batch.depth <= 16:
    batch.prefix += uint64(nibble) shl ((16 - batch.depth) * 4)

func leave(batch: var WriteBatch, nibble: uint8) =
  if batch.depth <= 16:
    batch.prefix -= uint64(nibble) shl ((16 - batch.depth) * 4)
  batch.depth -= 1

proc flush(batch: var WriteBatch, db: AristoDbRef): Result[void, AristoError] =
  if batch.writer != nil:
    ?db.putEndFn batch.writer
    batch.writer = nil
  ok()

template flushCheck(
    batch: var WriteBatch, db: AristoDbRef, parallel: static bool
): Result[void, AristoError] =
  if batch.count mod batchSize == 0:
    ?batch.flush(db)

    when parallel:
      if batch.count mod (batchSize * 10) == 0:
        info "Writing computeKey cache",
          keys = batch.count, tasksCompleted = batch.progress(parallel)
      else:
        debug "Writing computeKey cache",
          keys = batch.count, tasksCompleted = batch.progress(parallel)
    else:
      if batch.count mod (batchSize * 10) == 0:
        info "Writing computeKey cache",
          keys = batch.count, accounts = batch.progress(parallel)
      else:
        debug "Writing computeKey cache",
          keys = batch.count, accounts = batch.progress(parallel)
  ok()

proc putVtx(
    batch: var WriteBatch,
    db: AristoDbRef,
    rvid: RootedVertexID,
    vtx: VertexRef,
    key: HashKey,
): Result[void, AristoError] =
  if batch.writer == nil:
    batch.writer = ?db.putBegFn()

  db.putVtxFn(batch.writer, rvid, vtx, key)
  inc batch.count
  ?batch.flushCheck(db, parallel = false)

  ok()

proc putKeyAtLevel(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    vtx: VertexRef,
    key: HashKey,
    level: int,
    batch: var WriteBatch,
    snapshotFrame: AristoTxRef,
): Result[void, AristoError] =
  ## Store a hash key in the given layer or directly to the underlying database
  ## which helps ensure that memory usage is proportional to the pending change
  ## set (vertex data may have been committed to disk without computing the
  ## corresponding hash!)

  if level >= txRef.db.baseTxFrame().level:
    var frame = txRef
    while frame.level > level:
      frame = frame.parent

    frame.layersMergeKey(rvid, key)
    # A snapshot frame at or below the merge level must not be patched - the
    # equal-level case is already covered by layersMergeKey updating its own
    # frame's snapshot.
    if not snapshotFrame.isNil and level < snapshotFrame.level:
      snapshotFrame.layersMergeKeyInSnapshot(rvid, key)
  elif level == dbLevel:
    ?batch.putVtx(txRef.db, rvid, vtx, key)
  else: # level > dbLevel but less than baseTxFrame level
    # Throw defect here because we should not be writing vertexes to the database if
    # from a lower level than the baseTxFrame level.
    raiseAssert(
      "Cannot write keys at level < baseTxFrame level. Found level = " & $level &
        ", baseTxFrame level = " & $txRef.db.baseTxFrame().level
    )

  ok()

func layersGetKeyOrVtx*(
    db: AristoTxRef, rvid: RootedVertexID
): Opt[((HashKey, VertexRef), int)] =
  for w in db.rstack(stopAtSnapshot = true):
    if w.snapshot.level.isSome():
      w.snapshot.vtx.withValue(rvid, item):
        return Opt.some(((item[][1], item[][0]), item[][2]))
      break

    w.kMap.withValue(rvid, item):
      return ok(((item[], nil), w.level))
    w.sTab.withValue(rvid, item):
      return Opt.some(((VOID_HASH_KEY, item[]), w.level))

  Opt.none(((HashKey, VertexRef), int))

proc getKey(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    skipLayers: static bool,
    parallel: static bool,
): Result[((HashKey, VertexRef), int), AristoError] =
  const flags: set[GetVtxFlag] =
    when parallel or skipLayers:
      {GetVtxFlag.PeekCache}
    else:
      {}

  when not skipLayers:
    let keyVtxRes = txRef.layersGetKeyOrVtx(rvid)
    if keyVtxRes.isSome():
      return ok(keyVtxRes[])

  ok((?txRef.db.getKeyBe(rvid, flags), dbLevel))

proc getKeys(
    txRef: AristoTxRef,
    root: VertexID,
    vtx: BranchRef,
    keyvtxs: var array[16, ((HashKey, VertexRef), int)],
    skipLayers: static bool,
    parallel: static bool,
): Result[void, AristoError] =
  const flags: set[GetVtxFlag] =
    when parallel or skipLayers:
      {GetVtxFlag.PeekCache}
    else:
      {}

  var
    rvids {.noinit.}: array[16, RootedVertexID]
    nibbles {.noinit.}: array[16, uint8]
    nFetch = 0

  for n, subvid in vtx.pairs:
    when not skipLayers:
      let keyVtxRes = txRef.layersGetKeyOrVtx((root, subvid))
      if keyVtxRes.isSome():
        keyvtxs[n] = keyVtxRes[]
        continue
    rvids[nFetch] = (root, subvid)
    nibbles[nFetch] = n
    inc nFetch

  if nFetch > 0:
    var keyvtxsBe: array[16, (HashKey, VertexRef)]
    ?txRef.db.getKeysBe(
      rvids.toOpenArray(0, nFetch - 1), keyvtxsBe.toOpenArray(0, nFetch - 1), flags
    )
    for j in 0 ..< nFetch:
      keyvtxs[nibbles[j].int] = (keyvtxsBe[j], dbLevel)

  ok()

template childVid(vp: VertexRef): VertexID =
  # If we have to recurse into a child, where would that recusion start?
  let v = vp
  case v.vType
  of AccLeaf:
    let v = AccLeafRef(v)
    if v.stoID.isValid:
      v.stoID.vid
    else:
      default(VertexID)
  of Branch, ExtBranch:
    let v = BranchRef(v)
    v.startVid
  of BoundaryNode, StoLeaf, LeafPtr:
    default(VertexID)

proc computeKeyImpl(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    batch: var WriteBatch,
    vtx: VertexRef,
    level: int,
    skipLayers: static bool,
    spawnTpTasks: static bool,
    parallel: static bool,
    snapshotFrame: AristoTxRef,
    keyBuf: ptr KeyWriteBuf,
    vtxBufQueue: ptr ConcurrentVertexBufQueue,
): Result[(HashKey, int), AristoError]

when compileOption("threads"):
  when not defined(windows):
    import std/posix

  proc mergeKeys(
      txRef: AristoTxRef, bufs: openArray[KeyWriteBuf], snapshotFrame: AristoTxRef
  ) =
    ## Merge buffered hash keys into the layer that each key was computed against
    ## which helps ensure that memory usage is proportional to the pending change
    ## set (vertex data may have been committed to disk without computing the
    ## corresponding hash!)
    var total = 0
    for buf in bufs:
      total += buf.len

    if total == 0:
      return

    let baseLevel = txRef.db.baseTxFrame().level
    var
      frames = newSeq[AristoTxRef](txRef.level - baseLevel + 1)
      counts = newSeq[int](frames.len)

    block:
      var frame = txRef
      while not frame.isNil and frame.level >= baseLevel:
        frames[frame.level - baseLevel] = frame
        frame = frame.parent

    for buf in bufs:
      for item in buf:
        let level = item[2].int

        doAssert level >= baseLevel and level <= txRef.level,
          "Cannot write keys at level < baseTxFrame level. Found level = " & $level &
            ", baseTxFrame level = " & $baseLevel

        inc counts[level - baseLevel]

    for i, count in counts:
      if count > 0:
        frames[i].layersReserveKeys(count)

    for buf in bufs:
      for item in buf:
        frames[item[2].int - baseLevel].layersMergeKey(item[0], item[1])
        if not snapshotFrame.isNil and item[2].int < snapshotFrame.level:
          snapshotFrame.layersMergeKeyInSnapshot(item[0], item[1])

  proc putVtxBlob(
      batch: var WriteBatch, db: AristoDbRef, rvid: RootedVertexID, vtx: openArray[byte]
  ): Result[void, AristoError] =
    if batch.writer == nil:
      batch.writer = ?db.putBegFn()

    db.putVtxBlobFn(batch.writer, rvid, vtx)
    inc batch.count
    ?batch.flushCheck(db, parallel = true)

    ok()

  proc computeKeyImplTask(
      txRef: ptr AristoTxRef,
      rvid: RootedVertexID,
      batch: ptr WriteBatch,
      vtx: ptr VertexRef,
      level: int,
      skipLayers: bool,
      keyBuf: ptr KeyWriteBuf,
      vtxBufQueue: ptr ConcurrentVertexBufQueue,
  ): Result[(HashKey, int), AristoError] =
    if skipLayers:
      txRef[].computeKeyImpl(
        rvid,
        batch[],
        vtx[],
        level,
        skipLayers = true,
        spawnTpTasks = false,
        parallel = true,
        snapshotFrame = nil,
        keyBuf,
        vtxBufQueue,
      )
    else:
      txRef[].computeKeyImpl(
        rvid,
        batch[],
        vtx[],
        level,
        skipLayers = false,
        spawnTpTasks = false,
        parallel = true,
        snapshotFrame = nil,
        keyBuf,
        vtxBufQueue,
      )

proc computeKeyImpl(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    batch: var WriteBatch,
    vtx: VertexRef,
    level: int,
    skipLayers: static bool,
    spawnTpTasks: static bool,
    parallel: static bool,
    snapshotFrame: AristoTxRef,
    keyBuf: ptr KeyWriteBuf,
    vtxBufQueue: ptr ConcurrentVertexBufQueue,
): Result[(HashKey, int), AristoError] =
  # The bloom filter available used only when creating the key cache from an
  # empty state

  # Top-most level of all the verticies this hash computation depends on
  var level = level

  let key =
    case vtx.vType
    of AccLeaf:
      let vtx = AccLeafRef(vtx)
      let skey =
        if vtx.stoID.isValid:
          let
            keyvtxl =
              ?txRef.getKey((vtx.stoID.vid, vtx.stoID.vid), skipLayers, parallel)
            (skey, sl) =
              if keyvtxl[0][0].isValid:
                (keyvtxl[0][0], keyvtxl[1])
              else:
                ?txRef.computeKeyImpl(
                  (vtx.stoID.vid, vtx.stoID.vid),
                  batch,
                  keyvtxl[0][1],
                  keyvtxl[1],
                  skipLayers = skipLayers,
                  spawnTpTasks = false,
                  parallel,
                  snapshotFrame,
                  keyBuf,
                  vtxBufQueue,
                )
          level = max(level, sl)
          skey
        else:
          VOID_HASH_KEY
      rlpEncodeAccLeaf(vtx.pfx, vtx.account, skey).digestTo(HashKey)
    of StoLeaf:
      let vtx = StoLeafRef(vtx)
      rlpEncodeStoLeaf(vtx.pfx, vtx.stoData).digestTo(HashKey)
    of BoundaryNode:
      # Boundary node from a witness (no branch): pfx and childKey (absent branch
      # hash) are sufficient to get the extension RLP. putSubtrie set the key
      # so normally this branch is not reached.
      let ev = BoundaryNodeRef(vtx)
      rlpEncodeExt(ev.pfx, ev.childKey).digestTo(HashKey)
    of LeafPtr:
      let
        leafVid = LeafPtrRef(vtx).vid
        keyvtxl = ?txRef.getKey((rvid.root, leafVid), skipLayers, parallel)
        (leafKey, leafLevel) = ?txRef.computeKeyImpl(
          (rvid.root, leafVid),
          batch,
          keyvtxl[0][1],
          keyvtxl[1],
          skipLayers = skipLayers,
          spawnTpTasks = false,
          parallel,
          snapshotFrame,
          keyBuf,
          vtxBufQueue,
        )
      level = max(level, leafLevel)
      leafKey
    of Branches:
      # For branches, we need to load the vertices before recursing into them
      # to exploit their on-disk order
      let vtx = BranchRef(vtx)
      var keyvtxs: array[16, ((HashKey, VertexRef), int)]
      ?txRef.getKeys(rvid.root, vtx, keyvtxs, skipLayers, parallel)

      when spawnTpTasks:
        var
          futs: array[16, Flowvar[Result[(HashKey, int), AristoError]]]
          keyBufs: array[16, KeyWriteBuf]
          vtxBufQueues: array[16, ConcurrentVertexBufQueue]

        defer:
          for buf in keyBufs.mitems:
            buf.dispose()

      # Make sure we have keys computed for each hash
      block keysComputed:
        while true:
          # Compute missing keys in the order of the child vid that we have to
          # recurse into, again exploiting on-disk order - this more than
          # doubles computeKey speed on a fresh database!
          var
            minVid = default(VertexID)
            minIdx = keyvtxs.len + 1 # index where the minvid can be found
            n = 0'u8 # number of already-processed keys, for the progress bar

          # The O(n^2) sort/search here is fine given the small size of the list
          for nibble, keyvtx in keyvtxs.mpairs:
            when spawnTpTasks:
              if futs[nibble].isSpawned():
                n += 1 # no need to compute key
                continue

            let subvid = vtx.bVid(uint8 nibble)
            if (not subvid.isValid) or keyvtx[0][0].isValid:
              n += 1 # no need to compute key
              continue

            let childVid = keyvtx[0][1].childVid
            if not childVid.isValid:
              # leaf vertex without storage ID - we can compute the key trivially
              (keyvtx[0][0], keyvtx[1]) = ?txRef.computeKeyImpl(
                (rvid.root, subvid),
                batch,
                keyvtx[0][1],
                keyvtx[1],
                skipLayers = skipLayers,
                spawnTpTasks = false,
                parallel,
                snapshotFrame,
                keyBuf,
                vtxBufQueue,
              )
              n += 1
              continue

            if minIdx == keyvtxs.len + 1 or childVid < minVid:
              minIdx = nibble
              minVid = childVid

          if minIdx == keyvtxs.len + 1: # no uncomputed key found!
            break keysComputed

          when spawnTpTasks:
            let
              vid = (rvid.root, vtx.bVid(uint8 minIdx))
              batchPtr: ptr WriteBatch = batch.addr
              vtxPtr = keyvtxs[minIdx][0][1].addr
              level = keyvtxs[minIdx][1]

            vtxBufQueues[minIdx].init()
            futs[minIdx] = txRef.db.taskpool.spawn computeKeyImplTask(
              txRef.addr,
              vid,
              batchPtr,
              vtxPtr,
              level,
              skipLayers,
              keyBufs[minIdx].addr,
              vtxBufQueues[minIdx].addr,
            )
            inc batch.tasksTotal
          else:
            when not parallel:
              batch.enter(n)
            (keyvtxs[minIdx][0][0], keyvtxs[minIdx][1]) = ?txRef.computeKeyImpl(
              (rvid.root, vtx.bVid(uint8 minIdx)),
              batch,
              keyvtxs[minIdx][0][1],
              keyvtxs[minIdx][1],
              skipLayers,
              spawnTpTasks = false,
              parallel,
              snapshotFrame,
              keyBuf,
              vtxBufQueue,
            )
            when not parallel:
              batch.leave(n)

      when spawnTpTasks:
        var runningFutsIndexes: set[uint8] = {}
        for i, f in futs:
          if f.isSpawned() and not f.isReady():
            runningFutsIndexes.incl(i.uint8)

        var idleRounds = 0
        while runningFutsIndexes.len() > 0:
          var
            indexesToRemove: seq[uint8]
            progressed = false

          for i in runningFutsIndexes:
            if futs[i].isReady():
              indexesToRemove.add(i)
              inc batch.tasksCompleted
              progressed = true
              continue

            if not vtxBufQueues[i].isEmpty():
              var v: (RootedVertexID, VertexBuf)
              if vtxBufQueues[i].tryPop(v):
                progressed = true
                ?batch.putVtxBlob(txRef.db, v[0], v[1].data())

          for i in indexesToRemove:
            runningFutsIndexes.excl(i)

          if progressed:
            idleRounds = 0
          else:
            when defined(windows):
              cpuRelax()
            else:
              if idleRounds < 64:
                inc idleRounds
                cpuRelax()
              else:
                var req = Timespec(tv_sec: posix.Time(0), tv_nsec: 100_000)
                discard nanosleep(req, req)

        # At this point all futures have finished running.
        # Now we process any remaining data in the queues.
        for i, f in futs:
          if f.isSpawned():
            if not vtxBufQueues[i].isEmpty():
              var v: (RootedVertexID, VertexBuf)
              while vtxBufQueues[i].tryPop(v):
                ?batch.putVtxBlob(txRef.db, v[0], v[1].data())

            (keyvtxs[i][0][0], keyvtxs[i][1]) = ?sync(f)
            vtxBufQueues[i].dispose()

        txRef.mergeKeys(keyBufs, snapshotFrame)

      template branchSubKey(): untyped =
        if subvid.isValid:
          level = max(level, keyvtxs[n][1])
          keyvtxs[n][0][0]
        else:
          VOID_HASH_KEY

      if vtx.vType == ExtBranch:
        let brKey = rlpEncodeBranch(vtx, branchSubKey()).digestTo(HashKey)
        rlpEncodeExt(ExtBranchRef(vtx).pfx, brKey).digestTo(HashKey)
      else:
        rlpEncodeBranch(vtx, branchSubKey()).digestTo(HashKey)

  # Cache the hash into the same storage layer as the the top-most value that it
  # depends on (recursively) - this could be an ephemeral in-memory layer or the
  # underlying database backend - typically, values closer to the root are more
  # likely to live in an in-memory layer since any leaf change will lead to the
  # root key also changing while leaves that have never been hashed will see
  # their hash being saved directly to the backend.

  if vtx.vType in Branches or vtx.vType == LeafPtr:
    when parallel and not spawnTpTasks:
      if keyBuf.isNil:
        ?txRef.putKeyAtLevel(rvid, vtx, key, level, batch, snapshotFrame)
      elif level >= txRef.db.baseTxFrame().level:
        keyBuf[].add((rvid, key, level.uint32))
      elif level == dbLevel:
        var vtxBuf: VertexBuf
        vtx.blobifyTo(key, vtxBuf)
        vtxBufQueue[].push((rvid, vtxBuf))
      else:
        raiseAssert(
          "Cannot write keys at level < baseTxFrame level. Found level = " & $level &
            ", baseTxFrame level = " & $txRef.db.baseTxFrame().level
        )
    else:
      ?txRef.putKeyAtLevel(rvid, vtx, key, level, batch, snapshotFrame)

  ok (key, level)

proc computeKeyImpl(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    skipLayers: static bool,
    spawnTpTasks: static bool,
    parallel: static bool,
): Result[HashKey, AristoError] =
  let (keyvtx, level) =
    when skipLayers:
      (?txRef.db.getKeyBe(rvid, {GetVtxFlag.PeekCache}), dbLevel)
    else:
      ?txRef.getKeyRc(rvid, {})

  if keyvtx[0].isValid:
    return ok(keyvtx[0])

  var batch: WriteBatch

  # Find the topmost frame holding a snapshot, if any, so that key writes can
  # patch it directly instead of searching the frame stack for every key.
  var snapshotFrame: AristoTxRef
  for frame in txRef.rstack(stopAtSnapshot = true):
    if frame.snapshot.level.isSome():
      snapshotFrame = frame
      break

  let res = computeKeyImpl(
    txRef, rvid, batch, keyvtx[1], level, skipLayers, spawnTpTasks, parallel,
    snapshotFrame, nil, nil,
  )

  if res.isOk:
    ?batch.flush(txRef.db)

    if batch.count > 0:
      when parallel:
        if batch.count >= batchSize * 10:
          info "Wrote computeKey cache",
            keys = batch.count, tasksCompleted = batch.progress(parallel)
        else:
          debug "Wrote computeKey cache",
            keys = batch.count, tasksCompleted = batch.progress(parallel)
      else:
        if batch.count >= batchSize * 10:
          info "Wrote computeKey cache", keys = batch.count, accounts = "100.00%"
        else:
          debug "Wrote computeKey cache", keys = batch.count, accounts = "100.00%"

  ok (?res)[0]

proc computeKey*(
    txRef: AristoTxRef, # Database, top layer
    rvid: RootedVertexID, # Vertex to convert
    skipLayers: static bool = false,
): Result[HashKey, AristoError] =
  ## Compute the key for an arbitrary vertex ID. If successful, the length of
  ## the resulting key might be smaller than 32. If it is used as a root vertex
  ## state/hash, it must be converted to a `Hash32` (using (`.to(Hash32)`) as
  ## in `txRef.computeKey(rvid).value.to(Hash32)` which always results in a
  ## 32 byte value.
  txRef.computeKeyImpl(rvid, skipLayers, spawnTpTasks = false, parallel = false)

proc computeStateRoot*(
    txRef: AristoTxRef, skipLayers: static bool = false
): Result[HashKey, AristoError] =
  ## Ensure that key cache is topped up with the latest state root
  ## and return the computed value.

  template computeSerial(): Result[HashKey, AristoError] =
    txRef.computeKeyImpl(
      (STATE_ROOT_VID, STATE_ROOT_VID),
      skipLayers,
      spawnTpTasks = false,
      parallel = false,
    )

  when compileOption("threads"):
    # `taskpool` only exists with threads on
    if txRef.db.parallelStateRootComputation and not txRef.db.taskpool.isNil() and
        txRef.db.taskpool.numThreads > 1:
      txRef.computeKeyImpl(
        (STATE_ROOT_VID, STATE_ROOT_VID),
        skipLayers,
        spawnTpTasks = true,
        parallel = true,
      )
    else:
      computeSerial()
  else:
    computeSerial()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
