# nimbus-eth1
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/strformat,
  chronicles,
  eth/common/[accounts_rlp, base_rlp, hashes_rlp],
  results,
  "."/[aristo_desc, aristo_get, aristo_layers],
  ./aristo_desc/desc_backend

type WriteBatch = tuple[writer: PutHdlRef, count: int, depth: int, prefix: uint64]

# Keep write batch size _around_ 1mb, give or take some overhead - this is a
# tradeoff between efficiency and memory usage with diminishing returns the
# larger it is..
const batchSize = 1024 * 1024 div (sizeof(RootedVertexID) + sizeof(HashKey))

proc flush(batch: var WriteBatch, db: AristoDbRef): Result[void, AristoError] =
  if batch.writer != nil:
    ?db.putEndFn batch.writer
    batch.writer = nil
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
  batch.count += 1

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
    db: AristoTxRef,
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

  if level < db.db.baseTxFrame().level:
    ?batch.putVtx(db.db, rvid, vtx, key)

    if batch.count mod batchSize == 0:
      ?batch.flush(db.db)

      if batch.count mod (batchSize * 100) == 0:
        info "Writing computeKey cache", keys = batch.count, accounts = batch.progress
      else:
        debug "Writing computeKey cache", keys = batch.count, accounts = batch.progress
  else:
    db.deltaAtLevel(level).layersPutKey(rvid, vtx, key)

  ok()

template appendLeaf(w: var RlpWriter, pfx: NibblesBuf, leafData: untyped) =
  w.startList(2)
  w.append(pfx.toHexPrefix(isLeaf = true).data())
  w.wrapEncoding(1)
  w.append(leafData)

template encodeLeaf(pfx: NibblesBuf, leafData: untyped): HashKey =
  debugEcho "calling encode Leaf"
  debugEcho pfx
  debugEcho leafData
  var tracker = DynamicRlpLengthTracker()
  tracker.initLengthTracker()
  tracker.appendLeaf(pfx, leafData)

  if tracker.totalLength < 32:
    var writer = initTwoPassWriter(tracker)
    writer.appendLeaf(pfx, leafData)
    let buf = HashKey.fromBytes(writer.finish)
    debugEcho(buf)
    buf.value
  else:
    var writer = initHashWriter(tracker)
    writer.appendLeaf(pfx, leafData)
    let buf = writer.finish()
    debugEcho(buf)
    buf.to(HashKey)

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

# template appendBranch(w: var RlpWriter, vtx: VertexRef, subKeyForN: untyped) =
#   w.startList(17)
#   for (n {.inject.}, subvid {.inject.}) in vtx.allPairs():
#     w.append(subKeyForN)
#   w.append EmptyBlob
# 
# template encodeBranch(vtx: VertexRef, subKeyForN: untyped): HashKey =
#   var tracker: DynamicRlpLengthTracker
#   tracker.initLengthTracker()
#   tracker.appendBranch(vtx, subKeyForN)
# 
#   if tracker.totalLength < 32:
#     var writer = initTwoPassWriter(tracker)
#     writer.appendBranch(vtx, subKeyForN)
#     let buf = HashKey.fromBytes(writer.finish)
#     buf.value
#   else:
#     var writer = initHashWriter(tracker)
#     writer.appendBranch(vtx, subKeyForN)
#     let buf = writer.finish()
#     buf.to(HashKey)
# 
# template appendExt(w: var RlpWriter, pfx: NibblesBuf, branchKey: HashKey) =
#   w.startList(2)
#   w.append(pfx.toHexPrefix(isLeaf = false).data())
#   w.append(branchKey)
# 
# template encodeExt(pfx: NibblesBuf, branchKey: untyped): HashKey =
#   var tracker: DynamicRlpLengthTracker
#   tracker.initLengthTracker()
#   tracker.appendExt(pfx, branchKey)
# 
#   if tracker.totalLength < 32:
#     var writer = initTwoPassWriter(tracker)
#     writer.appendExt(pfx, branchKey)
#     let buf = HashKey.fromBytes(writer.finish)
#     buf.value
#   else:
#     var writer = initHashWriter(tracker)
#     writer.appendExt(pfx, branchKey)
#     let buf = writer.finish()
#     buf.to(HashKey)

proc getKey(
    db: AristoTxRef, rvid: RootedVertexID, skipLayers: static bool
): Result[((HashKey, VertexRef), int), AristoError] =
  ok when skipLayers:
    (?db.db.getKeyBe(rvid, {GetVtxFlag.PeekCache}), dbLevel)
  else:
    ?db.getKeyRc(rvid, {})

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

