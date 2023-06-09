# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[options],
  chronicles,
  metrics,
  eth/db/kvstore,
  eth/db/kvstore_sqlite3,
  stint,
  stew/[results, byteutils],
  ssz_serialization,
  ./beacon_light_client_content,
  ../wire/portal_protocol

export kvstore_sqlite3

# We only one best optimistic and one best final update
const
  bestFinalUpdateKey = toContentId(ByteList.init(toBytes("bestFinal")))
  bestOptimisticUpdateKey = toContentId(ByteList.init(toBytes("bestOptimistic")))

type
  BestLightClientUpdateStore = ref object
    putStmt: SqliteStmt[(int64, seq[byte]), void]
    getBulkStmt: SqliteStmt[(int64, int64), seq[byte]]

  LightClientDb* = ref object
    kv: KvStoreRef
    lcuStore: BestLightClientUpdateStore

template expectDb(x: auto): untyped =
  # There's no meaningful error handling implemented for a corrupt database or
  # full disk - this requires manual intervention, so we'll panic for now
  x.expect("working database (disk broken/full?)")

proc initBestUpdatesStore(
    backend: SqStoreRef,
    name: string): KvResult[BestLightClientUpdateStore] =
  ? backend.exec("""
    CREATE TABLE IF NOT EXISTS `""" & name & """` (
      `period` INTEGER PRIMARY KEY,  -- `SyncCommitteePeriod`
      `update` BLOB                  -- `altair.LightClientUpdate` (SSZ)
    );
  """)

  let
    putStmt = backend.prepareStmt("""
      REPLACE INTO `""" & name & """` (
        `period`, `update`
      ) VALUES (?, ?);
    """, (int64, seq[byte]), void, managed = false).expect("SQL query OK")

    getBulkStmt = backend.prepareStmt("""
      SELECT `update`
      FROM `""" & name & """`
      WHERE `period` >= ? AND `period` < ?;
    """, (int64, int64), seq[byte], managed = false).expect("SQL query OK")

  ok BestLightClientUpdateStore(
    putStmt: putStmt,
    getBulkStmt: getBulkStmt
  )

proc new*(
    T: type LightClientDb, path: string, inMemory = false):
    LightClientDb =
  let db =
    if inMemory:
      SqStoreRef.init("", "lc-test", inMemory = true).expect(
        "working database (out of memory?)")
    else:
      SqStoreRef.init(path, "lc").expectDb()

  let kvStore = kvStore db.openKvStore().expectDb()
  let lcuStore = initBestUpdatesStore(db, "lcu").expectDb()

  LightClientDb(
    kv: kvStore,
    lcuStore: lcuStore
  )

# TODO Add checks that uint64 can be safely casted to int64
proc getLightClientUpdates(
    db: LightClientDb, start: uint64, to: uint64
): ForkedLightClientUpdateBytesList =
  var updates: ForkedLightClientUpdateBytesList
  var update: seq[byte]
  for res in db.lcuStore.getBulkStmt.exec((start.int64, to.int64), update):
    res.expect("SQL query OK")
    let byteList = List[byte, MAX_LIGHT_CLIENT_UPDATE_SIZE].init(update)
    discard updates.add(byteList)
  return updates

func putLightClientUpdate(
    db: LightClientDb, period: uint64, update: seq[byte]) =
  let res = db.lcuStore.putStmt.exec((period.int64, update))
  res.expect("SQL query OK")

## Private KvStoreRef Calls

proc get(kv: KvStoreRef, key: openArray[byte]): results.Opt[seq[byte]] =
  var res: results.Opt[seq[byte]] = Opt.none(seq[byte])
  proc onData(data: openArray[byte]) = res = ok(@data)

  discard kv.get(key, onData).expectDb()

  return res

## Private LightClientDb calls
proc get(db: LightClientDb, key: openArray[byte]): results.Opt[seq[byte]] =
  db.kv.get(key)

proc put(db: LightClientDb, key, value: openArray[byte]) =
  db.kv.put(key, value).expectDb()

proc get*(db: LightClientDb, key: ContentId):  results.Opt[seq[byte]] =
  # TODO: Here it is unfortunate that ContentId is a uint256 instead of Digest256.
  db.get(key.toBytesBE())

proc put*(db: LightClientDb, key: ContentId, value: openArray[byte]) =
  db.put(key.toBytesBE(), value)

proc createGetHandler*(db: LightClientDb): DbGetHandler =
  return (
    proc(contentKey: ByteList, contentId: ContentId): results.Opt[seq[byte]] =
      let contentKeyResult = decode(contentKey)
      # TODO: as this should not fail, maybe it is better to raiseAssert ?
      if contentKeyResult.isNone():
        return Opt.none(seq[byte])

      let ck = contentKeyResult.get()

      if ck.contentType == lightClientUpdate:
        let
          # TODO: add validation that startPeriod is not from the future,
          # this requires db to be aware off the current beacon time
          startPeriod = ck.lightClientUpdateKey.startPeriod
          # get max 128 updates
          numOfUpdates = min(
            uint64(MAX_REQUEST_LIGHT_CLIENT_UPDATES),
            ck.lightClientUpdateKey.count
          )
          to = startPeriod + numOfUpdates
          updates = db.getLightClientUpdates(startPeriod, to)

        if len(updates) == 0:
          return Opt.none(seq[byte])
        else:
          return ok(SSZ.encode(updates))
      elif ck.contentType == lightClientFinalityUpdate:
        # TODO Return only when the update is better that requeste by contentKey
        return db.get(bestFinalUpdateKey)
      elif ck.contentType == lightClientOptimisticUpdate:
        # TODO Return only when the update is better that requeste by contentKey
        return db.get(bestOptimisticUpdateKey)
      else:
        return db.get(contentId)
  )

proc createStoreHandler*(db: LightClientDb): DbStoreHandler =
  return (proc(
      contentKey: ByteList,
      contentId: ContentId,
      content: seq[byte]) {.raises: [], gcsafe.} =
    let contentKeyResult = decode(contentKey)
      # TODO: as this should not fail, maybe it is better to raiseAssert ?
    if contentKeyResult.isNone():
      return

    let ck = contentKeyResult.get()

    if ck.contentType == lightClientUpdate:
      # Lot of assumptions here:
      # - that updates are continious i.e there is no period gaps
      # - that updates start from startPeriod of content key
      var period = ck.lightClientUpdateKey.startPeriod

      let updatesResult = decodeSsz(content, ForkedLightClientUpdateBytesList)

      if updatesResult.isErr:
        return

      let updates = updatesResult.get()

      for update in updates.asSeq():
        db.putLightClientUpdate(period, update.asSeq())
        inc period
    elif ck.contentType == lightClientFinalityUpdate:
      db.put(bestFinalUpdateKey, content)
    elif ck.contentType == lightClientOptimisticUpdate:
      db.put(bestOptimisticUpdateKey, content)
    else:
      db.put(contentId, content)
  )
