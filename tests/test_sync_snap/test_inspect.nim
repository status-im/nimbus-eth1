# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Snap sync components tester and TDD environment

import
  std/[sequtils, strformat, strutils],
  eth/[common, p2p, trie/db],
  unittest2,
  ../../nimbus/db/select_backend,
  ../../nimbus/sync/snap/range_desc,
  ../../nimbus/sync/snap/worker/db/[
    hexary_desc, hexary_error, hexary_inspect, hexary_paths,
    rocky_bulk_load, snapdb_accounts, snapdb_desc],
  ../replay/[pp, undump_accounts]

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc isImportOk(rc: Result[SnapAccountsGaps,HexaryError]): bool =
  if rc.isErr:
    check rc.error == NothingSerious # prints an error if different
  elif 0 < rc.value.innerGaps.len:
    check rc.value.innerGaps == seq[NodeSpecs].default
  else:
    return true

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_inspectSingleAccountsMemDb*(
    inList: seq[seq[UndumpAccounts]];
    memBase: SnapDbRef;
    singleStats: var seq[(int,TrieNodeStat)];
      ) =
  ## Fingerprinting single accounts lists for in-memory-db (modifies
  ## `singleStats`)
  for n,accList in inList:
    # Separate storage
    let
      root = accList[0].root
      rootKey = root.to(NodeKey)
      desc = SnapDbAccountsRef.init(memBase, root, Peer())
    for w in accList:
      check desc.importAccounts(w.base, w.data, persistent=false).isImportOk
    let stats = desc.hexaDb.hexaryInspectTrie(rootKey)
    check not stats.stopped
    let
      dangling = stats.dangling.mapIt(it.partialPath)
      keys = dangling.hexaryPathNodeKeys(
        rootKey, desc.hexaDb, missingOk=true)
    check dangling.len == keys.len
    singleStats.add (desc.hexaDb.tab.len,stats)

    # Verify piecemeal approach for `hexaryInspectTrie()` ...
    var
      ctx = TrieNodeStatCtxRef()
      piecemeal: HashSet[Blob]
    while not ctx.isNil:
      let stat2 = desc.hexaDb.hexaryInspectTrie(
        rootKey, resumeCtx=ctx, suspendAfter=128)
      check not stat2.stopped
      ctx = stat2.resumeCtx
      piecemeal.incl stat2.dangling.mapIt(it.partialPath).toHashSet
    # Must match earlier all-in-one result
    check dangling.len == piecemeal.len
    check dangling.toHashSet == piecemeal

proc test_inspectSingleAccountsPersistent*(
    inList: seq[seq[UndumpAccounts]];
    dbSlotCb: proc(n: int): SnapDbRef;
    singleStats: seq[(int,TrieNodeStat)];
      ) =
  ## Fingerprinting single accounts listsfor persistent db"
  for n,accList in inList:
    let
      root = accList[0].root
      rootKey = root.to(NodeKey)
      dbBase = n.dbSlotCb
    if dbBase.isNil:
      break
    # Separate storage on persistent DB (leaving first db slot empty)
    let desc = SnapDbAccountsRef.init(dbBase, root, Peer())

    for w in accList:
      check desc.importAccounts(w.base,w.data, persistent=true).isImportOk
    let stats = desc.getAccountFn.hexaryInspectTrie(rootKey)
    check not stats.stopped
    let
      dangling = stats.dangling.mapIt(it.partialPath)
      keys = dangling.hexaryPathNodeKeys(
        rootKey, desc.hexaDb, missingOk=true)
    check dangling.len == keys.len
    # Must be the same as the in-memory fingerprint
    let ssn1 = singleStats[n][1].dangling.mapIt(it.partialPath)
    check ssn1.toHashSet == dangling.toHashSet

    # Verify piecemeal approach for `hexaryInspectTrie()` ...
    var
      ctx = TrieNodeStatCtxRef()
      piecemeal: HashSet[Blob]
    while not ctx.isNil:
      let stat2 = desc.getAccountFn.hexaryInspectTrie(
        rootKey, resumeCtx=ctx, suspendAfter=128)
      check not stat2.stopped
      ctx = stat2.resumeCtx
      piecemeal.incl stat2.dangling.mapIt(it.partialPath).toHashSet
    # Must match earlier all-in-one result
    check dangling.len == piecemeal.len
    check dangling.toHashSet == piecemeal
 
