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
  "."/[aristo_desc, aristo_get, aristo_layers],
  ./aristo_desc/desc_backend,
  ../../concurrency/queue

export aristo_desc, chronicles, stack

type
  VertexBranch* = object
    isExt*: bool
    used*: uint16
    startVid*: VertexID
    pfx*: NibblesBuf

  WriteBatch* = object
    writer*: PutHdlRef
    count*: int
    depth*: int
    prefix*: uint64
  
  ConcurrentBuffer* = ConcurrentQueue[8, (RootedVertexID, VertexBranch, HashKey, int)]

proc `=copy`(dest: var WriteBatch; src: WriteBatch) {.error: "Copying WriteBatch is forbidden".} =
  discard

# Keep write batch size _around_ 1mb, give or take some overhead - this is a
# tradeoff between efficiency and memory usage with diminishing returns the
# larger it is..
const batchSize = 1024 * 1024 div (sizeof(RootedVertexID) + sizeof(HashKey))

proc flush(batch: var WriteBatch, txRef: AristoDbRef): Result[void, AristoError] =
  if batch.writer != nil:
    ?txRef.putEndFn batch.writer
    batch.writer = nil
  ok()

proc putVtx(
    batch: var WriteBatch,
    txRef: AristoDbRef,
    rvid: RootedVertexID,
    vtx: VertexRef,
    key: HashKey,
): Result[void, AristoError] =
  if batch.writer == nil:
    batch.writer = ?txRef.putBegFn()

  txRef.putVtxFn(batch.writer, rvid, vtx, key)
  inc batch.count

  ok()

func progress(batch: WriteBatch): string =
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

proc putKeyAtLevel(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    vtx: BranchRef,
    key: HashKey,
    level: int,
    batch: var WriteBatch,
    locksEnabled: static bool
): Result[void, AristoError] =
  ## Store a hash key in the given layer or directly to the underlying database
  ## which helps ensure that memory usage is proportional to the pending change
  ## set (vertex data may have been committed to disk without computing the
  ## corresponding hash!)

  if level >= txRef.db.baseTxFrame().level:
    let frame = txRef.deltaAtLevel(level)
    when locksEnabled:
      frame.db.lock.lockWrite()
    frame.layersPutKey(rvid, vtx, key)
    when locksEnabled:
      frame.db.lock.unlockWrite()
  elif level == dbLevel:
    ?batch.putVtx(txRef.db, rvid, vtx, key)

    if batch.count mod batchSize == 0:
      ?batch.flush(txRef.db)

      if batch.count mod (batchSize * 100) == 0:
        info "Writing computeKey cache", keys = batch.count, accounts = batch.progress
      else:
        debug "Writing computeKey cache", keys = batch.count, accounts = batch.progress
  else: # level > dbLevel but less than baseTxFrame level
    # Throw defect here because we should not be writing vertexes to the database if
    # from a lower level than the baseTxFrame level.
    raiseAssert("Cannot write keys at level < baseTxFrame level. Found level = " &
        $level & ", baseTxFrame level = " & $txRef.db.baseTxFrame().level)

  ok()

template encodeLeaf(w: var RlpWriter, pfx: NibblesBuf, leafData: untyped): HashKey =
  w.startList(2)
  w.append(pfx.toHexPrefix(isLeaf = true).data())
  w.append(leafData)
  w.finish().digestTo(HashKey)

template encodeBranch(w: var RlpWriter, vtx: VertexRef, subKeyForN: untyped): HashKey =
  w.startList(17)
  for (n {.inject.}, subvid {.inject.}) in vtx.allPairs():
    w.append(subKeyForN)
  w.append EmptyBlob
  w.finish().digestTo(HashKey)

template encodeExt(w: var RlpWriter, pfx: NibblesBuf, branchKey: HashKey): HashKey =
  w.startList(2)
  w.append(pfx.toHexPrefix(isLeaf = false).data())
  w.append(branchKey)
  w.finish().digestTo(HashKey)

proc getKey(
    txRef: AristoTxRef, rvid: RootedVertexID, skipLayers: static bool, locksEnabled: static bool
): Result[((HashKey, VertexRef), int), AristoError] =
  const 
    emptyFlags: set[GetVtxFlag] = {}
    flags = 
      when skipLayers or locksEnabled: 
        {GetVtxFlag.PeekCache} 
      else: 
        emptyFlags
  
  when not skipLayers:
    block body:
      when locksEnabled:
        txRef.db.lock.lockRead()
        defer:
          txRef.db.lock.unlockRead()
      
      let key = txRef.layersGetKey(rvid).valueOr:
        break body
      
      if key[0].isValid:
        return ok ((key[0], nil), key[1])

      let vtx = txRef.layersGetVtx(rvid).valueOr:
        return err(GetKeyNotFound)

      if vtx[0].isValid:
        return ok ((VOID_HASH_KEY, vtx[0]), vtx[1])
      else:
        return err(GetKeyNotFound)

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
    buffer: ptr ConcurrentBuffer
): Result[(HashKey, int), AristoError]

