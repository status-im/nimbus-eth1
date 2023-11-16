# Nimbus
# Copyright (c) 2021-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles,
  metrics,
  eth/db/kvstore,
  eth/db/kvstore_sqlite3,
  stint,
  stew/results,
  ./network/state/state_content,
  "."/network/wire/[portal_protocol, portal_protocol_config]

export kvstore_sqlite3

# This version of content db is the most basic, simple solution where data is
# stored no matter what content type or content network in the same kvstore with
# the content id as key. The content id is derived from the content key, and the
# deriviation is different depending on the content type. As we use content id,
# this part is currently out of the scope / API of the ContentDB.
# In the future it is likely that that either:
# 1. More kvstores are added per network, and thus depending on the network a
# different kvstore needs to be selected.
# 2. Or more kvstores are added per network and per content type, and thus
# content key fields are required to access the data.
# 3. Or databases are created per network (and kvstores pre content type) and
# thus depending on the network the right db needs to be selected.

declareCounter portal_pruning_counter,
  "Number of pruning events which occured during the node's uptime",
  labels = ["protocol_id"]

declareGauge portal_pruning_deleted_elements,
  "Number of elements deleted in the last pruning",
  labels = ["protocol_id"]

const
  contentDeletionFraction = 0.05 ## 5% of the content will be deleted when the
  ## storage capacity is hit and radius gets adjusted.

type
  RowInfo = tuple
    contentId: array[32, byte]
    payloadLength: int64
    distance: array[32, byte]

  ContentDB* = ref object
    kv: KvStoreRef
    storageCapacity*: uint64
    sizeStmt: SqliteStmt[NoParams, int64]
    unusedSizeStmt: SqliteStmt[NoParams, int64]
    vacuumStmt: SqliteStmt[NoParams, void]
    contentCountStmt: SqliteStmt[NoParams, int64]
    contentSizeStmt: SqliteStmt[NoParams, int64]
    getAllOrderedByDistanceStmt: SqliteStmt[array[32, byte], RowInfo]

  PutResultType* = enum
    ContentStored, DbPruned

  PutResult* = object
    case kind*: PutResultType
    of ContentStored:
      discard
    of DbPruned:
      distanceOfFurthestElement*: UInt256
      deletedFraction*: float64
      deletedElements*: int64

func xorDistance(
  a: openArray[byte],
  b: openArray[byte]
): Result[seq[byte], cstring] {.cdecl.} =
  var s: seq[byte] = newSeq[byte](32)

  if len(a) != 32 or len(b) != 32:
    return err("Blobs should have 32 byte length")

  var i = 0
  while i < 32:
    s[i] = a[i] xor b[i]
    inc i

  return ok(s)

template expectDb(x: auto): untyped =
  # There's no meaningful error handling implemented for a corrupt database or
  # full disk - this requires manual intervention, so we'll panic for now
  x.expect("working database (disk broken/full?)")

proc new*(
    T: type ContentDB, path: string, storageCapacity: uint64, inMemory = false):
    ContentDB =
  doAssert(storageCapacity <= uint64(int64.high))

  let db =
    if inMemory:
      SqStoreRef.init("", "fluffy-test", inMemory = true).expect(
        "working database (out of memory?)")
    else:
      SqStoreRef.init(path, "fluffy").expectDb()

  db.registerCustomScalarFunction("xorDistance", xorDistance)
    .expect("Couldn't register custom xor function")

  let sizeStmt = db.prepareStmt(
    "SELECT page_count * page_size as size FROM pragma_page_count(), pragma_page_size();",
    NoParams, int64).get()

  let unusedSizeStmt = db.prepareStmt(
    "SELECT freelist_count * page_size as size FROM pragma_freelist_count(), pragma_page_size();",
    NoParams, int64).get()

  let vacuumStmt = db.prepareStmt(
    "VACUUM;",
    NoParams, void).get()

  let kvStore = kvStore db.openKvStore().expectDb()

  let contentSizeStmt = db.prepareStmt(
    "SELECT SUM(length(value)) FROM kvstore",
    NoParams, int64).get()

  let contentCountStmt = db.prepareStmt(
    "SELECT COUNT(key) FROM kvstore;",
    NoParams, int64).get()

  let getAllOrderedByDistanceStmt = db.prepareStmt(
    "SELECT key, length(value), xorDistance(?, key) as distance FROM kvstore ORDER BY distance DESC",
    array[32, byte], RowInfo).get()

  ContentDB(
    kv: kvStore,
    storageCapacity: storageCapacity,
    sizeStmt: sizeStmt,
    unusedSizeStmt: unusedSizeStmt,
    vacuumStmt: vacuumStmt,
    contentSizeStmt: contentSizeStmt,
    contentCountStmt: contentCountStmt,
    getAllOrderedByDistanceStmt: getAllOrderedByDistanceStmt
  )

## Private KvStoreRef Calls