proc test_inspectAccountsInMemDb*(
    inList: seq[seq[UndumpAccounts]];
    memBase: SnapDbRef;
    accuStats: var seq[(int,TrieNodeStat)];
      ) =
  ## Fingerprinting accumulated accounts for in-memory-db (updates `accuStats`)
  let memDesc = SnapDbAccountsRef.init(memBase, Hash256(), Peer())

  for n,accList in inList:
    # Accumulated storage
    let
      root = accList[0].root
      rootKey = root.to(NodeKey)
      desc = memDesc.dup(root,Peer())
    for w in accList:
      check desc.importAccounts(w.base, w.data, persistent=false).isImportOk
    let stats = desc.hexaDb.hexaryInspectTrie(rootKey)
    check not stats.stopped
    let
      dangling = stats.dangling.mapIt(it.partialPath)
      keys = dangling.hexaryPathNodeKeys(
        rootKey, desc.hexaDb, missingOk=true)
    check dangling.len == keys.len
    accuStats.add (desc.hexaDb.tab.len, stats)

proc test_inspectAccountsPersistent*(
    inList: seq[seq[UndumpAccounts]];
    cdb: ChainDb;
    accuStats: seq[(int,TrieNodeStat)];
      ) =
  ## Fingerprinting accumulated accounts for persistent db
  let
    perBase = SnapDbRef.init(cdb)
    perDesc = SnapDbAccountsRef.init(perBase, Hash256(), Peer())

  for n,accList in inList:
    # Accumulated storage on persistent DB (using first db slot)
    let
      root = accList[0].root
      rootKey = root.to(NodeKey)
      rootSet = [rootKey].toHashSet
      desc = perDesc.dup(root,Peer())
    for w in accList:
      check desc.importAccounts(w.base, w.data, persistent=true).isImportOk
    let stats = desc.getAccountFn.hexaryInspectTrie(rootKey)
    check not stats.stopped
    let
      dangling = stats.dangling.mapIt(it.partialPath)
      keys = dangling.hexaryPathNodeKeys(
        rootKey, desc.hexaDb, missingOk=true)
    check dangling.len == keys.len
    check accuStats[n][1] == stats

proc test_inspectCascadedMemDb*(
    inList: seq[seq[UndumpAccounts]];
      ) =
  ## Cascaded fingerprinting accounts for in-memory-db
  let
    cscBase = SnapDbRef.init(newMemoryDB())
    cscDesc = SnapDbAccountsRef.init(cscBase, Hash256(), Peer())
  var
    cscStep: Table[NodeKey,(int,seq[Blob])]

  for n,accList in inList:
    # Accumulated storage
    let
      root = accList[0].root
      rootKey = root.to(NodeKey)
      desc = cscDesc.dup(root,Peer())
    for w in accList:
      check desc.importAccounts(w.base, w.data, persistent=false).isImportOk
    if cscStep.hasKeyOrPut(rootKey, (1, seq[Blob].default)):
      cscStep[rootKey][0].inc
    let
      stat0 = desc.hexaDb.hexaryInspectTrie(rootKey)
      stats = desc.hexaDb.hexaryInspectTrie(rootKey, cscStep[rootKey][1])
    check not stat0.stopped
    check not stats.stopped
    let
      accumulated = stat0.dangling.mapIt(it.partialPath).toHashSet
      cascaded = stats.dangling.mapIt(it.partialPath).toHashSet
    check accumulated == cascaded
  # Make sure that there are no trivial cases
  let trivialCases = toSeq(cscStep.values).filterIt(it[0] <= 1).len
  check trivialCases == 0

proc test_inspectCascadedPersistent*(
    inList: seq[seq[UndumpAccounts]];
    cdb: ChainDb;
      ) =
  ## Cascaded fingerprinting accounts for persistent db
  let
    cscBase = SnapDbRef.init(cdb)
    cscDesc = SnapDbAccountsRef.init(cscBase, Hash256(), Peer())
  var
    cscStep: Table[NodeKey,(int,seq[Blob])]

  for n,accList in inList:
    # Accumulated storage
    let
      root = accList[0].root
      rootKey = root.to(NodeKey)
      desc = cscDesc.dup(root, Peer())
    for w in accList:
      check desc.importAccounts(w.base, w.data, persistent=true).isImportOk
    if cscStep.hasKeyOrPut(rootKey, (1, seq[Blob].default)):
      cscStep[rootKey][0].inc
    let
      stat0 = desc.getAccountFn.hexaryInspectTrie(rootKey)
      stats = desc.getAccountFn.hexaryInspectTrie(rootKey, cscStep[rootKey][1])
    check not stat0.stopped
    check not stats.stopped
    let
      accumulated = stat0.dangling.mapIt(it.partialPath).toHashSet
      cascaded = stats.dangling.mapIt(it.partialPath).toHashSet
    check accumulated == cascaded
  # Make sure that there are no trivial cases
  let trivialCases = toSeq(cscStep.values).filterIt(it[0] <= 1).len
  check trivialCases == 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
