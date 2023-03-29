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
  std/[math, sequtils, tables],
  chronicles,
  chronos,
  eth/[common, p2p, trie/nibbles],
  stew/[byteutils, interval_set, keyed_queue],
  ../../../../utils/prettify,
  "../../.."/[sync_desc, protocol, types],
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_trie_nodes],
  ../db/[hexary_desc, hexary_envelope, snapdb_storage_slots],
  "."/[find_missing_nodes, storage_queue_helper]

logScope:
  topics = "snap-heal"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Storage slots healing " & info

proc `$`(node: NodeSpecs): string =
  node.partialPath.toHex

proc `$`(rs: NodeTagRangeSet): string =
  rs.fullFactor.toPC(0)

proc `$`(iv: NodeTagRange): string =
  iv.fullFactor.toPC(3)

proc toPC(w: openArray[NodeSpecs]; n: static[int] = 3): string =
  let sumUp = w.mapIt(it.hexaryEnvelope.len).foldl(a+b, 0.u256)
  (sumUp.to(float) / (2.0^256)).toPC(n)

proc healingCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string {.used.} =
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "runState=" & $buddy.ctrl.state & "," &
    "nStoQu=" & $env.storageQueueTotal() & "," &
    "nSlotLists=" & $env.nSlotLists & "}"

proc healingCtx(
    buddy: SnapBuddyRef;
    kvp: StoQuSlotsKVP;
    env: SnapPivotRef;
      ): string =
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "runState=" & $buddy.ctrl.state & "," &
    "covered=" & $kvp.data.slots.processed & "," &
    "nStoQu=" & $env.storageQueueTotal() & "," &
    "nSlotLists=" & $env.nSlotLists & "}"

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template noExceptionOops(info: static[string]; code: untyped) =
  try:
    code
  except CatchableError as e:
    raiseAssert "Inconveivable (" &
      info & "): name=" & $e.name & " msg=" & e.msg

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
      healStorageSlotsInspectionPlanBRetryNapMSecs)

    when extraTraceMessages:
      trace logTxt "missing nodes", peer,
        ctx=buddy.healingCtx(env), nLevel=mlv.level, nVisited=mlv.visited,
        nResult=mlv.missing.len, result=mlv.missing.toPC

    return mlv.missing


proc getNodesFromNetwork(
    buddy: SnapBuddyRef;
    kvp: StoQuSlotsKVP;
    missingNodes: seq[NodeSpecs];       # Nodes to fetch from the network
    ignore: HashSet[Blob];              # Except for these partial paths listed
    env: SnapPivotRef;
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ##  Extract from `missing` the next batch of nodes that need
  ## to be merged it into the database
  let
    ctx {.used.} = buddy.ctx
    peer {.used.} = buddy.peer
    accPath = kvp.data.accKey.to(Blob)
    storageRoot = kvp.key
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
    let rc = await buddy.getTrieNodes(storageRoot, @[req], pivot)
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


proc slotKey(node: NodeSpecs): (bool,NodeKey) =
  ## Read leaf node from persistent database (if any)
  try:
    let
      nodeRlp = rlpFromBytes node.data
      (_,prefix) = hexPrefixDecode node.partialPath
      (_,segment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
      nibbles = prefix & segment
    if nibbles.len == 64:
      return (true, nibbles.getBytes.convertTo(NodeKey))
  except CatchableError:
    discard

# ------------------------------------------------------------------------------
# Private functions: do the healing for one work item (sub-trie)
# ------------------------------------------------------------------------------

proc storageSlotsHealing(
    buddy: SnapBuddyRef;
    kvp: StoQuSlotsKVP;
    ignore: HashSet[Blob];           # Except for these partial paths listed
    env: SnapPivotRef;
      ) {.async.} =
  ## Returns `true` is the sub-trie is complete (probably inherited), and
  ## `false` if there are nodes left to be completed.
  let
    ctx = buddy.ctx
    db = ctx.pool.snapDb
    peer = buddy.peer
    missing = await buddy.compileMissingNodesList(kvp, env)

  if missing.len == 0:
    trace logTxt "nothing to do", peer, ctx=buddy.healingCtx(kvp,env)
    return

  when extraTraceMessages:
    trace logTxt "started", peer, ctx=buddy.healingCtx(kvp,env)

  # Get next batch of nodes that need to be merged it into the database
  let nodeSpecs = await buddy.getNodesFromNetwork(kvp, missing, ignore, env)
  if nodeSpecs.len == 0:
    return

  # Store nodes onto disk
  let report = db.importRawStorageSlotsNodes(peer, kvp.data.accKey, nodeSpecs)
  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    error logTxt "database error", peer, ctx=buddy.healingCtx(kvp,env),
      nNodes=nodeSpecs.len, error=report[^1].error
    return

  when extraTraceMessages:
    trace logTxt "nodes merged into database", peer,
      ctx=buddy.healingCtx(kvp,env), nNodes=nodeSpecs.len

  # Filter out leaf nodes
  var nLeafNodes = 0 # for logging
  for w in report:
    if w.slot.isSome and w.kind.get(otherwise = Branch) == Leaf:

      # Leaf Node has been stored, so register it
      let
        inx = w.slot.unsafeGet
        (isLeaf, slotKey) = nodeSpecs[inx].slotKey
      if isLeaf:
        let
          slotTag = slotKey.to(NodeTag)
          iv = NodeTagRange.new(slotTag,slotTag)
        kvp.data.slots.unprocessed.reduce iv
        discard kvp.data.slots.processed.merge iv
        nLeafNodes.inc

        when extraTraceMessages:
          trace logTxt "stored slot", peer,
            ctx=buddy.healingCtx(kvp,env), slotKey=slotTag

  when extraTraceMessages:
    trace logTxt "job done", peer, ctx=buddy.healingCtx(kvp,env), nLeafNodes

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healStorageSlots*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetching and merging missing slorage slots trie database nodes.
  let
    ctx {.used.} = buddy.ctx
    peer {.used.} = buddy.peer

  # Extract healing slot items from partial slots list
  var toBeHealed: seq[StoQuSlotsKVP]
  for kvp in env.fetchStoragePart.nextPairs:
    # Delete from queue and process this entry
    env.fetchStoragePart.del kvp.key

    # Move to returned list unless duplicated in full slots list
    if env.fetchStorageFull.eq(kvp.key).isErr:
      toBeHealed.add kvp
      env.parkedStorage.incl kvp.data.accKey # temporarily parked
      if healStorageSlotsBatchMax <= toBeHealed.len:
        break

  # Run against local batch
  let
    nHealerQueue = toBeHealed.len
  var
    ignore: HashSet[Blob]
  if 0 < nHealerQueue:
    when extraTraceMessages:
      trace logTxt "processing", peer, ctx=buddy.healingCtx(env), nHealerQueue

    for n in 0 ..< toBeHealed.len:
      # Stop processing, hand back the rest
      if buddy.ctrl.stopped:
        for m in n ..< toBeHealed.len:
          let kvp = toBeHealed[n]
          discard env.fetchStoragePart.append(kvp.key, kvp.data)
          env.parkedStorage.excl kvp.data.accKey
        break

      let kvp = toBeHealed[n]
      await buddy.storageSlotsHealing(kvp, ignore, env)

      # Re-queue again unless ready
      env.parkedStorage.excl kvp.data.accKey        # un-register
      if not kvp.data.slots.processed.isFull:
        discard env.fetchStoragePart.append(kvp.key, kvp.data)

  when extraTraceMessages:
    trace logTxt "done", peer, ctx=buddy.healingCtx(env), nHealerQueue

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
