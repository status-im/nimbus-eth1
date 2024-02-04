# Nimbus
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment

import
  std/[sequtils, tables],
  eth/[common, p2p],
  unittest2,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[
    hexary_desc, hexary_error, hexary_inspect,
    snapdb_accounts, snapdb_desc, snapdb_storage_slots],
  ../replay/[pp, undump_accounts, undump_storages],
  ./test_helpers

let
  # Forces `check()` to print the error (as opposed when using `isOk()`)
  OkStoDb = Result[void,seq[(int,HexaryError)]].ok()

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc toStoDbRc(r: seq[HexaryNodeReport]): Result[void,seq[(int,HexaryError)]]=
  ## Kludge: map error report to (older version) return code
  if r.len != 0:
    return err(r.mapIt((it.slot.get(otherwise = -1),it.error)))
  ok()

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_storageAccountsImport*(
    inList: seq[UndumpAccounts];
    dbBase: SnapDbRef;
    persistent: bool;
      ) =
  ## Import and merge accounts lists
  let
    root = inList[0].root

  for w in inList:
    let desc = SnapDbAccountsRef.init(dbBase, root, Peer())
    check desc.importAccounts(w.base, w.data, persistent).isImportOk

proc test_storageSlotsImport*(
    inList: seq[UndumpStorages];
    dbBase: SnapDbRef;
    persistent: bool;
    ignore: KnownStorageFailure;
    idPfx: string;
      ) =
  ## Import and merge storages lists
  let
    skipEntry = ignore.toTable
    dbDesc = SnapDbStorageSlotsRef.init(
      dbBase, NodeKey.default, Hash256(), Peer())

  for n,w in inList:
    let
      testId = idPfx & "#" & $n
      expRc = if skipEntry.hasKey(testId):
                Result[void,seq[(int,HexaryError)]].err(skipEntry[testId])
              else:
                OkStoDb
    check dbDesc.importStorageSlots(w.data, persistent).toStoDbRc == expRc

proc test_storageSlotsTries*(
    inList: seq[UndumpStorages];
    dbBase: SnapDbRef;
    persistent: bool;
    ignore: KnownStorageFailure;
    idPfx: string;
      ) =
  ## Inspecting imported storages lists sub-tries
  let
    skipEntry = ignore.toTable

  for n,w in inList:
    let
      testId = idPfx & "#" & $n
      errInx = if skipEntry.hasKey(testId): skipEntry[testId][0][0]
               else: high(int)
    for m in 0 ..< w.data.storages.len:
      let
        accKey = w.data.storages[m].account.accKey
        root = w.data.storages[m].account.storageRoot
        dbDesc = SnapDbStorageSlotsRef.init(dbBase, accKey, root, Peer())
        rc = dbDesc.inspectStorageSlotsTrie(persistent=persistent)
      if m == errInx:
        check rc == Result[TrieNodeStat,HexaryError].err(TrieIsEmpty)
      else:
        check rc.isOk # ok => level > 0 and not stopped

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