proc get(kv: KvStoreRef, key: openArray[byte]): Opt[seq[byte]] =
  var res: Opt[seq[byte]]
  proc onData(data: openArray[byte]) = res = Opt.some(@data)

  discard kv.get(key, onData).expectDb()

  return res

proc getSszDecoded(kv: KvStoreRef, key: openArray[byte], T: type auto): Opt[T] =
  let res = kv.get(key)
  if res.isSome():
    try:
      Opt.some(SSZ.decode(res.get(), T))
    except SerializationError:
      raiseAssert("Stored data should always be serialized correctly")
  else:
    Opt.none(T)

## Private ContentDB calls

proc get(db: ContentDB, key: openArray[byte]): Opt[seq[byte]] =
  db.kv.get(key)

proc put(db: ContentDB, key, value: openArray[byte]) =
  db.kv.put(key, value).expectDb()

proc contains(db: ContentDB, key: openArray[byte]): bool =
  db.kv.contains(key).expectDb()

proc del(db: ContentDB, key: openArray[byte]) =
  # TODO: Do we want to return the bool here too?
  discard db.kv.del(key).expectDb()

proc getSszDecoded(
    db: ContentDB, key: openArray[byte], T: type auto): Opt[T] =
  db.kv.getSszDecoded(key, T)

## Public ContentId based ContentDB calls

# TODO: Could also decide to use the ContentKey SSZ bytestring, as this is what
# gets send over the network in requests, but that would be a bigger key. Or the
# same hashing could be done on it here.
# However ContentId itself is already derived through different digests
# depending on the content type, and this ContentId typically needs to be
# checked with the Radius/distance of the node anyhow. So lets see how we end up
# using this mostly in the code.

proc get*(db: ContentDB, key: ContentId): Opt[seq[byte]] =
  # TODO: Here it is unfortunate that ContentId is a uint256 instead of Digest256.
  db.get(key.toBytesBE())

proc put*(db: ContentDB, key: ContentId, value: openArray[byte]) =
  db.put(key.toBytesBE(), value)

proc contains*(db: ContentDB, key: ContentId): bool =
  db.contains(key.toBytesBE())

proc del*(db: ContentDB, key: ContentId) =
  db.del(key.toBytesBE())

proc getSszDecoded*(db: ContentDB, key: ContentId, T: type auto): Opt[T] =
  db.getSszDecoded(key.toBytesBE(), T)

## Public database size, content and pruning related calls

proc reclaimSpace*(db: ContentDB): void =
  ## Runs sqlite VACUUM commands which rebuilds the db, repacking it into a
  ## minimal amount of disk space.
  ## Ideal mode of operation, is to run it after several deletes.
  ## Another option would be to run 'PRAGMA auto_vacuum = FULL;' statement at
  ## the start of db to leave it up to sqlite to clean up
  db.vacuumStmt.exec().expectDb()

proc size*(db: ContentDB): int64 =
  ## Return current size of DB as product of sqlite page_count and page_size:
  ## https://www.sqlite.org/pragma.html#pragma_page_count
  ## https://www.sqlite.org/pragma.html#pragma_page_size
  ## It returns the total size of db on the disk, i.e both data and metadata
  ## used to store content.
  ## It is worth noting that when deleting content, the size may lag behind due
  ## to the way how deleting works in sqlite.
  ## Good description can be found in: https://www.sqlite.org/lang_vacuum.html
  var size: int64 = 0
  discard (db.sizeStmt.exec do(res: int64):
    size = res).expectDb()
  return size

proc unusedSize(db: ContentDB): int64 =
  ## Returns the total size of the pages which are unused by the database,
  ## i.e they can be re-used for new content.
  var size: int64 = 0
  discard (db.unusedSizeStmt.exec do(res: int64):
    size = res).expectDb()
  return size

proc usedSize*(db: ContentDB): int64 =
  ## Returns the total size of the database (data + metadata) minus the unused
  ## pages.
  db.size() - db.unusedSize()

proc contentSize*(db: ContentDB): int64 =
  ## Returns total size of the content stored in DB.
  var size: int64 = 0
  discard (db.contentSizeStmt.exec do(res: int64):
    size = res).expectDb()
  return size

proc contentCount*(db: ContentDB): int64 =
  var count: int64 = 0
  discard (db.contentCountStmt.exec do(res: int64):
    count = res).expectDb()
  return count

