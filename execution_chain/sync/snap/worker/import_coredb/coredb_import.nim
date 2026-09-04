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
  std/paths,
  pkg/[chronicles, eth/common],
  ../../../../db/core_db,
  ../[helpers, cache_db, worker_desc],
  ./coredb_desc

logScope:
  topics = "snap sync"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc mergeAccountImpl(
    tx2: CoreDbTxRef;
    accPath: Hash32;
    account: Account;
    info: static[string];
      ): Opt[void] =
  let accRec = CoreDbAccount(
    nonce:    account.nonce,
    balance:  account.balance,
    codeHash: account.codeHash)
  tx2.mergeAccount(accPath, accRec).isOkOr:
    error info & ": Failed merging account",
      accPath=accPath.toStr, `error`=($$error)
    return err()
  ok()

proc mergeAccAndStoImpl(
    tx2: CoreDbTxRef;
    db: CacheDbRef;
    accPath: Hash32;
    account: Account;
    info: static[string];
      ): Opt[uint] =
  # Save account so that the storage trie can be updated
  ?tx2.mergeAccountImpl(accPath, account, info)

  # Clear storage trie
  tx2.clearStorage(accPath).isOkOr:
    error info & ": Failed clearing storage slots",
      accPath=accPath.toStr, `error`=($$error  )
    return err()

  var nSlots = 0u
  for w in db.walkFlatSlot(accPath):
    if 0 < w.error.len:
      error info & ": Error walking storage slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=w.error
      return err()
    tx2.mergeSlot(accPath, w.slotKey, w.data).isOkOr:
      error info & ": Failed merging slot", accPath=accPath.toStr,
        nSlotsSoFar=nSlots, slotKey=w.slotKey.toStr, `error`=($$error)
      return err()
    nSlots.inc

  ok(nSlots)

proc fetchStorageRootImpl(
    tx2: CoreDbTxRef;
    accPath: Hash32;
    info: static[string];
      ): Opt[Hash32] =
  var stoRoot = tx2.fetchStorageRoot(accPath).valueOr:
    error info & ": Failed computing storage root",
      accPath=accPath.toStr, `error`=($$error)
    return err()
  ok(move stoRoot)

proc fetchStateRootImpl(
    tx2: CoreDbTxRef;
    info: static[string];
      ): Opt[Hash32] =
  var root = tx2.getStateRoot.valueOr:
    error info & ": Failed computing state root", `error`=($$error)
    return err()
  ok(move root)

# -------------------------

proc importFlatImpl(
    tx2: CoreDbTxRef;
    db: CacheDbRef;
    info: static[string];
      ): Opt[AristoImportStats] =
  var u: AristoImportStats
  for w in db.walkFlatAcc():
    if 0 < w.error.len:
      error info & ": Error walking accounts",
        accPath=w.accPath.toStr, `error`=w.error
      return err()

    # Verify that the code and storage are properly updated. No need to
    # test the `storageRoot` as it will be reset to `zeroHash32` when BAL
    # forwarding.
    var nErrors = 0
    if w.data.dirtyCode:
      nErrors.inc
    if w.data.dirtyStorage:
      nErrors.inc
    if w.data.account.codeHash == zeroHash32:
      nErrors.inc
    if 0 < nErrors:
      error info & ": account record is incomplete",
        accPath=w.accPath.toStr,
        dirtyStorage=w.data.dirtyStorage,
        dirtyCode=w.data.dirtyCode,
        codeHash=w.data.account.codeHash.toStr
      return ok((0,0))

    if w.data.account.storageRoot == EMPTY_ROOT_HASH:
      # Save account only
      ?tx2.mergeAccountImpl(w.accPath, w.data.account, info)
    else:
      u.nSlots += ?tx2.mergeAccAndStoImpl(db, w.accPath, w.data.account, info)
    u.nAccounts.inc

  ok(u)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc mergeAccount*(
    db2: CoreDb2Ref;
    accPath: Hash32;
    account: Account;
    info: static[string];
      ): Opt[void] =
  db2.tx2.mergeAccountImpl(accPath, account, info)

proc mergeAccountAndStorage*(
    db2: CoreDb2Ref;
    cdb: CacheDbRef;
    accPath: Hash32;
    account: Account;
    info: static[string];
      ): Opt[(Hash32,uint)] =
  db2.tx2.mergeAccAndStoImpl(cdb, accPath, account, info)

proc importFlat*(
    db2: CoreDb2Ref;
    cdb: CacheDbRef;
    info: static[string];
      ): Opt[AristoImportStats] =
  db2.tx2.importFlatImpl(cdb, info)

proc fetchStorageRoot*(
    db2: CoreDb2Ref;
    accPath: Hash32;
    info: static[string];
      ): Opt[Hash32] =
  db2.tx2.fetchStorageRootImpl(accPath, info)

proc fetchStateRoot*(
    db2: CoreDb2Ref;
    info: static[string];
      ): Opt[Hash32] =
  db2.tx2.fetchStateRootImpl(info)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
