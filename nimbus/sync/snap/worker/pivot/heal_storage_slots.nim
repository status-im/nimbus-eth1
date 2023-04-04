# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Heal storage slots DB
## =====================
##
## This module works similar to `heal_accounts` applied to each per-account
## storage slots hexary trie. These per-account trie work items  are stored in
## the queue `env.fetchStoragePart`.
##
## There is another such queue `env.fetchStorageFull` which is not used here.
##
## In order to be able to checkpoint the current list of storage accounts (by
## a parallel running process), unfinished storage accounts are temporarily
## held in the set `env.parkedStorage`.
##
## Algorithm applied to each entry of `env.fetchStoragePart`
## --------------------------------------------------------
##
## * Find dangling nodes in the current slot trie  via `findMissingNodes()`.
##
## * Install that nodes from the network.
##
## * Rinse and repeat
##
## Discussion
## ----------
##
## A worst case scenario of a portentally failing `findMissingNodes()` call
## must be solved by fetching and storing more storage slots and running this
## healing algorithm again.
##

{.push raises: [].}

import
  std/[math, sequtils, sets, tables],
  chronicles,
  chronos,
  eth/[common, p2p, trie/nibbles],
  stew/[byteutils, interval_set, keyed_queue],
  ../../../../utils/prettify,
  "../../.."/[sync_desc, protocol, types],
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_trie_nodes],
  ../db/[hexary_desc, hexary_envelope, hexary_error, hexary_range,
         snapdb_storage_slots],
  "."/[find_missing_nodes, storage_queue_helper]

logScope:
  topics = "snap-slot"

const
  extraTraceMessages = false # or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Storage slots heal " & info

proc `$`(node: NodeSpecs): string =
  node.partialPath.toHex

proc `$`(rs: NodeTagRangeSet): string =
  rs.fullPC3

proc `$`(iv: NodeTagRange): string =
  iv.fullPC3

proc toPC(w: openArray[NodeSpecs]; n: static[int] = 3): string =
  let sumUp = w.mapIt(it.hexaryEnvelope.len).foldl(a+b, 0.u256)
  (sumUp.to(float) / (2.0^256)).toPC(n)

proc healingCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string {.used.} =
  "{" &
    "piv=" & "#" & $env.stateHeader.blockNumber & "," &
    "ctl=" & $buddy.ctrl.state & "," &
    "nStoQu=" & $env.storageQueueTotal() & "," &
    "nQuPart=" & $env.fetchStoragePart.len & "," &
    "nParked=" & $env.parkedStorage.len & "," &
    "nSlotLists=" & $env.nSlotLists & "}"

