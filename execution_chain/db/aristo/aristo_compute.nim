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
  std/strformat,
  chronicles,
  eth/common/[accounts_rlp, base_rlp, hashes_rlp],
  results,
  ./[aristo_desc, aristo_get, aristo_layers, aristo_blobify],
  ./aristo_desc/desc_backend,
  ../../concurrency/queue

export aristo_desc, chronicles

const
  MAX_RLP_SIZE_ACCOUNT_LEAF = 111
  MAX_RLP_SIZE_STORAGE_LEAF = 34
  MAX_RLP_SIZE_ACCOUNT_LEAF_NODE = 149
  MAX_RLP_SIZE_STORAGE_LEAF_NODE = 71
  MAX_RLP_SIZE_BRANCH_NODE = 533
  MAX_RLP_SIZE_EXTENSION_NODE = 69

type
  WriteBatch* = object
    writer*: PutHdlRef
    count*: int
    depth*: int
    prefix*: uint64
    tasksCompleted*: int
    tasksTotal*: int
  
  ConcurrentHashKeyQueue* = ConcurrentQueue[3, (RootedVertexID, HashKey, int)]
  ConcurrentVertexBufQueue* = ConcurrentQueue[3, (RootedVertexID, VertexBuf)]

proc `=copy`(dest: var WriteBatch; src: WriteBatch) {.error: "Copying WriteBatch is forbidden".} =
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

template flushCheck(batch: var WriteBatch, db: AristoDbRef, parallel: static bool): Result[void, AristoError] =
  if batch.count mod batchSize == 0:
    ?batch.flush(db)
    
    when parallel:
      if batch.count mod (batchSize * 100) == 0:
        info "Writing computeKey cache", keys = batch.count, tasksCompleted = batch.progress(parallel)
      else:
        debug "Writing computeKey cache", keys = batch.count, tasksCompleted = batch.progress(parallel)
    else:
      if batch.count mod (batchSize * 100) == 0:
        info "Writing computeKey cache", keys = batch.count, accounts = batch.progress(parallel)
      else:
        debug "Writing computeKey cache", keys = batch.count, accounts = batch.progress(parallel)
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
    batch: var WriteBatch
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
    raiseAssert("Cannot write keys at level < baseTxFrame level. Found level = " &
        $level & ", baseTxFrame level = " & $txRef.db.baseTxFrame().level)

  ok()

proc mergeKeyAtLevel(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    key: HashKey,
    level: int) =
  doAssert level >= txRef.db.baseTxFrame().level

  let frame = txRef.deltaAtLevel(level)
  withWriteLock(frame.lock):
    frame.layersMergeKey(rvid, key)

proc putVtxBlob(
    batch: var WriteBatch,
    db: AristoDbRef,
    rvid: RootedVertexID,
    vtx: openArray[byte],
): Result[void, AristoError] =
  if batch.writer == nil:
    batch.writer = ?db.putBegFn()

  db.putVtxBlobFn(batch.writer, rvid, vtx)
  inc batch.count
  ?batch.flushCheck(db, parallel = true)

  ok()

template encodeLeaf(w: var RlpWriter, pfx: NibblesBuf, leafData: untyped): HashKey =
  w.startList(2)
  w.append(pfx.toHexPrefix(isLeaf = true).data())
  w.append(leafData)
  w.finish(asOpenArray = true).digestTo(HashKey)

template encodeBranch(w: var RlpWriter, vtx: VertexRef, subKeyForN: untyped): HashKey =
  w.startList(17)
  for (n {.inject.}, subvid {.inject.}) in vtx.allPairs():
    w.append(subKeyForN)
  w.append EmptyBlob
  w.finish(asOpenArray = true).digestTo(HashKey)

template encodeExt(w: var RlpWriter, pfx: NibblesBuf, branchKey: HashKey): HashKey =
  w.startList(2)
  w.append(pfx.toHexPrefix(isLeaf = false).data())
  w.append(branchKey)
  w.finish(asOpenArray = true).digestTo(HashKey)