proc computeKeyImpl(
    db: AristoTxRef,
    rvid: RootedVertexID,
    batch: var WriteBatch,
    vtx: VertexRef,
    level: int,
    skipLayers: static bool,
): Result[(HashKey, int), AristoError] =
  # The bloom filter available used only when creating the key cache from an
  # empty state

  # Top-most level of all the verticies this hash computation depends on
  var level = level

  var writer = initRlpWriter()

  let key =
    case vtx.vType
    of AccLeaf:
      let
        vtx = AccLeafRef(vtx)
        stoID = vtx.stoID
        skey =
          if stoID.isValid:
            let
              keyvtxl = ?db.getKey((stoID.vid, stoID.vid), skipLayers)
              (skey, sl) =
                if keyvtxl[0][0].isValid:
                  (keyvtxl[0][0], keyvtxl[1])
                else:
                  ?db.computeKeyImpl(
                    (stoID.vid, stoID.vid),
                    batch,
                    keyvtxl[0][1],
                    keyvtxl[1],
                    skipLayers = skipLayers,
                  )
            level = max(level, sl)
            skey
          else:
            VOID_HASH_KEY

      encodeLeaf(vtx.pfx):
        Account(
          nonce: vtx.account.nonce,
          balance: vtx.account.balance,
          storageRoot: skey.to(Hash32),
          codeHash: vtx.account.codeHash,
        )
    of StoLeaf:
      let vtx = StoLeafRef(vtx)
      encodeLeaf(vtx.pfx):
        vtx.stoData
    of Branches:
      # For branches, we need to load the vertices before recursing into them
      # to exploit their on-disk order
      let vtx = BranchRef(vtx)
      var keyvtxs: array[16, ((HashKey, VertexRef), int)]
      for n, subvid in vtx.pairs:
        keyvtxs[n] = ?db.getKey((rvid.root, subvid), skipLayers)

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
              (keyvtx[0][0], keyvtx[1]) =
                ?db.computeKeyImpl(
                  (rvid.root, subvid),
                  batch,
                  keyvtx[0][1],
                  keyvtx[1],
                  skipLayers = skipLayers,
                )
              n += 1
              continue

            if minIdx == keyvtxs.len + 1 or childVid < minVid:
              minIdx = nibble
              minVid = childVid

          if minIdx == keyvtxs.len + 1: # no uncomputed key found!
            break keysComputed

          batch.enter(n)
          (keyvtxs[minIdx][0][0], keyvtxs[minIdx][1]) =
            ?db.computeKeyImpl(
              (rvid.root, vtx.bVid(uint8 minIdx)),
              batch,
              keyvtxs[minIdx][0][1],
              keyvtxs[minIdx][1],
              skipLayers = skipLayers,
            )
          batch.leave(n)

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
    ?db.putKeyAtLevel(rvid, BranchRef(vtx), key, level, batch)
  ok (key, level)

proc computeKeyImpl(
    db: AristoTxRef, rvid: RootedVertexID, skipLayers: static bool
): Result[HashKey, AristoError] =
  let (keyvtx, level) =
    when skipLayers:
      (?db.db.getKeyBe(rvid, {GetVtxFlag.PeekCache}), dbLevel)
    else:
      ?db.getKeyRc(rvid, {})

  if keyvtx[0].isValid:
    return ok(keyvtx[0])

  var batch: WriteBatch
  let res = computeKeyImpl(db, rvid, batch, keyvtx[1], level, skipLayers = skipLayers)
  if res.isOk:
    ?batch.flush(db.db)

    if batch.count > 0:
      if batch.count >= batchSize * 100:
        info "Wrote computeKey cache", keys = batch.count, accounts = "100.00%"
      else:
        debug "Wrote computeKey cache", keys = batch.count, accounts = "100.00%"

  ok (?res)[0]

proc computeKey*(
    db: AristoTxRef, # Database, top layer
    rvid: RootedVertexID, # Vertex to convert
): Result[HashKey, AristoError] =
  ## Compute the key for an arbitrary vertex ID. If successful, the length of
  ## the resulting key might be smaller than 32. If it is used as a root vertex
  ## state/hash, it must be converted to a `Hash32` (using (`.to(Hash32)`) as
  ## in `db.computeKey(rvid).value.to(Hash32)` which always results in a
  ## 32 byte value.
  computeKeyImpl(db, rvid, skipLayers = false)

proc computeKeys*(db: AristoTxRef, root: VertexID): Result[void, AristoError] =
  ## Ensure that key cache is topped up with the latest state root
  discard db.computeKeyImpl((root, root), skipLayers = true)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