proc deleteContentFraction*(
  db: ContentDB,
  target: UInt256,
  fraction: float64): (UInt256, int64, int64, int64) =
  ## Deletes at most `fraction` percent of content form database.
  ## Content furthest from provided `target` is deleted first.
  # TODO: The usage of `db.contentSize()` for the deletion calculation versus
  # `db.usedSize()` for the pruning threshold leads sometimes to some unexpected
  # results of how much content gets up deleted.
  doAssert(
    fraction > 0 and fraction < 1,
    "Deleted fraction should be > 0 and < 1"
  )

  let totalContentSize = db.contentSize()
  let bytesToDelete = int64(fraction * float64(totalContentSize))
  var deletedElements: int64 = 0

  var ri: RowInfo
  var deletedBytes: int64 = 0
  let targetBytes = target.toBytesBE()
  for e in db.getAllOrderedByDistanceStmt.exec(targetBytes, ri):
    if deletedBytes + ri.payloadLength <= bytesToDelete:
      db.del(ri.contentId)
      deletedBytes = deletedBytes + ri.payloadLength
      inc deletedElements
    else:
      return (
        UInt256.fromBytesBE(ri.distance),
        deletedBytes,
        totalContentSize,
        deletedElements
      )

proc put*(
    db: ContentDB,
    key: ContentId,
    value: openArray[byte],
    target: UInt256): PutResult =
  db.put(key, value)

  # The used size is used as pruning threshold. This means that the database
  # size will reach the size specified in db.storageCapacity and will stay
  # around that size throughout the node's lifetime, as after content deletion
  # due to pruning, the free pages will be re-used.
  # TODO:
  # 1. Devise vacuum strategy - after few pruning cycles database can become
  # fragmented which may impact performance, so at some point in time `VACUUM`
  # will need to be run to defragment the db.
  # 2. Deal with the edge case where a user configures max db size lower than
  # current db.size(). With such config the database would try to prune itself
  # with each addition.
  let dbSize = db.usedSize()

  if dbSize < int64(db.storageCapacity):
    return PutResult(kind: ContentStored)
  else:
    let (
      distanceOfFurthestElement,
      deletedBytes,
      totalContentSize,
      deletedElements
    ) =
      db.deleteContentFraction(target, contentDeletionFraction)

    let deletedFraction = float64(deletedBytes) / float64(totalContentSize)
    info "Deleted content fraction", deletedBytes, deletedElements, deletedFraction

    return PutResult(
      kind: DbPruned,
      distanceOfFurthestElement: distanceOfFurthestElement,
      deletedFraction: deletedFraction,
      deletedElements: deletedElements)

proc adjustRadius(
    p: PortalProtocol,
    deletedFraction: float64,
    distanceOfFurthestElement: UInt256) =
  # Invert fraction as the UInt256 implementation does not support
  # multiplication by float
  let invertedFractionAsInt = int64(1.0 / deletedFraction)
  let scaledRadius = p.dataRadius div u256(invertedFractionAsInt)

  # Choose a larger value to avoid the situation where the
  # `distanceOfFurthestElement is very close to the local id so that the local
  # radius would end up too small to accept any more data to the database.
  # If scaledRadius radius will be larger it will still contain all elements.
  let newRadius = max(scaledRadius, distanceOfFurthestElement)

  info "Database radius adjusted",
    oldRadius = p.dataRadius,
    newRadius = newRadius,
    distanceOfFurthestElement

  # Both scaledRadius and distanceOfFurthestElement are smaller than current
  # dataRadius, so the radius will constantly decrease through the node its
  # lifetime.
  p.dataRadius = newRadius

proc createGetHandler*(db: ContentDB): DbGetHandler =
  return (
    proc(contentKey: ByteList, contentId: ContentId): Opt[seq[byte]] =
      let content = db.get(contentId).valueOr:
        return Opt.none(seq[byte])

      ok(content)
  )

proc createStoreHandler*(
    db: ContentDB, cfg: RadiusConfig, p: PortalProtocol): DbStoreHandler =
  return (proc(
      contentKey: ByteList,
      contentId: ContentId,
      content: seq[byte]) {.raises: [], gcsafe.} =
    # always re-check that the key is in the node range to make sure only
    # content in range is stored.
    # TODO: current silent assumption is that both ContentDB and PortalProtocol
    # are using the same xor distance function
    if p.inRange(contentId):
      case cfg.kind:
      of Dynamic:
        # In case of dynamic radius setting we obey storage limits and adjust
        # radius to store network fraction corresponding to those storage limits.
        let res = db.put(contentId, content, p.baseProtocol.localNode.id)
        if res.kind == DbPruned:
          portal_pruning_counter.inc(labelValues = [$p.protocolId])
          portal_pruning_deleted_elements.set(
            res.deletedElements.int64,
            labelValues = [$p.protocolId]
          )

          if res.deletedFraction > 0.0:
            p.adjustRadius(res.deletedFraction, res.distanceOfFurthestElement)
          else:
            # Note:
            # This can occur when the furthest content is bigger than the fraction
            # size. This is unlikely to happen as it would require either very
            # small storage capacity or a very small `contentDeletionFraction`
            # combined with some big content.
            info "Database pruning attempt resulted in no content deleted"
            return

      of Static:
        # If the config is set statically, radius is not adjusted, and is kept
        # constant thorugh node life time, also database max size is disabled
        # so we will effectivly store fraction of the network
        db.put(contentId, content)
  )
