# fluffy
# Copyright (c) 2022-2024 Status Research & Development GmbH
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
  results,
  ssz_serialization,
  beacon_chain/db_limits,
  beacon_chain/spec/datatypes/[phase0, altair, bellatrix],
  beacon_chain/spec/forks,
  beacon_chain/spec/forks_light_client,
  ./beacon_content,
  ./beacon_chain_historical_summaries,
  ./beacon_init_loader,
  ../wire/portal_protocol

from beacon_chain/spec/helpers import is_better_update, toMeta

export kvstore_sqlite3

type
  BestLightClientUpdateStore = ref object
    getStmt: SqliteStmt[int64, seq[byte]]
    getBulkStmt: SqliteStmt[(int64, int64), seq[byte]]
    putStmt: SqliteStmt[(int64, seq[byte]), void]
    delStmt: SqliteStmt[int64, void]

  BeaconDb* = ref object
    backend: SqStoreRef
    kv: KvStoreRef
    bestUpdates: BestLightClientUpdateStore
    forkDigests: ForkDigests
    cfg: RuntimeConfig
    finalityUpdateCache: Opt[LightClientFinalityUpdateCache]
    optimisticUpdateCache: Opt[LightClientOptimisticUpdateCache]

  # Storing the content encoded here. Could also store decoded and access the
  # slot directly. However, that would require is to have access to the
  # fork digests here to be able the re-encode the data.
  LightClientFinalityUpdateCache = object
    lastFinalityUpdate: seq[byte]
    lastFinalityUpdateSlot: uint64

  LightClientOptimisticUpdateCache = object
    lastOptimisticUpdate: seq[byte]
    lastOptimisticUpdateSlot: uint64

template expectDb(x: auto): untyped =
  # There's no meaningful error handling implemented for a corrupt database or
  # full disk - this requires manual intervention, so we'll panic for now
  x.expect("working database (disk broken/full?)")

template disposeSafe(s: untyped): untyped =
  if distinctBase(s) != nil:
    s.dispose()
    s = typeof(s)(nil)

proc initBestUpdatesStore(
    backend: SqStoreRef, name: string
): KvResult[BestLightClientUpdateStore] =
  ?backend.exec(
    """
    CREATE TABLE IF NOT EXISTS `""" & name &
      """` (
      `period` INTEGER PRIMARY KEY,  -- `SyncCommitteePeriod`
      `update` BLOB                  -- `altair.LightClientUpdate` (SSZ)
    );
  """
  )

  let
    getStmt = backend
      .prepareStmt(
        """
      SELECT `update`
      FROM `""" & name &
          """`
      WHERE `period` = ?;
    """,
        int64,
        seq[byte],
        managed = false,
      )
      .expect("SQL query OK")
    getBulkStmt = backend
      .prepareStmt(
        """
      SELECT `update`
      FROM `""" & name &
          """`
      WHERE `period` >= ? AND `period` < ?;
    """,
        (int64, int64),
        seq[byte],
        managed = false,
      )
      .expect("SQL query OK")
    putStmt = backend
      .prepareStmt(
        """
      REPLACE INTO `""" & name &
          """` (
        `period`, `update`
      ) VALUES (?, ?);
    """,
        (int64, seq[byte]),
        void,
        managed = false,
      )
      .expect("SQL query OK")
    delStmt = backend
      .prepareStmt(
        """
      DELETE FROM `""" & name &
          """`
      WHERE `period` = ?;
    """,
        int64,
        void,
        managed = false,
      )
      .expect("SQL query OK")

  ok BestLightClientUpdateStore(
    getStmt: getStmt, getBulkStmt: getBulkStmt, putStmt: putStmt, delStmt: delStmt
  )

func close*(store: var BestLightClientUpdateStore) =
  store.getStmt.disposeSafe()
  store.getBulkStmt.disposeSafe()
  store.putStmt.disposeSafe()
  store.delStmt.disposeSafe()

proc new*(
    T: type BeaconDb, networkData: NetworkInitData, path: string, inMemory = false
): BeaconDb =
  let
    db =
      if inMemory:
        SqStoreRef.init("", "lc-test", inMemory = true).expect(
          "working database (out of memory?)"
        )
      else:
        SqStoreRef.init(path, "lc").expectDb()

    kvStore = kvStore db.openKvStore().expectDb()
    bestUpdates = initBestUpdatesStore(db, "lcu").expectDb()

  BeaconDb(
    backend: db,
    kv: kvStore,
    bestUpdates: bestUpdates,
    cfg: networkData.metadata.cfg,
    forkDigests: (newClone networkData.forks)[],
  )

## Private KvStoreRef Calls
proc get(kv: KvStoreRef, key: openArray[byte]): results.Opt[seq[byte]] =
  var res: results.Opt[seq[byte]] = Opt.none(seq[byte])
  proc onData(data: openArray[byte]) =
    res = ok(@data)

  discard kv.get(key, onData).expectDb()

  return res