proc computeKeyImpl(
    txRef: AristoTxRef,
    rvid: RootedVertexID,
    batch: var WriteBatch,
    vtx: VertexRef,
    level: int,
    skipLayers: static bool,
    parallel: static bool,
    locksEnabled: static bool,
    buffer: ptr ConcurrentBuffer
): Result[(HashKey, int), AristoError] =
  # The bloom filter available used only when creating the key cache from an
  # empty state

  # Top-most level of all the verticies this hash computation depends on
  var level = level

  # TODO this is the same code as when serializing NodeRef, without the NodeRef
  var writer = initRlpWriter()

  let key =
    case vtx.vType
    of AccLeaf:
      let vtx = AccLeafRef(vtx)
      writer.encodeLeaf(vtx.pfx):
        let
          stoID = vtx.stoID
          skey =
            if stoID.isValid:
              let
                keyvtxl = ?txRef.getKey((stoID.vid, stoID.vid), skipLayers, locksEnabled)
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
                      parallel = false,
                      locksEnabled,
                      buffer
                    )
              level = max(level, sl)
              skey
            else:
              VOID_HASH_KEY

        rlp.encode Account(
          nonce: vtx.account.nonce,
          balance: vtx.account.balance,
          storageRoot: skey.to(Hash32),
          codeHash: vtx.account.codeHash,
        )
    of StoLeaf:
      let vtx = StoLeafRef(vtx)
      writer.encodeLeaf(vtx.pfx):
        # TODO avoid memory allocation when encoding storage data
        rlp.encode(vtx.stoData)
    of Branches:
      # For branches, we need to load the vertices before recursing into them
      # to exploit their on-disk order
      let vtx = BranchRef(vtx)
      var keyvtxs: array[16, ((HashKey, VertexRef), int)]
      for n, subvid in vtx.pairs:
        keyvtxs[n] = ?txRef.getKey((rvid.root, subvid), skipLayers, locksEnabled)

      when parallel:
        var 
          futs: array[16, Flowvar[Result[(HashKey, int), AristoError]]]
          buffers: array[16, ConcurrentBuffer]

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
            when parallel:
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
                  parallel = false,
                  locksEnabled,
                  buffer
                )
              n += 1
              continue

            if minIdx == keyvtxs.len + 1 or childVid < minVid:
              minIdx = nibble
              minVid = childVid

          if minIdx == keyvtxs.len + 1: # no uncomputed key found!
            break keysComputed


          when parallel:
            let
              vid = (rvid.root, vtx.bVid(uint8 minIdx))
              batchPtr: ptr WriteBatch = batch.addr
              vtxPtr = keyvtxs[minIdx][0][1].addr
              level = keyvtxs[minIdx][1]
            buffers[minIdx].init()
            futs[minIdx] = txRef.db.taskpool.spawn computeKeyImplTask(
              txRef.addr, vid, batchPtr, vtxPtr, level, skipLayers = skipLayers, buffers[minIdx].addr)
          else:
            #batch.enter(n)
            (keyvtxs[minIdx][0][0], keyvtxs[minIdx][1]) =
              ?txRef.computeKeyImpl(
                (rvid.root, vtx.bVid(uint8 minIdx)),
                batch,
                keyvtxs[minIdx][0][1],
                keyvtxs[minIdx][1],
                skipLayers = skipLayers,
                parallel = false,
                locksEnabled,
                buffer
              )
            #batch.leave(n)

      when parallel:
        var runningFutsIndexes: set[uint8] = {}
        for i, f in futs:
          if f.isSpawned():
            runningFutsIndexes.incl(i.uint8)
        
        while runningFutsIndexes.len() > 0:
          for i, f in futs:
            if runningFutsIndexes.contains(i.uint8):
              let v = buffers[i].tryPop().valueOr:
                # once we stop receiving data we check if the task is finished 
                # and then remove it from the set
                if f.isReady():
                  runningFutsIndexes.excl(i.uint8)
                continue
              if v[1].isExt:
                let b = ExtBranchRef.init(v[1].pfx, v[1].startVid, v[1].used)
                ?txRef.putKeyAtLevel(v[0], BranchRef(b), v[2], v[3], batch, locksEnabled)
              else:
                let b = BranchRef.init(v[1].startVid, v[1].used)
                ?txRef.putKeyAtLevel(v[0], b, v[2], v[3], batch, locksEnabled)
        
        # At this point all futures have finished running.
        # Now we process any remaining data in the buffers.
        for i, f in futs:
          if f.isSpawned():
            var data = buffers[i].tryPop()
            while data.isSome():
              let v = data.get()
              if v[1].isExt:
                let b = ExtBranchRef.init(v[1].pfx, v[1].startVid, v[1].used)
                ?txRef.putKeyAtLevel(v[0], BranchRef(b), v[2], v[3], batch, locksEnabled)
              else:
                let b = BranchRef.init(v[1].startVid, v[1].used)
                ?txRef.putKeyAtLevel(v[0], b, v[2], v[3], batch, locksEnabled)
              
              data = buffers[i].tryPop()

            (keyvtxs[i][0][0], keyvtxs[i][1]) = ?sync(f)

      template writeBranch(w: var RlpWriter, vtx: BranchRef): HashKey =
        w.encodeBranch(vtx):
          if subvid.isValid:
            level = max(level, keyvtxs[n][1])
            keyvtxs[n][0][0]
          else:
            VOID_HASH_KEY

      if vtx.vType == ExtBranch:
        let vtx = ExtBranchRef(vtx)
        writer.encodeExt(vtx.pfx):
          var bwriter = initRlpWriter()
          bwriter.writeBranch(vtx)
      else:
        writer.writeBranch(vtx)

  # Cache the hash into the same storage layer as the the top-most value that it
  # depends on (recursively) - this could be an ephemeral in-memory layer or the
  # underlying database backend - typically, values closer to the root are more
  # likely to live in an in-memory layer since any leaf change will lead to the
  # root key also changing while leaves that have never been hashed will see
  # their hash being saved directly to the backend.

  if vtx.vType in Branches:
    if buffer.isNil():
      ?txRef.putKeyAtLevel(rvid, BranchRef(vtx), key, level, batch, locksEnabled)
    else:
      if vtx.vType == ExtBranch:
        let b = ExtBranchRef(vtx)
        buffer[].push((rvid, VertexBranch(isExt: true, used: b.used, startVid: b.startVid, pfx: b.pfx), key, level))
      elif vtx.vType == Branch:
        let b = BranchRef(vtx)
        buffer[].push((rvid, VertexBranch(isExt: false, used: b.used, startVid: b.startVid), key, level))
      else:
        raiseAssert("not expected")

  ok (key, level)

