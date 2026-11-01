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
  pkg/[chronicles, eth/common, stew/interval_set],
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
    nStoNoRoot: uint
    nCodeNoHash: uint

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

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
    count: var int;
    info: static[string];
      ): tuple[nSlots: uint, ok: bool] =
  # Clear storage trie
  tx.clearStorage(accPath).isOkOr:
    error info & ": Failed clearing storage slots",
      accPath=accPath.toStr, `error`=($$error)
    return (0,false)

  var nSlots = 0u
  for w in adb.walkFlatSlot(accPath):
    if 0 < w.error.len:
      error info & ": Error walking storage slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=w.error
      return (nSlots,false)
    tx.mergeSlot(accPath, w.slotKey, w.data).isOkOr:
      error info & ": Failed merging slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=($$error)
      return (nSlots,false)

    nSlots.inc
    count.inc

    # Save regurlarly
    if nCoreDbImportPersistBatch <= count:
      tx.checkpoint(0)
      db.persist tx
      count = 0

  # Verify storage sub-MPT.
  let hash = tx.fetchStorageRoot(accPath).valueOr:
    error info & ": Failed computing storage root", nSlots,
      accPath=accPath.toStr, `error`=($$error)
    return (nSlots,false)
  if stoRoot != hash:
    error info & ": Mismatch with pre-set storage root", nSlots,
      accPath=accPath.toStr, stoRoot=hash.toStr, expected=stoRoot.toStr
    return (nSlots,false)

  (nSlots,true)

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
  var u: CoredbImportStats

  # Import canonical head
  let cNum = tx.mergeCanonicalHead(adb, info).valueOr:
    u.nErrors.inc
    return u

  # Merge flat tables into CoreDb/Aristo.
  var count = 0
  for w in adb.walkFlatAcc():
    if 0 < w.error.len:
      error info & ": Error walking accounts",
        accPath=w.accPath.toStr, `error`=w.error
      u.nErrors.inc
      return u

    # Verify that the code and storage are properly updated. No need to
    # test the `storageRoot` as it will be reset to `zeroHash32` when BAL
    # forwarding.
    block noErrorsOk:
      block checkErrors:
        if w.data.dirtyCode:
          break checkErrors
        if w.data.dirtyStorage:
          break checkErrors
        if w.data.account.storageRoot == zeroHash32:
          u.nStoNoRoot.inc
          break checkErrors
        if w.data.account.codeHash == zeroHash32:
          u.nCodeNoHash.inc
          break checkErrors
        break noErrorsOk
      error info & ": Account record is incomplete",
        accPath=w.accPath.toStr,
        dirtyStorage=w.data.dirtyStorage,
        dirtyCode=w.data.dirtyCode,
        storageRoot=w.data.account.storageRoot.toStr,
        codeHash=w.data.account.codeHash.toStr
      u.nErrors.inc
      if stopOnError:
        return u

    # Save account
    let accRec = CoreDbAccount(
      nonce:    w.data.account.nonce,
      balance:  w.data.account.balance,
      codeHash: w.data.account.codeHash)
    tx.mergeAccount(w.accPath, accRec).isOkOr:
      error info & ": Failed merging account",
        accPath=w.accPath.toStr, `error`=($$error)
      u.nErrors.inc
      return u

    if w.data.account.storageRoot != EMPTY_ROOT_HASH:
      u.nStorage.inc
      let q = db.mergeStoTrie(
        tx, adb, w.accPath, w.data.account.storageRoot, count, info)
      u.nSlots += q.nSlots
      if not q.ok:
        u.nErrors.inc
        if stopOnError:
          return u

    if w.data.account.codeHash != EMPTY_CODE_HASH:
      u.nCodes.inc
      db.mergeCtrCode(tx, adb, w.accPath, w.data.account.codeHash, info).isOkOr:
        u.nErrors.inc
        if stopOnError:
          return u

      count.inc

    u.nAccounts.inc
    count.inc

    # Save regurlarly
    if nCoreDbImportPersistBatch <= count:
      tx.checkpoint(0)
      db.persist tx
      count = 0

  tx.checkpoint(cNum)
  db.persist tx
  u

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
    status = ?adb.getAccMissingIntv(info)
    header = ?adb.getHeader(status.number, info)
    txStats = db.importFlat(tx, adb, stopOnError, info) # import data

  if 0 < txStats.nErrors:
    error info & ": Error importing snap data", number=status.number, txStats
    return err()

  let txStateRoot = ?tx.fetchStateRoot(info)
  if header.stateRoot != txStateRoot:
    error info & ": Dtate roots differ when importing snap data",
      number=status.number, stateRoot=header.stateRoot.toStr,
      expected=txStateRoot.toStr, txStats
    return err()

  ok(txStats)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