## Private BeaconDb calls
proc get(db: BeaconDb, key: openArray[byte]): results.Opt[seq[byte]] =
  db.kv.get(key)

proc put(db: BeaconDb, key, value: openArray[byte]) =
  db.kv.put(key, value).expectDb()

## Public ContentId based ContentDB calls
proc get*(db: BeaconDb, key: ContentId): results.Opt[seq[byte]] =
  # TODO: Here it is unfortunate that ContentId is a uint256 instead of Digest256.
  db.get(key.toBytesBE())

proc put*(db: BeaconDb, key: ContentId, value: openArray[byte]) =
  db.put(key.toBytesBE(), value)

# TODO Add checks that uint64 can be safely casted to int64
proc getLightClientUpdates(
    db: BeaconDb, start: uint64, to: uint64
): ForkedLightClientUpdateBytesList =
  ## Get multiple consecutive LightClientUpdates for given periods
  var updates: ForkedLightClientUpdateBytesList
  var update: seq[byte]
  for res in db.bestUpdates.getBulkStmt.exec((start.int64, to.int64), update):
    res.expect("SQL query OK")
    let byteList = List[byte, MAX_LIGHT_CLIENT_UPDATE_SIZE].init(update)
    discard updates.add(byteList)
  return updates

proc getBestUpdate*(
    db: BeaconDb, period: SyncCommitteePeriod
): Result[ForkedLightClientUpdate, string] =
  ## Get the best ForkedLightClientUpdate for given period
  ## Note: Only the best one for a given period is being stored.
  doAssert period.isSupportedBySQLite
  doAssert distinctBase(db.bestUpdates.getStmt) != nil

  var update: seq[byte]
  for res in db.bestUpdates.getStmt.exec(period.int64, update):
    res.expect("SQL query OK")
    return decodeLightClientUpdateForked(db.forkDigests, update)

proc putBootstrap*(
    db: BeaconDb, blockRoot: Digest, bootstrap: ForkedLightClientBootstrap
) =
  # Put a ForkedLightClientBootstrap in the db.
  withForkyBootstrap(bootstrap):
    when lcDataFork > LightClientDataFork.None:
      let
        contentKey = bootstrapContentKey(blockRoot)
        contentId = toContentId(contentKey)
        forkDigest = forkDigestAtEpoch(
          db.forkDigests, epoch(forkyBootstrap.header.beacon.slot), db.cfg
        )
        encodedBootstrap = encodeBootstrapForked(forkDigest, bootstrap)

      db.put(contentId, encodedBootstrap)

func putLightClientUpdate*(db: BeaconDb, period: uint64, update: seq[byte]) =
  # Put an encoded ForkedLightClientUpdate in the db.
  let res = db.bestUpdates.putStmt.exec((period.int64, update))
  res.expect("SQL query OK")

func putBestUpdate*(
    db: BeaconDb, period: SyncCommitteePeriod, update: ForkedLightClientUpdate
) =
  # Put a ForkedLightClientUpdate in the db.
  doAssert not db.backend.readOnly # All `stmt` are non-nil
  doAssert period.isSupportedBySQLite
  withForkyUpdate(update):
    when lcDataFork > LightClientDataFork.None:
      let numParticipants = forkyUpdate.sync_aggregate.num_active_participants
      if numParticipants < MIN_SYNC_COMMITTEE_PARTICIPANTS:
        let res = db.bestUpdates.delStmt.exec(period.int64)
        res.expect("SQL query OK")
      else:
        let
          forkDigest = forkDigestAtEpoch(
            db.forkDigests, epoch(forkyUpdate.attested_header.beacon.slot), db.cfg
          )
          encodedUpdate = encodeForkedLightClientObject(update, forkDigest)
          res = db.bestUpdates.putStmt.exec((period.int64, encodedUpdate))
        res.expect("SQL query OK")
    else:
      db.bestUpdates.delStmt.exec(period.int64).expect("SQL query OK")

proc putUpdateIfBetter*(
    db: BeaconDb, period: SyncCommitteePeriod, update: ForkedLightClientUpdate
) =
  let currentUpdate = db.getBestUpdate(period).valueOr:
    # No current update for that period so we can just put this one
    db.putBestUpdate(period, update)
    return

  if is_better_update(update, currentUpdate):
    db.putBestUpdate(period, update)

proc putUpdateIfBetter*(db: BeaconDb, period: SyncCommitteePeriod, update: seq[byte]) =
  let newUpdate = decodeLightClientUpdateForked(db.forkDigests, update).valueOr:
    # TODO:
    # Need to go over the usage in offer/accept vs findcontent/content
    # and in some (all?) decoding has already been verified.
    return

  db.putUpdateIfBetter(period, newUpdate)