func layersGetKeyOrVtx*(
    db: AristoTxRef,
    rvid: RootedVertexID,
    parallel: static bool): Opt[((HashKey, VertexRef), int)] =

  for w in db.rstack(stopAtSnapshot = true):
    if w.snapshot.level.isSome():
      when parallel:
        w.lock.lockRead()
        defer:
          w.lock.unlockRead()

      w.snapshot.vtx.withValue(rvid, item):
        return Opt.some(((item[][1], item[][0]), item[][2]))
      break

    when parallel:
      w.lock.lockRead()
      defer:
        w.lock.unlockRead()

    w.kMap.withValue(rvid, item):
      return ok(((item[], nil), w.level))
    w.sTab.withValue(rvid, item):
      return Opt.some(((VOID_HASH_KEY, item[]), w.level))

  Opt.none(((HashKey, VertexRef), int))

proc getKey(
    txRef: AristoTxRef, rvid: RootedVertexID, skipLayers: static bool, parallel: static bool
): Result[((HashKey, VertexRef), int), AristoError] =
  const 
    emptyFlags: set[GetVtxFlag] = {}
    flags = 
      when parallel:
        {GetVtxFlag.PeekCache, GetVtxFlag.NoPutCache} 
      else:
        when skipLayers:
          {GetVtxFlag.PeekCache} 
        else: 
          emptyFlags  
  
  when not skipLayers:
    let keyVtxRes = txRef.layersGetKeyOrVtx(rvid, parallel)
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
  of StoLeaf:
    default(VertexID)

proc computeKeyImplTask(
    txRef: ptr AristoTxRef,
    rvid: RootedVertexID,
    batch: ptr WriteBatch,
    vtx: ptr VertexRef,
    level: int,
    skipLayers: bool,
    keyQueue: ptr ConcurrentHashKeyQueue,
    vtxBufQueue: ptr ConcurrentVertexBufQueue
): Result[(HashKey, int), AristoError]

