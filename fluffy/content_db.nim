# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

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
  "Number of pruning event which happened during node lifetime",
  labels = ["protocol_id"]

declareGauge portal_pruning_deleted_elements,
  "Number of elements delted in last pruning",
  labels = ["protocol_id"]

type
  RowInfo = tuple
    contentId: array[32, byte]
    payloadLength: int64
    distance: array[32, byte]

  ObjInfo* = object
    contentId*: array[32, byte]
    payloadLength*: int64
    distFrom*: UInt256

  ContentDB* = ref object
    kv: KvStoreRef
    maxSize: uint32
    sizeStmt: SqliteStmt[NoParams, int64]
    unusedSizeStmt: SqliteStmt[NoParams, int64]
    vacStmt: SqliteStmt[NoParams, void]
    contentSizeStmt: SqliteStmt[NoParams, int64]
    getAllOrderedByDistanceStmt: SqliteStmt[array[32, byte], RowInfo]

  PutResultType* = enum
    ContentStored, DbPruned

  PutResult* = object
    case kind*: PutResultType
    of ContentStored:
      discard
    of DbPruned:
      furthestStoredElementDistance*: UInt256
      fractionOfDeletedContent*: float64
      numOfDeletedElements*: int64

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
    T: type ContentDB, path: string, maxSize: uint32, inMemory = false):
    ContentDB =
  let db =
    if inMemory:
      SqStoreRef.init("", "fluffy-test", inMemory = true).expect(
        "working database (out of memory?)")
    else:
      SqStoreRef.init(path, "fluffy").expectDb()

  db.registerCustomScalarFunction("xorDistance", xorDistance)
    .expect("Couldn't register custom xor function")

  let getSizeStmt = db.prepareStmt(
    "SELECT page_count * page_size as size FROM pragma_page_count(), pragma_page_size();",
    NoParams, int64).get()

  let unusedSize = db.prepareStmt(
    "SELECT freelist_count * page_size as size FROM pragma_freelist_count(), pragma_page_size();",
    NoParams, int64).get()

  let vacStmt = db.prepareStmt(
    "VACUUM;",
    NoParams, void).get()

  let kvStore = kvStore db.openKvStore().expectDb()

  let contentSizeStmt = db.prepareStmt(
    "SELECT SUM(length(value)) FROM kvstore",
    NoParams, int64
  ).get()

  let getAllOrderedByDistanceStmt = db.prepareStmt(
    "SELECT key, length(value), xorDistance(?, key) as distance FROM kvstore ORDER BY distance DESC",
    array[32, byte], RowInfo
  ).get()

  ContentDB(
    kv: kvStore,
    maxSize: maxSize,
    sizeStmt: getSizeStmt,
    vacStmt: vacStmt,
    unusedSizeStmt: unusedSize,
    contentSizeStmt: contentSizeStmt,
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
    except SszError:
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

proc getSszDecoded*(
    db: ContentDB, key: openArray[byte], T: type auto): Opt[T] =
  db.kv.getSszDecoded(key, T)

proc reclaimSpace*(db: ContentDB): void =
  ## Runs sqlite VACUUM commands which rebuilds the db, repacking it into a
  ## minimal amount of disk space.
  ## Ideal mode of operation, is to run it after several deletes.
  ## Another option would be to run 'PRAGMA auto_vacuum = FULL;' statement at
  ## the start of db to leave it up to sqlite to clean up
  db.vacStmt.exec().expectDb()

proc size*(db: ContentDB): int64 =
  ## Retrun current size of DB as product of sqlite page_count and page_size
  ## https://www.sqlite.org/pragma.html#pragma_page_count
  ## https://www.sqlite.org/pragma.html#pragma_page_size
  ## It returns total size of db i.e both data and metadata used to store content
  ## also it is worth noting that when deleting content, size may lags behind due
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

proc realSize*(db: ContentDB): int64 =
  db.size() - db.unusedSize()

proc contentSize(db: ContentDB): int64 =
  ## Returns total size of content stored in DB
  var size: int64 = 0
  discard (db.contentSizeStmt.exec do(res: int64):
    size = res).expectDb()
  return size

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
  db.get(key.toByteArrayBE())

proc put*(db: ContentDB, key: ContentId, value: openArray[byte]) =
  db.put(key.toByteArrayBE(), value)

proc contains*(db: ContentDB, key: ContentId): bool =
  db.contains(key.toByteArrayBE())

proc del*(db: ContentDB, key: ContentId) =
  db.del(key.toByteArrayBE())

proc getSszDecoded*(db: ContentDB, key: ContentId, T: type auto): Opt[T] =
  db.getSszDecoded(key.toByteArrayBE(), T)

proc deleteContentFraction(
  db: ContentDB,
  target: UInt256,
  fraction: float64): (UInt256, int64, int64, int64) =
  ## Deletes at most `fraction` percent of content form database.
  ## First, content furthest from provided `target` is deleted.

  doAssert(
    fraction > 0 and fraction < 1,
    "Deleted fraction should be > 0 and < 1"
  )

  let totalContentSize = db.contentSize()
  let bytesToDelete = int64(fraction * float64(totalContentSize))
  var numOfDeletedElements: int64 = 0

  var ri: RowInfo
  var bytesDeleted: int64 = 0
  let targetBytes = target.toByteArrayBE()
  for e in db.getAllOrderedByDistanceStmt.exec(targetBytes, ri):
    if bytesDeleted + ri.payloadLength < bytesToDelete:
      db.del(ri.contentId)
      bytesDeleted = bytesDeleted + ri.payloadLength
      inc numOfDeletedElements
    else:
      return (
        UInt256.fromBytesBE(ri.distance),
        bytesDeleted,
        totalContentSize,
        numOfDeletedElements
      )

proc put*(
    db: ContentDB,
    key: ContentId,
    value: openArray[byte],
    target: UInt256): PutResult =

  db.put(key, value)

  # We use real size for our pruning threshold, which means that database file
  # will reach size specified in db.maxSize, and will stay that size thorough
  # node life time, as after content deletion free pages will be re used.
  # TODO:
  # 1. Devise vacuum strategy - after few pruning cycles database can become
  # fragmented which may impact performance, so at some point in time `VACUUM`
  # will need to be run to defragment the db.
  # 2. Deal with the edge case where a user configures max db size lower than
  # current db.size(). With such config the database would try to prune itself
  # with each addition.
  let dbSize = db.realSize()

  if dbSize < int64(db.maxSize):
    return PutResult(kind: ContentStored)
  else:
    # TODO Add some configuration for this magic number
    let (
      furthestNonDeletedElement,
      deletedBytes,
      totalContentSize,
      deletedElements
    ) =
      db.deleteContentFraction(target, 0.25)

    let deletedFraction = float64(deletedBytes) / float64(totalContentSize)

    return PutResult(
      kind: DbPruned,
      furthestStoredElementDistance: furthestNonDeletedElement,
      fractionOfDeletedContent: deletedFraction,
      numOfDeletedElements: deletedElements)

proc adjustRadius(
    p: PortalProtocol,
    fractionOfDeletedContent: float64,
    furthestElementInDbDistance: UInt256) =
  if fractionOfDeletedContent == 0.0:
    # even though pruning was triggered no content was deleted, it could happen
    # in pathological case of really small database with really big values.
    # log it as error as it should not happenn
    error "Database pruning attempt resulted in no content deleted"
    return

  # we need to invert fraction as our Uin256 implementation does not support
  # multiplication by float
  let invertedFractionAsInt = int64(1.0 / fractionOfDeletedContent)

  let scaledRadius = p.dataRadius div u256(invertedFractionAsInt)

  # Chose larger value to avoid situation, where furthestElementInDbDistance
  # is super close to local id, so local radius would end up too small
  # to accept any more data to local database
  # If scaledRadius radius will be larger it will still contain all elements
  let newRadius = max(scaledRadius, furthestElementInDbDistance)

  debug "Database pruned",
    oldRadius = p.dataRadius,
    newRadius = newRadius,
    furthestDistanceInDb = furthestElementInDbDistance,
    fractionOfDeletedContent = fractionOfDeletedContent

  # both scaledRadius and furthestElementInDbDistance are smaller than current
  # dataRadius, so the radius will constantly decrease through the node
  # life time
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
      content: seq[byte]) {.raises: [Defect], gcsafe.} =
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
            res.numOfDeletedElements.int64,
            labelValues = [$p.protocolId]
          )

          p.adjustRadius(
            res.fractionOfDeletedContent,
            res.furthestStoredElementDistance
          )
      of Static:
        # If the config is set statically, radius is not adjusted, and is kept
        # constant thorugh node life time, also database max size is disabled
        # so we will effectivly store fraction of the network
        db.put(contentId, content)
  )