proc getLastFinalityUpdate*(db: BeaconDb): Opt[ForkedLightClientFinalityUpdate] =
  db.finalityUpdateCache.map(
    proc(x: LightClientFinalityUpdateCache): ForkedLightClientFinalityUpdate =
      decodeLightClientFinalityUpdateForked(db.forkDigests, x.lastFinalityUpdate).valueOr:
        raiseAssert "Stored finality update must be valid"
  )

proc createGetHandler*(db: BeaconDb): DbGetHandler =
  return (
    proc(contentKey: ByteList, contentId: ContentId): results.Opt[seq[byte]] =
      let contentKey = contentKey.decode().valueOr:
        # TODO: as this should not fail, maybe it is better to raiseAssert ?
        return Opt.none(seq[byte])

      case contentKey.contentType
      of unused:
        raiseAssert "Should not be used and fail at decoding"
      of lightClientBootstrap:
        db.get(contentId)
      of lightClientUpdate:
        let
          # TODO: add validation that startPeriod is not from the future,
          # this requires db to be aware off the current beacon time
          startPeriod = contentKey.lightClientUpdateKey.startPeriod
          # get max 128 updates
          numOfUpdates = min(
            uint64(MAX_REQUEST_LIGHT_CLIENT_UPDATES),
            contentKey.lightClientUpdateKey.count,
          )
          toPeriod = startPeriod + numOfUpdates # Not inclusive
          updates = db.getLightClientUpdates(startPeriod, toPeriod)

        if len(updates) == 0:
          Opt.none(seq[byte])
        else:
          Opt.some(SSZ.encode(updates))
      of lightClientFinalityUpdate:
        # TODO:
        # Return only when the update is better than what is requested by
        # contentKey. This is currently not possible as the contentKey does not
        # include best update information.
        if db.finalityUpdateCache.isSome():
          let slot = contentKey.lightClientFinalityUpdateKey.finalizedSlot
          let cache = db.finalityUpdateCache.get()
          if cache.lastFinalityUpdateSlot >= slot:
            Opt.some(cache.lastFinalityUpdate)
          else:
            Opt.none(seq[byte])
        else:
          Opt.none(seq[byte])
      of lightClientOptimisticUpdate:
        # TODO same as above applies here too.
        if db.optimisticUpdateCache.isSome():
          let slot = contentKey.lightClientOptimisticUpdateKey.optimisticSlot
          let cache = db.optimisticUpdateCache.get()
          if cache.lastOptimisticUpdateSlot >= slot:
            Opt.some(cache.lastOptimisticUpdate)
          else:
            Opt.none(seq[byte])
        else:
          Opt.none(seq[byte])
      of beacon_content.ContentType.historicalSummaries:
        db.get(contentId)
  )

proc createStoreHandler*(db: BeaconDb): DbStoreHandler =
  return (
    proc(
        contentKey: ByteList, contentId: ContentId, content: seq[byte]
    ) {.raises: [], gcsafe.} =
      let contentKey = decode(contentKey).valueOr:
        # TODO: as this should not fail, maybe it is better to raiseAssert ?
        return

      case contentKey.contentType
      of unused:
        raiseAssert "Should not be used and fail at decoding"
      of lightClientBootstrap:
        db.put(contentId, content)
      of lightClientUpdate:
        let updates = decodeSsz(content, ForkedLightClientUpdateBytesList).valueOr:
          return

        # Lot of assumptions here:
        # - that updates are continious i.e there is no period gaps
        # - that updates start from startPeriod of content key
        var period = contentKey.lightClientUpdateKey.startPeriod
        for update in updates.asSeq():
          # Only put the update if it is better, although in currently a new offer
          # should not be accepted as it is based on only the period.
          db.putUpdateIfBetter(SyncCommitteePeriod(period), update.asSeq())
          inc period
      of lightClientFinalityUpdate:
        db.finalityUpdateCache = Opt.some(
          LightClientFinalityUpdateCache(
            lastFinalityUpdateSlot:
              contentKey.lightClientFinalityUpdateKey.finalizedSlot,
            lastFinalityUpdate: content,
          )
        )
      of lightClientOptimisticUpdate:
        db.optimisticUpdateCache = Opt.some(
          LightClientOptimisticUpdateCache(
            lastOptimisticUpdateSlot:
              contentKey.lightClientOptimisticUpdateKey.optimisticSlot,
            lastOptimisticUpdate: content,
          )
        )
      of beacon_content.ContentType.historicalSummaries:
        # TODO: Its probably better to not use the kvstore here and instead use a sql
        # table with slot as index and move the slot logic to the db store handler.
        let current = db.get(contentId)
        if current.isSome():
          let summariesWithProof = decodeSsz(
            db.forkDigests, current.get(), HistoricalSummariesWithProof
          ).valueOr:
            raiseAssert error
          let newSummariesWithProof = decodeSsz(
            db.forkDigests, content, HistoricalSummariesWithProof
          ).valueOr:
            return
          if newSummariesWithProof.epoch > summariesWithProof.epoch:
            db.put(contentId, content)
        else:
          db.put(contentId, content)
  )
