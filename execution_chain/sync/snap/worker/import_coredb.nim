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
  pkg/[chronicles, chronos, eth/common, stew/interval_set],
  ../../../db/core_db,
  ./[helpers, cache_db, worker_desc]

logScope:
  topics = "snap sync"

type
  CoredbImportStats* = tuple
    nAccounts: uint
    nStorage: uint
    nSlots: uint
    nCodes: uint
    nErrors: uint

  ImportDesc = tuple
    stats: CoredbImportStats
    count: int
    timer: Moment

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
    let now = Moment.now()
    if ctrl.timer + coreDbImportMsgInterval < now:
      debug info & ": Importing into core DB", stats=ctrl.stats
      ctrl.timer = now

proc mergeCanonicalHead(
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
    startOfHist = cHdr.parentHash
  tx.persistHeaderAndSetHead(cHash, cHdr, startOfHist).isOkOr:
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
  if stoRoot != hash:
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
      ): Opt[void] =
  # Save contract code so that the storage trie can be updated
  let data = adb.getFlatCode(accPath, info).valueOr:
    error info & ": No such contract code", accPath=accPath.toStr,
      codeHash=codeHash.toStr
    return err()

  let hash = data.keccak256
  if codeHash != hash:
    error info & ": Mismatch with pre-set code hash",
      accPath=accPath.toStr, codeHash=hash.toStr, expected=codeHash.toStr
    return err()

  # Save contract code to core DB
  tx.persistCodeByHash(codeHash, data).isOkOr:
    error info & ": Failed storing contract code",
      accPath=accPath.toStr, codeHash=codeHash.toStr,
      nCode=data.len, `error`=error
    return err()

  ok()

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
    adb: CacheDbRef;
    stopOnError: bool;
    info: static[string];
      ): CoredbImportStats =
  var ctrl: ImportDesc

  # Import canonical head
  let cNum = tx.mergeCanonicalHead(adb, info).valueOr:
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

    # Verify that the code and storage are properly updated. No need to
    # test the `storageRoot` as it will be reset to `zeroHash32` when BAL
    # forwarding.
    if w.data.dirtyCode or
       w.data.dirtyStorage or
       w.data.account.storageRoot == zeroHash32 or
       w.data.account.codeHash == zeroHash32:
      error info & ": Account record is incomplete",
        accPath=w.accPath.toStr,
        dirtyStorage=w.data.dirtyStorage,
        dirtyCode=w.data.dirtyCode,
        storageRoot=w.data.account.storageRoot.toStr,
        codeHash=w.data.account.codeHash.toStr
      ctrl.stats.nErrors.inc
      if stopOnError:
        return ctrl.stats

    # Save account
    let accRec = CoreDbAccount(
      nonce:    w.data.account.nonce,
      balance:  w.data.account.balance,
      codeHash: w.data.account.codeHash)
    tx.mergeAccount(w.accPath, accRec).isOkOr:
      error info & ": Failed merging account record",
        accPath=w.accPath.toStr, `error`=($$error)
      ctrl.stats.nErrors.inc
      return ctrl.stats
    ctrl.stats.nAccounts.inc

    if w.data.account.storageRoot != EMPTY_ROOT_HASH:
      ctrl.stats.nStorage.inc
      db.mergeStoTrie(
           tx, adb, w.accPath, w.data.account.storageRoot, ctrl, info).isOkOr:
        ctrl.stats.nErrors.inc
        if stopOnError:
          return ctrl.stats

    if w.data.account.codeHash != EMPTY_CODE_HASH:
      ctrl.stats.nCodes.inc
      db.mergeCtrCode(tx, adb, w.accPath, w.data.account.codeHash, info).isOkOr:
        ctrl.stats.nErrors.inc
        if stopOnError:
          return ctrl.stats

    db.persistRegularly(tx, ctrl)

  tx.checkpoint(cNum)
  db.persist tx
  ctrl.stats

# ------------------------------------------------------------------------------
# Public function(s)
# ------------------------------------------------------------------------------

proc importCoreDb*(
    db: CoreDbRef;
    tx: CoreDbTxRef;
    adb: CacheDbRef;
    info: static[string];
    stopOnError = false;
      ): Opt[CoredbImportStats] =
  ## Import the flat tables into a version of CoreDb.
  ##
  let
    start = Moment.now()
    status = ?adb.getAccMissingIntv(info)
    header = ?adb.getHeader(status.number, info)
    txStats = db.importFlat(tx, adb, stopOnError, info) # import data

  if 0 < txStats.nErrors:
    error info & ": Error importing snap data", number=status.number, txStats
    return err()

  let txStateRoot = ?tx.fetchStateRoot(info)
  if header.stateRoot != txStateRoot:
    error info & ": State roots differ when importing snap data",
      number=status.number, stateRoot=header.stateRoot.toStr,
      expected=txStateRoot.toStr, txStats
    return err()

  notice info & ": Imported snap state to Core DB",
    number=status.number, stateRoot=header.stateRoot.toStr,
      nAccounts=txStats.nAccounts, nStorage=txStats.nStorage,
      nSlots=txStats.nSlots, nCodes=txStats.nCodes,
      ela=(Moment.now()-start).toStr

  ok(txStats)

proc wipeCacheDb*(adb: CacheDbRef) =
  ## Wipe cache DB on disk
  adb.close(wipe=true)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