proc computeKeyImpl(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    batch: var WriteBatch,
    vtx: VertexRef,
    level: int,
    skipLayers: static bool,
    spawnTpTasks: static bool,
    parallel: static bool,
    keyQueue: ptr ConcurrentHashKeyQueue,
    vtxBufQueue: ptr ConcurrentVertexBufQueue
): Result[(HashKey, int), AristoError] =
  # The bloom filter available used only when creating the key cache from an
  # empty state

  # Top-most level of all the verticies this hash computation depends on
  var level = level

  # TODO this is the same code as when serializing NodeRef, without the NodeRef
  
  let key =
    case vtx.vType
    of AccLeaf:
      let vtx = AccLeafRef(vtx)
      var writer = RlpArrayBufWriter[MAX_RLP_SIZE_ACCOUNT_LEAF_NODE, 1]()
      writer.encodeLeaf(vtx.pfx):
        let
          stoID = vtx.stoID
          skey =
            if stoID.isValid:
              let
                keyvtxl = ?txRef.getKey((stoID.vid, stoID.vid), skipLayers, parallel)
                (skey, sl) =
                  if keyvtxl[0][0].isValid:
                    (keyvtxl[0][0], keyvtxl[1])
                  else:
                    ?txRef.computeKeyImpl(
                      (stoID.vid, stoID.vid),
                      batch,
                      keyvtxl[0][1],
                      keyvtxl[1],
                      skipLayers = skipLayers,
                      spawnTpTasks = false,
                      parallel,
                      keyQueue,
                      vtxBufQueue
                    )
              level = max(level, sl)
              skey
            else:
              VOID_HASH_KEY

        var w = RlpArrayBufWriter[MAX_RLP_SIZE_ACCOUNT_LEAF, 1]()
        w.append(Account(
          nonce: vtx.account.nonce,
          balance: vtx.account.balance,
          storageRoot: skey.to(Hash32),
          codeHash: vtx.account.codeHash
        ))
        w.finish(asOpenArray = true)
    of StoLeaf:
      let vtx = StoLeafRef(vtx)
      var writer = RlpArrayBufWriter[MAX_RLP_SIZE_STORAGE_LEAF_NODE, 1]()
      writer.encodeLeaf(vtx.pfx):
        var w = RlpArrayBufWriter[MAX_RLP_SIZE_STORAGE_LEAF, 1]()
        w.append(vtx.stoData)
        w.finish(asOpenArray = true)
    of Branches:
      # For branches, we need to load the vertices before recursing into them
      # to exploit their on-disk order
      let vtx = BranchRef(vtx)
      var keyvtxs: array[16, ((HashKey, VertexRef), int)]
      for n, subvid in vtx.pairs:
        keyvtxs[n] = ?txRef.getKey((rvid.root, subvid), skipLayers, parallel)

      when spawnTpTasks:
        var 
          futs: array[16, Flowvar[Result[(HashKey, int), AristoError]]]
          keyQueues: array[16, ConcurrentHashKeyQueue]
          vtxBufQueues: array[16, ConcurrentVertexBufQueue]

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
              (keyvtx[0][0], keyvtx[1]) =
                ?txRef.computeKeyImpl(
                  (rvid.root, subvid),
                  batch,
                  keyvtx[0][1],
                  keyvtx[1],
                  skipLayers = skipLayers,
                  spawnTpTasks = false,
                  parallel,
                  keyQueue,
                  vtxBufQueue
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

            keyQueues[minIdx].init()
            vtxBufQueues[minIdx].init()
            futs[minIdx] = txRef.db.taskpool.spawn computeKeyImplTask(
              txRef.addr, vid, batchPtr, vtxPtr, level, skipLayers, 
              keyQueues[minIdx].addr, vtxBufQueues[minIdx].addr)
            inc batch.tasksTotal

          else:
            when not parallel:
              batch.enter(n)
            (keyvtxs[minIdx][0][0], keyvtxs[minIdx][1]) =
              ?txRef.computeKeyImpl(
                (rvid.root, vtx.bVid(uint8 minIdx)),
                batch,
                keyvtxs[minIdx][0][1],
                keyvtxs[minIdx][1],
                skipLayers,
                spawnTpTasks = false,
                parallel,
                keyQueue,
                vtxBufQueue
              )
            when not parallel:
              batch.leave(n)

      when spawnTpTasks:
        var runningFutsIndexes: set[uint8] = {}
        for i, f in futs:
          if f.isSpawned() and not f.isReady():
            runningFutsIndexes.incl(i.uint8)
        
        while runningFutsIndexes.len() > 0:
          var indexesToRemove: seq[uint8]
          
          for i in runningFutsIndexes:
            if futs[i].isReady():
              indexesToRemove.add(i)
              inc batch.tasksCompleted
              continue

            when not skipLayers:
              if not keyQueues[i].isEmpty():
                var k: (RootedVertexID, HashKey, int)
                if keyQueues[i].tryPop(k):
                  txRef.mergeKeyAtLevel(k[0], k[1], k[2])
                
            if not vtxBufQueues[i].isEmpty():
              var v: (RootedVertexID, VertexBuf)
              if vtxBufQueues[i].tryPop(v):
                ?batch.putVtxBlob(txRef.db, v[0], v[1].data())

          for i in indexesToRemove:
            runningFutsIndexes.excl(i)

        # At this point all futures have finished running.
        # Now we process any remaining data in the queues.
        for i, f in futs:
          if f.isSpawned():
            when not skipLayers:
              if not keyQueues[i].isEmpty():
                var k: (RootedVertexID, HashKey, int)
                while keyQueues[i].tryPop(k):
                  txRef.mergeKeyAtLevel(k[0], k[1], k[2])

            if not vtxBufQueues[i].isEmpty():
              var v: (RootedVertexID, VertexBuf)
              while vtxBufQueues[i].tryPop(v):
                ?batch.putVtxBlob(txRef.db, v[0], v[1].data())

            (keyvtxs[i][0][0], keyvtxs[i][1]) = ?sync(f)
            keyQueues[i].dispose()
            vtxBufQueues[i].dispose()

      template writeBranch(w: var RlpWriter, vtx: BranchRef): HashKey =
        w.encodeBranch(vtx):
          if subvid.isValid:
            level = max(level, keyvtxs[n][1])
            keyvtxs[n][0][0]
          else:
            VOID_HASH_KEY

      if vtx.vType == ExtBranch:
        let vtx = ExtBranchRef(vtx)
        var writer = RlpArrayBufWriter[MAX_RLP_SIZE_EXTENSION_NODE, 1]()
        writer.encodeExt(vtx.pfx):
          var bwriter = RlpArrayBufWriter[MAX_RLP_SIZE_BRANCH_NODE, 1]()
          bwriter.writeBranch(vtx)
      else:
        var writer = RlpArrayBufWriter[MAX_RLP_SIZE_BRANCH_NODE, 1]()
        writer.writeBranch(vtx)

  # Cache the hash into the same storage layer as the the top-most value that it
  # depends on (recursively) - this could be an ephemeral in-memory layer or the
  # underlying database backend - typically, values closer to the root are more
  # likely to live in an in-memory layer since any leaf change will lead to the
  # root key also changing while leaves that have never been hashed will see
  # their hash being saved directly to the backend.

  if vtx.vType in Branches:      
    when parallel and not spawnTpTasks:
      if level >= txRef.db.baseTxFrame().level:
        keyQueue[].push((rvid, key, level))
      elif level == dbLevel:
        var vtxBuf: VertexBuf
        vtx.blobifyTo(key, vtxBuf)
        vtxBufQueue[].push((rvid, vtxBuf))
      else:
        raiseAssert("Cannot write keys at level < baseTxFrame level. Found level = " &
          $level & ", baseTxFrame level = " & $txRef.db.baseTxFrame().level)
    else:
      ?txRef.putKeyAtLevel(rvid, BranchRef(vtx), key, level, batch)

  ok (key, level)

proc computeKeyImplTask(
    txRef: ptr AristoTxRef,
    rvid: RootedVertexID,
    batch: ptr WriteBatch,
    vtx: ptr VertexRef,
    level: int,
    skipLayers: bool,
    keyQueue: ptr ConcurrentHashKeyQueue,
    vtxBufQueue: ptr ConcurrentVertexBufQueue
): Result[(HashKey, int), AristoError] =
  if skipLayers:
    txRef[].computeKeyImpl(rvid, batch[], vtx[], level, skipLayers = true, 
        spawnTpTasks = false, parallel = true, keyQueue, vtxBufQueue)
  else:
    txRef[].computeKeyImpl(rvid, batch[], vtx[], level, skipLayers = false, 
        spawnTpTasks = false, parallel = true, keyQueue, vtxBufQueue)

proc computeKeyImpl(
    txRef: AristoTxRef, 
    rvid: RootedVertexID, 
    skipLayers: static bool, 
    spawnTpTasks: static bool, 
    parallel: static bool
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
    txRef,
    rvid,
    batch,
    keyvtx[1],
    level,
    skipLayers,
    spawnTpTasks,
    parallel,
    nil,
    nil
  )

  if res.isOk:
    ?batch.flush(txRef.db)

    if batch.count > 0:
      when parallel:
        if batch.count >= batchSize * 100:
          info "Wrote computeKey cache", keys = batch.count, tasksCompleted = batch.progress(parallel)
        else:
          debug "Wrote computeKey cache", keys = batch.count, tasksCompleted = batch.progress(parallel)
      else:
        if batch.count >= batchSize * 100:
          info "Wrote computeKey cache", keys = batch.count, accounts = "100.00%"
        else:
          debug "Wrote computeKey cache", keys = batch.count, accounts = "100.00%"

  ok (?res)[0]

proc computeKey*(
    txRef: AristoTxRef, # Database, top layer
    rvid: RootedVertexID, # Vertex to convert
    skipLayers: static bool = false
): Result[HashKey, AristoError] =
  ## Compute the key for an arbitrary vertex ID. If successful, the length of
  ## the resulting key might be smaller than 32. If it is used as a root vertex
  ## state/hash, it must be converted to a `Hash32` (using (`.to(Hash32)`) as
  ## in `txRef.computeKey(rvid).value.to(Hash32)` which always results in a
  ## 32 byte value.
  txRef.computeKeyImpl(rvid, skipLayers, spawnTpTasks = false, parallel = false)

proc computeStateRoot*(
    txRef: AristoTxRef,
    skipLayers: static bool = false
): Result[HashKey, AristoError] =
  ## Ensure that key cache is topped up with the latest state root
  ## and return the computed value.
  if txRef.db.parallelStateRootComputation and txRef.db.taskpool != nil and txRef.db.taskpool.numThreads > 1:
    txRef.computeKeyImpl(
      (STATE_ROOT_VID, STATE_ROOT_VID),
      skipLayers,
      spawnTpTasks = when compileOption("threads"): true else: false,
      parallel = when compileOption("threads"): true else: false
    )
  else:
    txRef.computeKeyImpl(
      (STATE_ROOT_VID, STATE_ROOT_VID),
      skipLayers,
      spawnTpTasks = false,
      parallel = false
    )

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
