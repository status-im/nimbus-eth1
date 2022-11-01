# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Check/analyse DB completeness
## =============================

import
  chronicles,
  eth/[common, p2p, trie/trie_defs],
  stew/keyed_queue,
  ../../../../utils/prettify,
  ../../../sync_desc,
  "../.."/[range_desc, worker_desc],
  "."/[hexary_desc, hexary_error, snapdb_accounts, snapdb_storage_slots]

{.push raises: [Defect].}

logScope:
  topics = "snap-db"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Check DB " & info

proc accountsCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string =
  let
    ctx = buddy.ctx
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "nAccounts=" & $env.nAccounts & "," &
    ("covered=" & env.fetchAccounts.unprocessed.emptyFactor.toPC(0) & "/" &
        ctx.data.coveredAccounts.fullFactor.toPC(0)) & "," &
    "nCheckNodes=" & $env.fetchAccounts.checkNodes.len & "," &
    "nMissingNodes=" & $env.fetchAccounts.missingNodes.len & "}"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc storageSlotsCtx(
    buddy: SnapBuddyRef;
    storageRoot: Hash256;
    env: SnapPivotRef;
      ): string =
  let
    ctx = buddy.ctx
    rc = env.fetchStorage.eq(storageRoot)
  if rc.isErr:
    return "n/a"
  let
    data = rc.value
    slots = data.slots
  result = "{" &
    "inherit=" & (if data.inherit: "t" else: "f") & ","
  if not slots.isNil:
    result &= "" &
      "covered=" & slots.unprocessed.emptyFactor.toPC(0) &
      "nCheckNodes=" & $slots.checkNodes.len & "," &
      "nMissingNodes=" & $slots.missingNodes.len
  result &= "}"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc checkStorageSlotsTrie(
    buddy: SnapBuddyRef;
    accKey: NodeKey;
    storageRoot: Hash256;
    env: SnapPivotRef;
      ): Result[bool,HexaryDbError] =
  ## Check whether a storage slots hexary trie is complete.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer

    rc = db.inspectStorageSlotsTrie(peer, accKey, storageRoot)

  if rc.isErr:
    return err(rc.error)

  ok(rc.value.dangling.len == 0)


iterator accountsWalk(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): (NodeKey,Account,HexaryDbError) =
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot
    walk = SnapDbAccountsRef.init(db, stateRoot, peer)

  var
    accKey = NodeKey.default
    count = 0
    runOk = true

  while runOk:
    count.inc

    let nextKey = block:
      let rc = walk.nextAccountsChainDbKey(accKey)
      if rc.isErr:
        if rc.error != AccountNotFound:
          error logTxt "accounts walk stopped", peer,
            account=accKey.to(NodeTag),
            ctx=buddy.accountsCtx(env), count, reason=rc.error
        runOk = false
        continue
      rc.value

    accKey = nextKey

    let accData = block:
      let rc = walk.getAccountsData(accKey, persistent = true)
      if rc.isErr:
        error logTxt "accounts walk error", peer, account=accKey,
          ctx=buddy.accountsCtx(env), count, error=rc.error
        runOk = false
        continue
      rc.value

    yield (accKey, accData, NothingSerious)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc checkAccountsTrieIsComplete*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): bool =
  ## Check whether accounts hexary trie is complete
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot

    rc = db.inspectAccountsTrie(peer, stateRoot)

  if rc.isErr:
    error logTxt "accounts health check failed", peer,
      ctx=buddy.accountsCtx(env), error=rc.error
    return false

  rc.value.dangling.len == 0


proc checkAccountsListOk*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
    noisy = false;
      ): bool =
  ## Loop over accounts, returns `false` for some error.
  let
    ctx = buddy.ctx
    peer = buddy.peer
  var
    accounts = 0
    storage = 0
    nextMsgThresh = 1

  for (key,accData,error) in buddy.accountsWalk(env):

    if error != NothingSerious:
      error logTxt "accounts loop stopped", peer, ctx=buddy.accountsCtx(env),
        accounts, storage, error
      return false

    accounts.inc
    if accData.storageRoot != emptyRlpHash:
      storage.inc

    when extraTraceMessages:
      if noisy and nextMsgThresh <= accounts:
        debug logTxt "accounts loop check point", peer,
          ctx=buddy.accountsCtx(env), accounts, storage
        nextMsgThresh *= 2

  when extraTraceMessages:
    let isComplete = buddy.checkAccountsTrieIsComplete(env)
    debug logTxt "accounts list report", peer, ctx=buddy.accountsCtx(env),
      accounts, storage, isComplete

  true


proc checkStorageSlotsTrieIsComplete*(
    buddy: SnapBuddyRef;
    accKey: NodeKey;
    storageRoot: Hash256;
    env: SnapPivotRef;
      ): bool =
  ## Check whether a storage slots hexary trie is complete.
  let
    peer = buddy.peer
    rc = buddy.checkStorageSlotsTrie(accKey, storageRoot, env)
  if rc.isOk:
    return rc.value

  when extraTraceMessages:
    debug logTxt "atorage slots health check failed", peer,
      nStoQueue=env.fetchStorage.len,
      ctx=buddy.storageSlotsCtx(storageRoot, env), error=rc.error

proc checkStorageSlotsTrieIsComplete*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): bool =
  ## Check for all accounts thye whether storage slot hexary tries are complete.
  let
    ctx = buddy.ctx
    peer = buddy.peer
  var
    accounts = 0
    incomplete = 0
    complete = 0

  for (accKey,accData,error) in buddy.accountsWalk(env):
    if error != NothingSerious:
      error logTxt "atorage slots accounts loop stopped", peer,
        nStoQueue=env.fetchStorage.len, accounts, incomplete, complete, error
      return false

    accounts.inc
    let storageRoot = accData.storageRoot
    if storageRoot == emptyRlpHash:
      continue

    let rc = buddy.checkStorageSlotsTrie(accKey, storageRoot, env)
    if rc.isOk and rc.value:
      complete.inc
    else:
      incomplete.inc

  when extraTraceMessages:
    debug logTxt "storage slots report", peer, ctx=buddy.accountsCtx(env),
      nStoQueue=env.fetchStorage.len, accounts, incomplete, complete

  0 < accounts and incomplete == 0

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
