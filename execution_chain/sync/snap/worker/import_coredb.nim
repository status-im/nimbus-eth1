# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  pkg/[chronicles, chronos, eth/common, metrics, stew/interval_set],
  ../../../db/core_db,
  ./[helpers, cache_db, update, worker_desc]

logScope:
  topics = "snap sync"

type
  CoredbImportStats* = tuple
    nAccounts: uint
    nStorages: uint
    nLazyStores: uint
    nSlots: uint
    nCodes: uint
    nLazyCodes: uint
    nErrors: uint

  ImportDesc = tuple
    ctx: SnapCtxRef
    stats: CoredbImportStats
    accPath: Hash32
    count: int
    timer: Moment

declareGauge nec_snap_dbimport_progress, "" &
  "Factor of how much has been imported into Core DB"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template persistRegularly(
    db: CoreDbRef;
    tx: CoreDbTxRef;
    ctrl: var ImportDesc;                           # var parameter
      ): untyped =
  ## Flush cached to disk
  block:
    ctrl.count.inc
    if nCoreDbImportPersistBatch <= ctrl.count:
      tx.checkpoint(0)
      db.persist tx
      ctrl.count = 0
      let w = ctrl.accPath.to(UInt256).per256
      metrics.set(nec_snap_dbimport_progress, w)
      ctrl.ctx.updateEta w

    let now = Moment.now()
    if ctrl.timer + coreDbImportMsgInterval < now:
      debug info & ": Importing into core DB", stats=ctrl.stats
      ctrl.timer = now

proc mergeCanonicalBacklog(
    tx: CoreDbTxRef;
    adb: CacheDbRef;
    info: static[string];
      ): Opt[BlockNumber] =
  # Get state record with block number and missing account ranges.
  let state = adb.getAccMissingIntv(info).valueOr:
    error info & ": Error reading accounts state"
    return err()
  if 0 < state.ranges.chunks():
    error info & ": Missing account ranges"
    return err()
  var cNum = state.number

  # Import canonical header and BAL
  let
    cHdr = ?adb.getHeader(cNum, info)
    cHash = ?adb.getBlockHash(cNum, info)
    cBal = ?adb.getBal(cNum, info)
    backlogStart = if cNum <= nBacklogHeaders: BlockNumber(1)
                   else: cNum - nBacklogHeaders

  # Store backlog, oldest header with parent hash as start-of-history.
  block:
    let
      header = adb.getHeader(backlogStart, info).valueOr:
        error info & ": Failed to fetch from cache oldest backlog header",
          header=backlogStart, pivot=cNum
        return err()
      hash = ?adb.getBlockHash(backlogStart, info)
    tx.persistHeader(hash, header, startOfHistory=header.parentHash).isOkOr:
      error info & ": Error persiting backlog oldest header",
        header=backlogStart, pivot=cNum, `error`=error
      return err()

  # Store rest of backlog
  for bn in backlogStart+1 ..< cNum:
    let
      header = ?adb.getHeader(bn, info)
      hash = ?adb.getBlockHash(bn, info)
    tx.persistHeader(hash, header).isOkOr:
      error info & ": Error persiting backlog header",
        header=bn, pivot=cNum, `error`=error
      return err()

  # Store canonical head
  tx.persistHeaderAndSetHead(cHash, cHdr).isOkOr:
    error info & ": Error setting canonical head", header=cNum, `error`=error
    return err()
  tx.setFirstBlockHash(cHash).isOkOr:
    error info & ": Error setting first hash", header=cNum, `error`=error
    return err()
  tx.persistBlockAccessList(cHash, cBal)

  ok(move cNum)

proc mergeStoTrie(
    db: CoreDbRef;
    tx: CoreDbTxRef;
    adb: CacheDbRef;
    accPath: Hash32;
    stoRoot: Hash32;
    ctrl: var ImportDesc;
    info: static[string];
      ): Opt[void] =
  # Clear storage trie
  tx.clearStorage(accPath).isOkOr:
    error info & ": Failed clearing storage slots",
      accPath=accPath.toStr, `error`=($$error)
    return err()

  var nSlots {.used.} = 0u
  for w in adb.walkFlatSlot(accPath):
    if 0 < w.error.len:
      error info & ": Error walking storage slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=w.error
      return err()
    tx.mergeSlot(accPath, w.slotKey, w.data).isOkOr:
      error info & ": Failed merging slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=($$error)
      return err()

    nSlots.inc
    ctrl.count.inc

    ctrl.stats.nSlots.inc
    db.persistRegularly(tx, ctrl)

  # Verify storage sub-MPT.
  let hash = tx.fetchStorageRoot(accPath).valueOr:
    error info & ": Failed computing storage root", nSlots,
      accPath=accPath.toStr, `error`=($$error)
    return err()
  if stoRoot == zeroHash32:
    ctrl.stats.nLazyStores.inc
  elif stoRoot != hash:
    error info & ": Mismatch with pre-set storage root", nSlots,
      accPath=accPath.toStr, stoRoot=hash.toStr, expected=stoRoot.toStr
    return err()

  ok()

