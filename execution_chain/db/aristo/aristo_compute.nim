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
  std/[algorithm, atomics, strformat],
  chronicles,
  results,
  eth/common/hashes_rlp,
  ./[aristo_desc, aristo_get, aristo_layers, aristo_blobify, aristo_serialise],
  ./aristo_desc/desc_backend,
  ../../concurrency/[queue, shared_types]

export aristo_desc, atomics, chronicles, hashes_rlp, shared_types

type
  WriteBatch* = object
    writer*: PutHdlRef
    count*: int
    depth*: int
    prefix*: uint64
    tasksCompleted*: int
    tasksTotal*: int

  ConcurrentVertexBufQueue* = ConcurrentQueue[3, (RootedVertexID, VertexBuf)]

  KeyWriteBuf* = SharedSeq[(RootedVertexID, HashKey, int)]

  KeyVtxLevel = ((HashKey, VertexRef), int)

  WorkItem* = object
    rvid: RootedVertexID
    slot: ptr KeyVtxLevel
    sortVid: VertexID

proc `=copy`(
    dest: var WriteBatch, src: WriteBatch
) {.error: "Copying WriteBatch is forbidden".} =
  discard

# Keep write batch size _around_ 1mb, give or take some overhead - this is a
# tradeoff between efficiency and memory usage with diminishing returns the
# larger it is..
const batchSize = 1024 * 1024 div (sizeof(RootedVertexID) + sizeof(HashKey))

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
      if batch.count mod (batchSize * 100) == 0:
        info "Writing computeKey cache",
          keys = batch.count, tasksCompleted = batch.progress(parallel)
      else:
        debug "Writing computeKey cache",
          keys = batch.count, tasksCompleted = batch.progress(parallel)
    else:
      if batch.count mod (batchSize * 100) == 0:
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
    vtx: BranchRef,
    key: HashKey,
    level: int,
    batch: var WriteBatch,
): Result[void, AristoError] =
  ## Store a hash key in the given layer or directly to the underlying database
  ## which helps ensure that memory usage is proportional to the pending change
  ## set (vertex data may have been committed to disk without computing the
  ## corresponding hash!)

  if level >= txRef.db.baseTxFrame().level:
    let frame = txRef.deltaAtLevel(level)
    frame.layersMergeKey(rvid, key)
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
  of BoundaryNode, StoLeaf:
    default(VertexID)

proc branchKeyFrom(
    vtx: BranchRef, keyvtxs: var array[16, KeyVtxLevel], level: var int
): HashKey =
  template subKeyForN(): untyped =
    if subvid.isValid:
      level = max(level, keyvtxs[n][1])
      keyvtxs[n][0][0]
    else:
      VOID_HASH_KEY

  if vtx.vType == ExtBranch:
    let brKey = rlpEncodeBranch(vtx, subKeyForN()).digestTo(HashKey)
    rlpEncodeExt(ExtBranchRef(vtx).pfx, brKey).digestTo(HashKey)
  else:
    rlpEncodeBranch(vtx, subKeyForN()).digestTo(HashKey)

proc computeKeyImpl(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    batch: var WriteBatch,
    vtx: VertexRef,
    level: int,
    skipLayers: static bool,
    spawnTpTasks: static bool,
    parallel: static bool,
    keyBuf: ptr KeyWriteBuf,
    vtxBufQueue: ptr ConcurrentVertexBufQueue,
): Result[(HashKey, int), AristoError]

when compileOption("threads"):
  when defined(windows):
    import std/os

    proc idleSleep() =
      sleep(1)

  else:
    import std/posix

    proc idleSleep() =
      var req = Timespec(tv_sec: posix.Time(0), tv_nsec: 100_000)
      discard nanosleep(req, req)

  proc mergeKeys(txRef: AristoTxRef, bufs: openArray[KeyWriteBuf]) =
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
        let level = item[2]

        doAssert level >= baseLevel and level <= txRef.level,
          "Cannot write keys at level < baseTxFrame level. Found level = " &
            $level & ", baseTxFrame level = " & $baseLevel

        inc counts[level - baseLevel]

    for i, count in counts:
      if count > 0:
        frames[i].layersReserveKeys(count)

    for buf in bufs:
      for item in buf:
        frames[item[2] - baseLevel].layersMergeKey(item[0], item[1])

  proc putVtxBlob(
      batch: var WriteBatch, db: AristoDbRef, rvid: RootedVertexID, vtx: openArray[byte]
  ): Result[void, AristoError] =
    if batch.writer == nil:
      batch.writer = ?db.putBegFn()

    db.putVtxBlobFn(batch.writer, rvid, vtx)
    inc batch.count
    ?batch.flushCheck(db, parallel = true)

    ok()

  func itemCmp(a, b: WorkItem): int =
    cmp(a.sortVid.uint64, b.sortVid.uint64)

  proc computeItemsTask(
      txRef: ptr AristoTxRef,
      items: ptr UncheckedArray[WorkItem],
      numItems: int,
      nextItem: ptr Atomic[int],
      skipLayers: bool,
      keyBuf: ptr KeyWriteBuf,
      vtxBufQueue: ptr ConcurrentVertexBufQueue,
  ): Result[void, AristoError] =
    var batch: WriteBatch

    while true:
      let idx = nextItem[].fetchAdd(1)
      if idx >= numItems:
        return ok()

      let item = items[idx]
      let res =
        if skipLayers:
          txRef[].computeKeyImpl(
            item.rvid,
            batch,
            item.slot[][0][1],
            item.slot[][1],
            skipLayers = true,
            spawnTpTasks = false,
            parallel = true,
            keyBuf,
            vtxBufQueue,
          )
        else:
          txRef[].computeKeyImpl(
            item.rvid,
            batch,
            item.slot[][0][1],
            item.slot[][1],
            skipLayers = false,
            spawnTpTasks = false,
            parallel = true,
            keyBuf,
            vtxBufQueue,
          )

      if res.isErr():
        return err(res.error())

      item.slot[][0][0] = res[][0]
      item.slot[][1] = res[][1]