proc computeKeyImplTask(
    txRef: ptr AristoTxRef,
    rvid: RootedVertexID,
    batch: ptr WriteBatch,
    vtx: ptr VertexRef,
    level: int,
    skipLayers: bool,
    buffer: ptr ConcurrentBuffer
): Result[(HashKey, int), AristoError] =
  if skipLayers:
    txRef[].computeKeyImpl(rvid, batch[], vtx[], level, skipLayers = true, parallel = false, locksEnabled = true, buffer)
  else:
    txRef[].computeKeyImpl(rvid, batch[], vtx[], level, skipLayers = false, parallel = false, locksEnabled = true, buffer)

proc computeKeyImpl(
    txRef: AristoTxRef, rvid: RootedVertexID, skipLayers: static bool, parallel: static bool, locksEnabled: static bool
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
    skipLayers = skipLayers,
    parallel = parallel,
    locksEnabled,
    nil
  )

  if res.isOk:
    ?batch.flush(txRef.db)

    if batch.count > 0:
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
  txRef.computeKeyImpl(rvid, skipLayers, parallel = false, locksEnabled = false)

proc computeStateRoot*(
    txRef: AristoTxRef,
    skipLayers: static bool = false
): Result[HashKey, AristoError] =
  ## Ensure that key cache is topped up with the latest state root
  ## and return the computed value.
  if txRef.db.parallelStateRootComputation:
    txRef.computeKeyImpl(
      (STATE_ROOT_VID, STATE_ROOT_VID),
      skipLayers,
      parallel = when compileOption("threads"): true else: false,
      locksEnabled = when compileOption("threads"): true else: false
    )
  else:
    txRef.computeKeyImpl(
      (STATE_ROOT_VID, STATE_ROOT_VID),
      skipLayers,
      parallel = false,
      locksEnabled = false
    )

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