proc mergeCtrCode(
    db: CoreDbRef;
    tx: CoreDbTxRef;
    adb: CacheDbRef;
    accPath: Hash32;
    codeHash: Hash32;
    info: static[string];
      ): Opt[Hash32] =
  # Save contract code so that the storage trie can be updated
  let data = adb.getFlatCode(accPath, info).valueOr:
    error info & ": No such contract code", accPath=accPath.toStr,
      codeHash=codeHash.toStr
    return err()

  let hash = data.keccak256
  if codeHash != hash and
     codeHash != zeroHash32:
    error info & ": Mismatch with pre-set code hash",
      accPath=accPath.toStr, codeHash=hash.toStr, expected=codeHash.toStr
    return err()

  # Save contract code to core DB
  tx.persistCodeByHash(hash, data).isOkOr:
    error info & ": Failed storing contract code",
      accPath=accPath.toStr, codeHash=hash.toStr,
      nCodes=data.len, `error`=error
    return err()

  ok(hash)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc fetchStateRoot(
    tx: CoreDbTxRef;
    info: static[string];
      ): Opt[Hash32] =
  var root = tx.getStateRoot.valueOr:
    error info & ": Failed computing state root", `error`=($$error)
    return err()
  ok(move root)

proc importFlat(
    db: CoreDbRef;
    tx: CoreDbTxRef;
    ctx: SnapCtxRef;
    stopOnError: bool;
    info: static[string];
      ): CoredbImportStats =
  var ctrl: ImportDesc
  ctrl.ctx = ctx

  metrics.set(nec_snap_dbimport_progress, 0)

  # Import canonical head
  let
    adb = ctx.pool.cacheDB
    cNum = tx.mergeCanonicalBacklog(adb, info).valueOr:
      error info & ": Failed importing header backlog"
      ctrl.stats.nErrors.inc
      return ctrl.stats

  # Merge flat tables into CoreDb/Aristo.
  var count = 0
  for w in adb.walkFlatAcc():
    if 0 < w.error.len:
      error info & ": Error walking accounts",
        accPath=w.accPath.toStr, `error`=w.error
      ctrl.stats.nErrors.inc
      return ctrl.stats

    # Import contract code and get code hash
    var codeHash = w.data.account.codeHash
    if codeHash != EMPTY_CODE_HASH:
      ctrl.stats.nCodes.inc
      if codeHash == zeroHash32:
        ctrl.stats.nLazyCodes.inc
      let rc = db.mergeCtrCode(tx, adb, w.accPath, w.data.account.codeHash,info)
      if rc.isOk:
        codeHash = rc.value
      else:
        ctrl.stats.nErrors.inc
        if stopOnError:
          return ctrl.stats

    # Import account record
    var
      accUpdateOk = false
      accRec = CoreDbAccount(
        nonce:    w.data.account.nonce,
        balance:  w.data.account.balance,
        codeHash: codeHash)
    tx.mergeAccount(w.accPath, accRec).isOkOr:
      error info & ": Failed merging account record",
        accPath=w.accPath.toStr, `error`=($$error)
      ctrl.stats.nErrors.inc
      return ctrl.stats
    ctrl.stats.nAccounts.inc
    ctrl.accPath = w.accPath

    if w.data.account.storageRoot != EMPTY_ROOT_HASH:
      ctrl.stats.nStorages.inc
      db.mergeStoTrie(
           tx, adb, w.accPath, w.data.account.storageRoot, ctrl, info).isOkOr:
        ctrl.stats.nErrors.inc
        if stopOnError:
          return ctrl.stats

    db.persistRegularly(tx, ctrl)

  tx.checkpoint(cNum)
  db.persist tx
  metrics.set(nec_snap_dbimport_progress, ctrl.accPath.to(UInt256).per256)
  ctrl.stats

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

proc importCoreDbMetricsReset*(ctx: SnapCtxRef) =
  metrics.set(nec_snap_dbimport_progress, 0)
  ctx.resetEta()

proc importCoreDb*(
    db: CoreDbRef;
    tx: CoreDbTxRef;
    ctx: SnapCtxRef;
    info: static[string];
    stopOnError = false;
      ): Opt[CoredbImportStats] =
  ## Import the flat tables into a version of CoreDb.
  ##
  ctx.resetEta()

  let
    adb = ctx.pool.cacheDB
    start = Moment.now()
    status = ?adb.getAccMissingIntv(info)
    header = ?adb.getHeader(status.number, info)
    txStats = db.importFlat(tx, ctx, stopOnError, info) # import data

  if 0 < txStats.nErrors:
    error info & ": Error importing snap data", number=status.number, txStats
    return err()

  let txStateRoot = ?tx.fetchStateRoot(info)
  if header.stateRoot != txStateRoot:
    error info & ": Imported snap state root differs from expected",
      number=status.number, stateRoot=txStateRoot.toStr,
      expected=header.stateRoot.toStr, txStats
    return err()

  metrics.set(nec_snap_dbimport_progress, 1.0)

  notice info & ": Imported snap state to Core DB",
    number=status.number, stateRoot=header.stateRoot.toStr,
      nAccounts=txStats.nAccounts, nStorages=txStats.nStorages,
      nSlots=txStats.nSlots, nLazyStores=txStats.nLazyStores,
      nCodes=txStats.nCodes, nLazyCodes=txStats.nLazyCodes,
      ela=(Moment.now()-start).toStr

  ok(txStats)

proc wipeCacheDb*(ctx: SnapCtxRef) =
  ## Wipe cache DB on disk
  ctx.pool.cacheDB.close(wipe=true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