proc computeKeyImpl(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    batch: var WriteBatch,
    vtx: VertexRef,
    level: int,
    skipLayers: static bool,
    spawnTpTasks: static bool,
    parallel: static bool,
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
    of Branches:
      # For branches, we need to load the vertices before recursing into them
      # to exploit their on-disk order
      let vtx = BranchRef(vtx)
      var keyvtxs: array[16, ((HashKey, VertexRef), int)]
      for n, subvid in vtx.pairs:
        keyvtxs[n] = ?txRef.getKey((rvid.root, subvid), skipLayers, parallel)

      when spawnTpTasks:
        const maxTasks = 32

        var
          gkeyvtxs: array[16, array[16, KeyVtxLevel]]
          expanded: set[uint8]
          items: seq[WorkItem]

        for n, subvid in vtx.pairs:
          if keyvtxs[n][0][0].isValid:
            continue

          let cvtx = keyvtxs[n][0][1]
          if cvtx.vType in Branches:
            expanded.incl(n)
            for g, gsubvid in BranchRef(cvtx).pairs:
              gkeyvtxs[n][g] = ?txRef.getKey((rvid.root, gsubvid), skipLayers, parallel)
              if not gkeyvtxs[n][g][0][0].isValid:
                items.add WorkItem(
                  rvid: (rvid.root, gsubvid),
                  slot: gkeyvtxs[n][g].addr,
                  sortVid: gkeyvtxs[n][g][0][1].childVid,
                )
          else:
            items.add WorkItem(
              rvid: (rvid.root, subvid), slot: keyvtxs[n].addr, sortVid: cvtx.childVid
            )

        items.sort(itemCmp)

        var
          futs: array[maxTasks, Flowvar[Result[void, AristoError]]]
          keyBufs: array[maxTasks, KeyWriteBuf]
          vtxBufQueues: array[maxTasks, ConcurrentVertexBufQueue]
          nextItem: Atomic[int]

        defer:
          for buf in keyBufs.mitems:
            buf.dispose()

        let numTasks = min(items.len, min(txRef.db.taskpool.numThreads, maxTasks))
        if numTasks > 0:
          let itemsPtr = cast[ptr UncheckedArray[WorkItem]](items[0].addr)
          for t in 0 ..< numTasks:
            vtxBufQueues[t].init()
            futs[t] = txRef.db.taskpool.spawn computeItemsTask(
              txRef.addr,
              itemsPtr,
              items.len,
              nextItem.addr,
              skipLayers,
              keyBufs[t].addr,
              vtxBufQueues[t].addr,
            )
            inc batch.tasksTotal
      else:
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
          elif idleRounds < 64:
            inc idleRounds
            cpuRelax()
          else:
            idleSleep()

        # At this point all futures have finished running.
        # Now we process any remaining data in the queues.
        for i, f in futs:
          if f.isSpawned():
            if not vtxBufQueues[i].isEmpty():
              var v: (RootedVertexID, VertexBuf)
              while vtxBufQueues[i].tryPop(v):
                ?batch.putVtxBlob(txRef.db, v[0], v[1].data())

            ?sync(f)
            vtxBufQueues[i].dispose()

        txRef.mergeKeys(keyBufs)

        for n in expanded:
          var clevel = keyvtxs[n][1]
          let cbr = BranchRef(keyvtxs[n][0][1])
          keyvtxs[n][0][0] = cbr.branchKeyFrom(gkeyvtxs[n], clevel)
          keyvtxs[n][1] = clevel
          ?txRef.putKeyAtLevel(
            (rvid.root, vtx.bVid(n)), cbr, keyvtxs[n][0][0], clevel, batch
          )

      vtx.branchKeyFrom(keyvtxs, level)

  # Cache the hash into the same storage layer as the the top-most value that it
  # depends on (recursively) - this could be an ephemeral in-memory layer or the
  # underlying database backend - typically, values closer to the root are more
  # likely to live in an in-memory layer since any leaf change will lead to the
  # root key also changing while leaves that have never been hashed will see
  # their hash being saved directly to the backend.

  if vtx.vType in Branches:
    when parallel and not spawnTpTasks:
      if level >= txRef.db.baseTxFrame().level:
        keyBuf[].add((rvid, key, level))
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
      ?txRef.putKeyAtLevel(rvid, BranchRef(vtx), key, level, batch)

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
  let res = computeKeyImpl(
    txRef, rvid, batch, keyvtx[1], level, skipLayers, spawnTpTasks, parallel, nil, nil
  )

  if res.isOk:
    ?batch.flush(txRef.db)

    if batch.count > 0:
      when parallel:
        if batch.count >= batchSize * 100:
          info "Wrote computeKey cache",
            keys = batch.count, tasksCompleted = batch.progress(parallel)
        else:
          debug "Wrote computeKey cache",
            keys = batch.count, tasksCompleted = batch.progress(parallel)
      else:
        if batch.count >= batchSize * 100:
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
