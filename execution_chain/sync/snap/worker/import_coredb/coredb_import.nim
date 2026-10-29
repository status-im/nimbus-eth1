# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Not for production, yet.
## ------------------------
##
## Module depends on Aristo (maybe in second instance.) This module serves
## as a template how to flush and re-fill production Aristo from the flat
## snap sync tables once they are ready.
##
{.push raises: [].}

import
  pkg/[chronicles, eth/common, stew/interval_set],
  ../../../../db/core_db,
  ../[helpers, cache_db, worker_desc]

logScope:
  topics = "snap sync"

type
  CoredbImportStats* = tuple
    nAccounts: uint
    nStorage: uint
    nStoRoot: uint
    nSlots: uint
    nCodes: uint
    nErrors: uint

# ------------------------------------------------------------------------------
# Private functions
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

proc mergeAccount(
    tx: CoreDbTxRef;
    accPath: Hash32;
    account: Account;
    info: static[string];
      ): Opt[void] =
  let accRec = CoreDbAccount(
    nonce:    account.nonce,
    balance:  account.balance,
    codeHash: account.codeHash)
  tx.mergeAccount(accPath, accRec).isOkOr:
    error info & ": Failed merging account",
      accPath=accPath.toStr, `error`=($$error)
    return err()
  ok()

proc mergeAccAndSto(
    db: CoreDbRef;
    tx: CoreDbTxRef;
    adb: CacheDbRef;
    accPath: Hash32;
    account: Account;
    count: var int;
    info: static[string];
      ): tuple[nSlots: uint, stoRoot: bool, ok: bool] =
  # Save account so that the storage trie can be updated
  tx.mergeAccount(accPath, account, info).isOkOr:
    return (0,false,false)

  # Clear storage trie
  tx.clearStorage(accPath).isOkOr:
    error info & ": Failed clearing storage slots",
      accPath=accPath.toStr, `error`=($$error)
    return (0,false,false)

  var nSlots = 0u
  for w in adb.walkFlatSlot(accPath):
    if 0 < w.error.len:
      error info & ": Error walking storage slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=w.error
      return (nSlots,false,false)
    tx.mergeSlot(accPath, w.slotKey, w.data).isOkOr:
      error info & ": Failed merging slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=($$error)
      return (nSlots,false,false)

    nSlots.inc
    count.inc

    # Save regurlarly
    if nCoreDbImportPersistBatch <= count:
      tx.checkpoint(0)
      db.persist tx
      count = 0

  # Verify storage sub-MPT if there is a storage root. It is set to zero by
  # the BAL forwarder when there were changes to the sub-MPT. If the sub-MPT
  # was complete, no `storeageRoot` update will have taken place.
  if account.storageRoot != zeroHash32:
    var stoRoot = tx.fetchStorageRoot(accPath).valueOr:
      error info & ": Failed computing storage root", nSlots,
        accPath=accPath.toStr, `error`=($$error)
      return (nSlots,true,false)
    if account.storageRoot != stoRoot:
      error info & ": Mismatch with pre-set storage root", nSlots,
        accPath=accPath.toStr, stoRoot=stoRoot.toStr,
        expected=account.storageRoot.toStr
      return (nSlots,true,false)
    return (nSlots,true,true)

  (nSlots,false,true)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchStateRoot*(
    tx: CoreDbTxRef;
    info: static[string];
      ): Opt[Hash32] =
  var root = tx.getStateRoot.valueOr:
    error info & ": Failed computing state root", `error`=($$error)
    return err()
  ok(move root)

proc importFlat*(
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
        if w.data.account.codeHash == zeroHash32:
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

    if w.data.account.storageRoot == EMPTY_ROOT_HASH:
      # Save account only
      tx.mergeAccount(w.accPath, w.data.account, info).isOkOr:
        u.nErrors.inc
        return u
    else:
      let w = db.mergeAccAndSto(
        tx, adb, w.accPath, w.data.account, count, info)
      u.nSlots += w.nSlots
      u.nStorage.inc
      if w.stoRoot:
        u.nStoRoot.inc
      if not w.ok:
        u.nErrors.inc
        if stopOnError:
          return u

    if w.data.account.codeHash != EMPTY_CODE_HASH:
      let rc = adb.getFlatCode(w.accPath, info)
      if rc.isErr:
        error info & ": No suc contract code", accPath=w.accPath.toStr,
          codeHash=w.data.account.codeHash.toStr
        u.nErrors.inc
        if stopOnError:
          return u
      else:
        tx.persistCodeByHash(w.data.account.codeHash, rc.value).isOkOr:
          error info & ": Failed storing contract code",
            accPath=w.accPath.toStr, codeHash=w.data.account.codeHash.toStr,
            nCode=rc.value.len, `error`=error
          u.nErrors.inc
          return u
        u.nCodes.inc
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
# End
# ------------------------------------------------------------------------------
