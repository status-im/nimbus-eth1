# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  eth/common,
  results,
  "."/[aristo_desc, aristo_get, aristo_serialise],
  ./aristo_desc/desc_backend

type WriteBatch = tuple[writer: PutHdlRef, count: int, depth: int, prefix: uint64]

# Keep write batch size _around_ 1mb, give or take some overhead - this is a
# tradeoff between efficiency and memory usage with diminishing returns the
# larger it is..
const batchSize = 1024 * 1024 div (sizeof(RootedVertexID) + sizeof(HashKey))

func progress(batch: WriteBatch): string =
  # Return an approximation on how much of the keyspace has been covered by
  # looking at the path prefix that we're currently processing
  &"{(float(batch.prefix) / float(uint64.high)) * 100:02.2f}%"

func enter(batch: var WriteBatch, nibble: int) =
  batch.depth += 1
  if batch.depth <= 16:
    batch.prefix += uint64(nibble) shl ((16 - batch.depth) * 4)

func leave(batch: var WriteBatch, nibble: int) =
  if batch.depth <= 16:
    batch.prefix -= uint64(nibble) shl ((16 - batch.depth) * 4)
  batch.depth -= 1

proc putKeyAtLevel(
    db: AristoDbRef,
    rvid: RootedVertexID,
    key: HashKey,
    level: int,
    batch: var WriteBatch,
): Result[void, AristoError] =
  ## Store a hash key in the given layer or directly to the underlying database
  ## which helps ensure that memory usage is proportional to the pending change
  ## set (vertex data may have been committed to disk without computing the
  ## corresponding hash!)

  # Only put computed keys in the database which keeps churn down by focusing on
  # the ones that do not change - the ones that don't require hashing might as
  # well be loaded from the vertex!
  if level == -2:
    if key.len == 32:
      let be = db.backend
      if batch.writer == nil:
        doAssert be != nil, "source data is from the backend"
        # TODO long-running batch here?
        batch.writer = ?be.putBegFn()

      be.putKeyFn(batch.writer, rvid, key)
      batch.count += 1

      if batch.count mod batchSize == 0:
        if batch.count mod (batchSize * 100) == 0:
          info "Writing computeKey cache",
            count = batch.count, accounts = batch.progress
        else:
          debug "Writing computeKey cache",
            count = batch.count, accounts = batch.progress
        ?be.putEndFn batch.writer
        batch.writer = nil

    ok()
  else:
    db.deltaAtLevel(level).kMap[rvid] = key
    ok()

func maxLevel(cur, other: int): int =
  # Compare two levels and return the topmost in the stack, taking into account
  # the odd reversal of order around the zero point
  if cur < 0:
    max(cur, other) # >= 0 is always more topmost than <0
  elif other < 0:
    cur
  else:
    min(cur, other) # Here the order is reversed and 0 is the top layer

proc computeKeyImpl(
    db: AristoDbRef, # Database, top layer
    rvid: RootedVertexID, # Vertex to convert
    batch: var WriteBatch,
): Result[(HashKey, int), AristoError] =
  ## Compute the key for an arbitrary vertex ID. If successful, the length of
  ## the resulting key might be smaller than 32. If it is used as a root vertex
  ## state/hash, it must be converted to a `Hash32` (using (`.to(Hash32)`) as
  ## in `db.computeKey(rvid).value.to(Hash32)` which always results in a
  ## 32 byte value.

  db.getKeyRc(rvid).isErrOr:
    # Value cached either in layers or database
    return ok value

  let (vtx, vl) = ?db.getVtxRc(rvid, {GetVtxFlag.PeekCache})

  # Top-most level of all the verticies this hash compution depends on
  var level = vl

  # TODO this is the same code as when serializing NodeRef, without the NodeRef
  var writer = initRlpWriter()

  case vtx.vType
  of Leaf:
    writer.startList(2)
    writer.append(vtx.pfx.toHexPrefix(isLeaf = true).data())

    case vtx.lData.pType
    of AccountData:
      let
        stoID = vtx.lData.stoID
        skey =
          if stoID.isValid:
            let (skey, sl) = ?db.computeKeyImpl((stoID.vid, stoID.vid), batch)
            level = maxLevel(level, sl)
            skey
          else:
            VOID_HASH_KEY

      writer.append(
        encode Account(
          nonce: vtx.lData.account.nonce,
          balance: vtx.lData.account.balance,
          storageRoot: skey.to(Hash32),
          codeHash: vtx.lData.account.codeHash,
        )
      )
    of RawData:
      writer.append(vtx.lData.rawBlob)
    of StoData:
      # TODO avoid memory allocation when encoding storage data
      writer.append(rlp.encode(vtx.lData.stoData))
  of Branch:
    template writeBranch(w: var RlpWriter) =
      w.startList(17)
      for n in 0 .. 15:
        let vid = vtx.bVid[n]
        if vid.isValid:
          batch.enter(n)
          let (bkey, bl) = ?db.computeKeyImpl((rvid.root, vid), batch)
          batch.leave(n)

          level = maxLevel(level, bl)
          w.append(bkey)
        else:
          w.append(VOID_HASH_KEY)
      w.append EmptyBlob

    if vtx.pfx.len > 0: # Extension node
      var bwriter = initRlpWriter()
      writeBranch(bwriter)

      writer.startList(2)
      writer.append(vtx.pfx.toHexPrefix(isleaf = false).data())
      writer.append(bwriter.finish().digestTo(HashKey))
    else:
      writeBranch(writer)

  let h = writer.finish().digestTo(HashKey)

  # Cache the hash int the same storage layer as the the top-most value that it
  # depends on (recursively) - this could be an ephemeral in-memory layer or the
  # underlying database backend - typically, values closer to the root are more
  # likely to live in an in-memory layer since any leaf change will lead to the
  # root key also changing while leaves that have never been hashed will see
  # their hash being saved directly to the backend.
  ?db.putKeyAtLevel(rvid, h, level, batch)

  ok (h, level)

proc computeKey*(
    db: AristoDbRef, # Database, top layer
    rvid: RootedVertexID, # Vertex to convert
): Result[HashKey, AristoError] =
  var batch: WriteBatch
  let res = computeKeyImpl(db, rvid, batch)
  if res.isOk:
    if batch.writer != nil:
      if batch.count >= batchSize * 100:
        info "Writing computeKey cache", count = batch.count, progress = "100.00%"
      else:
        debug "Writing computeKey cache", count = batch.count, progress = "100.00%"
      ?db.backend.putEndFn batch.writer
      batch.writer = nil
  ok (?res)[0]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