proc healingCtx(
    buddy: SnapBuddyRef;
    kvp: StoQuSlotsKVP;
    env: SnapPivotRef;
      ): string =
  "{" &
    "piv=" & "#" & $env.stateHeader.blockNumber & "," &
    "ctl=" & $buddy.ctrl.state & "," &
    "processed=" & $kvp.data.slots.processed & "," &
    "nStoQu=" & $env.storageQueueTotal() & "," &
    "nQuPart=" & $env.fetchStoragePart.len & "," &
    "nParked=" & $env.parkedStorage.len & "," &
    "nSlotLists=" & $env.nSlotLists & "}"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template discardRlpError(info: static[string]; code: untyped) =
  try:
    code
  except RlpError:
    discard

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc compileMissingNodesList(
    buddy: SnapBuddyRef;
    kvp: StoQuSlotsKVP;
    env: SnapPivotRef;
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ## Find some missing glue nodes in storage slots database.
  let
    ctx = buddy.ctx
    peer {.used.} = buddy.peer
    slots = kvp.data.slots
    rootKey = kvp.key.to(NodeKey)
    getFn = ctx.pool.snapDb.getStorageSlotsFn(kvp.data.accKey)

  if not slots.processed.isFull:
    let mlv = await slots.findMissingNodes(
      rootKey, getFn,
      healStorageSlotsInspectionPlanBLevel,
      healStorageSlotsInspectionPlanBRetryMax,
      healStorageSlotsInspectionPlanBRetryNapMSecs,
      forcePlanBOk = true)

    # Clean up empty account ranges found while looking for nodes
    if not mlv.emptyGaps.isNil:
      for w in mlv.emptyGaps.increasing:
        discard slots.processed.merge w
        slots.unprocessed.reduce w

    when extraTraceMessages:
      trace logTxt "missing nodes", peer,
        ctx=buddy.healingCtx(env), nLevel=mlv.level, nVisited=mlv.visited,
        nResult=mlv.missing.len, result=mlv.missing.toPC

    return mlv.missing


proc getNodesFromNetwork(
    buddy: SnapBuddyRef;
    missingNodes: seq[NodeSpecs];       # Nodes to fetch from the network
    ignore: HashSet[Blob];              # Except for these partial paths listed
    kvp: StoQuSlotsKVP;                 # Storage slots context
    env: SnapPivotRef;                  # For logging
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ##  Extract from `missing` the next batch of nodes that need
  ## to be merged it into the database
  let
    peer {.used.} = buddy.peer
    accPath = kvp.data.accKey.to(Blob)
    rootHash = env.stateHeader.stateRoot
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  # Initalise for fetching nodes from the network via `getTrieNodes()`
  var
    nodeKey: Table[Blob,NodeKey]          # Temporary `path -> key` mapping
    req = SnapTriePaths(accPath: accPath) # Argument for `getTrieNodes()`

  # There is no point in fetching too many nodes as it will be rejected. So
  # rest of the `missingNodes` list is ignored to be picked up later.
  for w in missingNodes:
    if w.partialPath notin ignore and not nodeKey.hasKey(w.partialPath):
      req.slotPaths.add w.partialPath
      nodeKey[w.partialPath] = w.nodeKey
      if fetchRequestTrieNodesMax <= req.slotPaths.len:
        break

  if 0 < req.slotPaths.len:
    # Fetch nodes from the network.
    let rc = await buddy.getTrieNodes(rootHash, @[req], pivot)
    if rc.isOk:
      # Reset error counts for detecting repeated timeouts, network errors, etc.
      buddy.only.errors.resetComError()

      return rc.value.nodes.mapIt(NodeSpecs(
        partialPath: it.partialPath,
        nodeKey:     nodeKey[it.partialPath],
        data:        it.data))

    # Process error ...
    let
      error = rc.error
      ok = await buddy.ctrl.stopAfterSeriousComError(error, buddy.only.errors)
    when extraTraceMessages:
      trace logTxt "reply error", peer, ctx=buddy.healingCtx(kvp,env),
        error, stop=ok

  return @[]


proc kvStoSlotsLeaf(
    buddy: SnapBuddyRef;
    node: NodeSpecs;                    # Node data fetched from network
    kvp: StoQuSlotsKVP;                 # For logging
    env: SnapPivotRef;                  # For logging
      ): (bool,NodeKey) =
  ## Re-read leaf node from persistent database (if any)
  var nNibbles = -1
  discardRlpError("kvStorageSlotsLeaf"):
    let
      nodeRlp = rlpFromBytes node.data
      prefix = (hexPrefixDecode node.partialPath)[1]
      segment = (hexPrefixDecode nodeRlp.listElem(0).toBytes)[1]
      nibbles = prefix & segment

    nNibbles = nibbles.len
    if nNibbles == 64:
      return (true, nibbles.getBytes.convertTo(NodeKey))

  when extraTraceMessages:
    trace logTxt "non-leaf node path or corrupt data", peer=buddy.peer,
      ctx=buddy.healingCtx(kvp,env), nNibbles


proc registerStoSlotsLeaf(
    buddy: SnapBuddyRef;
    slotKey: NodeKey;
    kvp: StoQuSlotsKVP;
    env: SnapPivotRef;
      ) =
  ## Process single account node as would be done with an interval by
  ## the `storeAccounts()` function
  let
    ctx = buddy.ctx
    peer = buddy.peer
    rootKey = kvp.key.to(NodeKey)
    getSlotFn = ctx.pool.snapDb.getStorageSlotsFn kvp.data.accKey
    pt = slotKey.to(NodeTag)

  # Extend interval [pt,pt] if possible
  var iv: NodeTagRange
  try:
    iv = getSlotFn.hexaryRangeInflate(rootKey, pt)
  except CatchableError as e:
    error logTxt "inflating interval oops", peer, ctx=buddy.healingCtx(kvp,env),
      accKey=kvp.data.accKey, slotKey, name=($e.name), msg=e.msg
    iv = NodeTagRange.new(pt,pt)

  # Register isolated leaf node
  if 0 < kvp.data.slots.processed.merge iv:
    kvp.data.slots.unprocessed.reduce iv

  when extraTraceMessages:
    trace logTxt "registered single slot", peer, ctx=buddy.healingCtx(env),
      leftSlack=(iv.minPt < pt), rightSlack=(pt < iv.maxPt)

# ------------------------------------------------------------------------------
# Private functions: do the healing for one work item (sub-trie)
# ------------------------------------------------------------------------------

proc stoSlotsHealingImpl(
    buddy: SnapBuddyRef;
    ignore: HashSet[Blob];           # Except for these partial paths listed
    kvp: StoQuSlotsKVP;
    env: SnapPivotRef;
      ): Future[(int,HashSet[Blob])]
      {.async.} =
  ## Returns `true` is the sub-trie is complete (probably inherited), and
  ## `false` if there are nodes left to be completed.
  let
    ctx = buddy.ctx
    db = ctx.pool.snapDb
    peer = buddy.peer
    missing = await buddy.compileMissingNodesList(kvp, env)

  if missing.len == 0:
    trace logTxt "nothing to do", peer, ctx=buddy.healingCtx(kvp,env)
    return (0,EmptyBlobSet) # nothing to do

  # Get next batch of nodes that need to be merged it into the database
  let fetchedNodes = await buddy.getNodesFromNetwork(missing, ignore, kvp, env)
  if fetchedNodes.len == 0:
    when extraTraceMessages:
      trace logTxt "node set unavailable", nMissing=missing.len
    return (0,EmptyBlobSet)

  # Store nodes onto disk
  let
    nFetchedNodes = fetchedNodes.len
    report = db.importRawStorageSlotsNodes(peer, kvp.data.accKey, fetchedNodes)

  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    error logTxt "database error", peer, ctx=buddy.healingCtx(kvp,env),
      nFetchedNodes, error=report[^1].error
    return (-1,EmptyBlobSet)

  # Filter out leaf nodes
  var
    nLeafNodes = 0 # for logging
    rejected: HashSet[Blob]
  trace logTxt "importRawStorageSlotsNodes", nReport=report.len #########
  for w in report:
    if w.slot.isSome: # non-indexed entries appear typically at the end, though
      let inx = w.slot.unsafeGet

      # Node error, will need to pick up later and download again. Node that
      # there need not be an expicit node specs (so `kind` is opted out.)
      if w.kind.isNone or w.error != HexaryError(0):
        rejected.incl fetchedNodes[inx].partialPath

      elif w.kind.unsafeGet == Leaf:
        # Leaf node has been stored, double check
        let (isLeaf, key) = buddy.kvStoSlotsLeaf(fetchedNodes[inx], kvp, env)
        if isLeaf:
          # Update `unprocessed` registry, collect storage roots (if any)
          buddy.registerStoSlotsLeaf(key, kvp, env)
          nLeafNodes.inc

  when extraTraceMessages:
    trace logTxt "merged into database", peer, ctx=buddy.healingCtx(kvp,env),
      nLeafNodes

  return (nFetchedNodes - rejected.len, rejected)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healStorageSlots*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetching and merging missing slorage slots trie database nodes.
  trace logTxt "started", peer=buddy.peer, ctx=buddy.healingCtx(env)

  var
    nNodesFetched = 0
    nFetchLoop = 0
    ignore: HashSet[Blob]
    visited: HashSet[NodeKey]

  while buddy.ctrl.running and
        visited.len <= healStorageSlotsBatchMax and
        ignore.len <= healStorageSlotsFailedMax and
        not env.archived:
    # Pull out the next request list from the queue
    let kvp = block:
      let rc = env.storageQueueUnlinkPartialItem visited
      if rc.isErr:
        when extraTraceMessages:
          trace logTxt "queue exhausted", peer=buddy.peer,
            ctx=buddy.healingCtx(env), nIgnore=ignore.len, nVisited=visited.len
        break
      rc.value

    nFetchLoop.inc

    # Process request range for healing
    let (nNodes, rejected) = await buddy.stoSlotsHealingImpl(ignore, kvp, env)
    if kvp.data.slots.processed.isFull:
      env.nSlotLists.inc
      env.parkedStorage.excl kvp.data.accKey
    else:
      # Re-queue again, to be re-processed in another cycle
      visited.incl kvp.data.accKey
      env.storageQueueAppend kvp

    ignore = ignore + rejected
    nNodesFetched.inc(nNodes)

  trace logTxt "done", peer=buddy.peer, ctx=buddy.healingCtx(env),
    nNodesFetched, nFetchLoop, nIgnore=ignore.len, nVisited=visited.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
