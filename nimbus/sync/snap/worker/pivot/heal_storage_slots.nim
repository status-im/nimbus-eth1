# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Heal storage DB:
## ================
##
## This module works similar to `heal_accounts` applied to each per-account
## storage slots hexary trie. These per-account trie work items  are stored in
## the pair of queues `env.fetchStorageFull` and `env.fetchStoragePart`.
##
## There is one additional short cut for speeding up processing. If a
## per-account storage slots hexary trie is marked inheritable, it will be
## checked whether it is complete and can be used wholesale.
##
## Inheritable tries appear after a pivot state root change. Typically, not all
## account data have changed and so the same  per-account storage slots are
## valid.
##

import
  std/[sequtils, tables],
  chronicles,
  chronos,
  eth/[common, p2p, trie/nibbles, trie/trie_defs, rlp],
  stew/[interval_set, keyed_queue],
  ../../../../utils/prettify,
  ../../../sync_desc,
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_trie_nodes],
  ../db/[hexary_desc, hexary_error, snapdb_storage_slots],
  ./sub_tries_helper

{.push raises: [Defect].}

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

proc healingCtx(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    env: SnapPivotRef;
      ): string =
  let slots = kvp.data.slots
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "covered=" & slots.unprocessed.emptyFactor.toPC(0) & "," &
    "nNodesCheck=" & $slots.nodes.check.len & "," &
    "nNodesMissing=" & $slots.nodes.missing.len & "}"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc acceptWorkItemAsIs(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
      ): Result[bool,HexaryError] =
  ## Check whether this work item is done and the corresponding storage trie
  ## can be completely inherited.
  if kvp.data.inherit:
    let
      ctx = buddy.ctx
      peer = buddy.peer
      db = ctx.data.snapDb
      accKey = kvp.data.accKey
      storageRoot = kvp.key

      rc = db.inspectStorageSlotsTrie(peer, accKey, storageRoot)

    # Check whether the hexary trie is complete
    if rc.isOk:
      return ok(rc.value.dangling.len == 0)

    return err(rc.error)

  ok(false)


proc verifyStillMissingNodes(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    env: SnapPivotRef;
      ) =
  ## Check whether previously missing nodes from the `nodes.missing` list
  ## have been magically added to the database since it was checked last
  ## time. These nodes will me moved to `nodes.check` for further processing.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    accKey = kvp.data.accKey
    storageRoot = kvp.key
    slots = kvp.data.slots

  var delayed: seq[NodeSpecs]
  for w in slots.nodes.missing:
    let rc = db.getStorageSlotsNodeKey(peer, accKey, storageRoot, w.partialPath)
    if rc.isOk:
      # Check nodes for dangling links
      slots.nodes.check.add w
    else:
      # Node is still missing
      delayed.add w

  # Must not modify sequence while looping over it
  slots.nodes.missing = slots.nodes.missing & delayed


proc updateMissingNodesList(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    env: SnapPivotRef;
      ): Future[bool]
      {.async.} =
  ## Starting with a given set of potentially dangling intermediate trie nodes
  ## `nodes.check`, this set is filtered and processed. The outcome is fed back
  ## to the vey same list `nodes.check`.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    accKey = kvp.data.accKey
    storageRoot = kvp.key
    slots = kvp.data.slots

  let rc = await db.getStorageSlotsFn(accKey).subTriesFromPartialPaths(
    storageRoot,                       # State root related to storage slots
    slots,                             # Storage slots download specs
    snapRequestTrieNodesFetchMax)      # Maxinmal datagram request size
  if rc.isErr:
    let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
    if rc.error == TrieIsLockedForPerusal:
      trace logTxt "failed", peer, itCtx=buddy.healingCtx(kvp,env),
        nSlotLists=env.nSlotLists, nStorageQueue, error=rc.error
    else:
      error logTxt "failed => stop", peer, itCtx=buddy.healingCtx(kvp,env),
        nSlotLists=env.nSlotLists, nStorageQueue, error=rc.error
      # Attempt to switch pivot, there is not much else one can do here
      buddy.ctrl.zombie = true
    return false

  return true


proc getMissingNodesFromNetwork(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    env: SnapPivotRef;
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ##  Extract from `nodes.missing` the next batch of nodes that need
  ## to be merged it into the database
  let
    ctx = buddy.ctx
    peer = buddy.peer
    accKey = kvp.data.accKey
    storageRoot = kvp.key
    pivot = "#" & $env.stateHeader.blockNumber # for logging
    slots = kvp.data.slots

    nSickSubTries = slots.nodes.missing.len
    inxLeft = max(0, nSickSubTries - snapRequestTrieNodesFetchMax)

  # There is no point in processing too many nodes at the same time. So leave
  # the rest on the `nodes.missing` queue to be handled later.
  let fetchNodes = slots.nodes.missing[inxLeft ..< nSickSubTries]
  slots.nodes.missing.setLen(inxLeft)

  # Initalise for `getTrieNodes()` for fetching nodes from the network
  var
    nodeKey: Table[Blob,NodeKey] # Temporary `path -> key` mapping
    pathList: seq[seq[Blob]]     # Function argument for `getTrieNodes()`
  for w in fetchNodes:
    pathList.add @[w.partialPath]
    nodeKey[w.partialPath] = w.nodeKey

  # Fetch nodes from the network. Note that the remainder of the `nodes.missing`
  # list might be used by another process that runs semi-parallel.
  let
    req = @[accKey.to(Blob)] & fetchNodes.mapIt(it.partialPath)
    rc = await buddy.getTrieNodes(storageRoot, @[req], pivot)
  if rc.isOk:
    # Reset error counts for detecting repeated timeouts, network errors, etc.
    buddy.data.errors.resetComError()

    # Register unfetched missing nodes for the next pass
    for w in rc.value.leftOver:
      for n in 1 ..< w.len:
        slots.nodes.missing.add NodeSpecs(
          partialPath: w[n],
          nodeKey:     nodeKey[w[n]])
    return rc.value.nodes.mapIt(NodeSpecs(
      partialPath: it.partialPath,
      nodeKey:     nodeKey[it.partialPath],
      data:        it.data))

  # Restore missing nodes list now so that a task switch in the error checker
  # allows other processes to access the full `nodes.missing` list.
  slots.nodes.missing = slots.nodes.missing & fetchNodes

  let error = rc.error
  if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
    discard
    when extraTraceMessages:
      let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
      trace logTxt "fetch nodes error => stop", peer,
        itCtx=buddy.healingCtx(kvp,env), nSlotLists=env.nSlotLists,
        nStorageQueue, error
  else:
    discard
    when extraTraceMessages:
      let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
      trace logTxt "fetch nodes error", peer,
        itCtx=buddy.healingCtx(kvp,env), nSlotLists=env.nSlotLists,
        nStorageQueue, error

  return @[]


proc kvStorageSlotsLeaf(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    node: NodeSpecs;
    env: SnapPivotRef;
      ): (bool,NodeKey)
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Read leaf node from persistent database (if any)
  let
    peer = buddy.peer

    nodeRlp = rlpFromBytes node.data
    (_,prefix) = hexPrefixDecode node.partialPath
    (_,segment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
    nibbles = prefix & segment
  if nibbles.len == 64:
    return (true, nibbles.getBytes.convertTo(NodeKey))


proc registerStorageSlotsLeaf(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    slotKey: NodeKey;
    env: SnapPivotRef;
      ) =
  ## Process single trie node as would be done with an interval by
  ## the `storeStorageSlots()` function
  let
    peer = buddy.peer
    slots = kvp.data.slots
    pt = slotKey.to(NodeTag)

  # Find range set (from list) containing `pt`
  var ivSet: NodeTagRangeSet
  block foundCoveringRange:
    for w in slots.unprocessed:
      if 0 < w.covered(pt,pt):
        ivSet = w
        break foundCoveringRange
    return # already processed, forget this account leaf

  # Register this isolated leaf node that was added
  discard ivSet.reduce(pt,pt)

  when extraTraceMessages:
    let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
    trace logTxt "single node", peer,
      itCtx=buddy.healingCtx(kvp,env), nSlotLists=env.nSlotLists,
      nStorageQueue, slotKey=pt


proc assembleWorkItemsQueue(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): (seq[SnapSlotsQueuePair],int) =
  ## ..
  var
    toBeHealed: seq[SnapSlotsQueuePair]
    nAcceptedAsIs = 0

  # Search the current slot item batch list for items to complete via healing
  for kvp in env.fetchStoragePart.nextPairs:
    # Marked items indicate that a partial sub-trie existsts which might have
    # been inherited from an earlier storage root.
    if kvp.data.inherit:

      # Remove `kvp` work item from the queue object (which is allowed within a
      # `for` loop over a `KeyedQueue` object type.)
      env.fetchStorageFull.del(kvp.key)

      # With some luck, the `kvp` work item refers to a complete storage trie
      # that can be be accepted as-is in wich case `kvp` can be just dropped.
      let rc = buddy.acceptWorkItemAsIs(kvp)
      if rc.isOk and rc.value:
        env.nSlotLists.inc
        nAcceptedAsIs.inc # for logging
        continue # dropping `kvp`

      toBeHealed.add kvp
      if healStorageSlotsBatchMax <= toBeHealed.len:
        return (toBeHealed, nAcceptedAsIs)

  # Ditto for partial items queue
  for kvp in env.fetchStoragePart.nextPairs:
    if healSlorageSlotsTrigger <= kvp.data.slots.unprocessed.emptyFactor:
      env.fetchStoragePart.del(kvp.key)

      let rc = buddy.acceptWorkItemAsIs(kvp)
      if rc.isOk and rc.value:
        env.nSlotLists.inc
        nAcceptedAsIs.inc # for logging
        continue # dropping `kvp`

      # Add to local batch to be processed, below
      toBeHealed.add kvp
      if healStorageSlotsBatchMax <= toBeHealed.len:
        break

  (toBeHealed, nAcceptedAsIs)

# ------------------------------------------------------------------------------
# Private functions: do the healing for one work item (sub-trie)
# ------------------------------------------------------------------------------

proc storageSlotsHealing(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    env: SnapPivotRef;
      ): Future[bool]
      {.async.} =
  ## Returns `true` is the sub-trie is complete (probably inherited), and
  ## `false` if there are nodes left to be completed.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    accKey = kvp.data.accKey
    slots = kvp.data.slots

  when extraTraceMessages:
    block:
      let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
      trace logTxt "started", peer, itCtx=buddy.healingCtx(kvp,env),
        nSlotLists=env.nSlotLists, nStorageQueue

  # Update for changes since last visit
  buddy.verifyStillMissingNodes(kvp, env)

  # ???
  if slots.nodes.check.len != 0:
    if not await buddy.updateMissingNodesList(kvp,env):
      return false

  # Check whether the trie is complete.
  if slots.nodes.missing.len == 0:
    trace logTxt "complete", peer, itCtx=buddy.healingCtx(kvp,env)
    return true

  # Get next batch of nodes that need to be merged it into the database
  let nodeSpecs = await buddy.getMissingNodesFromNetwork(kvp,env)
  if nodeSpecs.len == 0:
    return

  # Store nodes onto disk
  let report = db.importRawStorageSlotsNodes(peer, accKey, nodeSpecs)
  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
    error logTxt "error updating persistent database", peer,
      itCtx=buddy.healingCtx(kvp,env), nSlotLists=env.nSlotLists,
      nStorageQueue, nNodes=nodeSpecs.len, error=report[^1].error
    slots.nodes.missing = slots.nodes.missing & nodeSpecs
    return false

  when extraTraceMessages:
    block:
      let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
      trace logTxt "nodes merged into database", peer,
        itCtx=buddy.healingCtx(kvp,env), nSlotLists=env.nSlotLists,
        nStorageQueue, nNodes=nodeSpecs.len

  # Filter out error and leaf nodes
  var nLeafNodes = 0 # for logging
  for w in report:
    if w.slot.isSome: # non-indexed entries appear typically at the end, though
      let inx = w.slot.unsafeGet

      if w.error != NothingSerious or w.kind.isNone:
        # error, try downloading again
        slots.nodes.missing.add nodeSpecs[inx]

      elif w.kind.unsafeGet != Leaf:
        # re-check this node
        slots.nodes.check.add nodeSpecs[inx]

      else:
        # Node has been stored, double check
        let (isLeaf, slotKey) =
          buddy.kvStorageSlotsLeaf(kvp, nodeSpecs[inx], env)
        if isLeaf:
          # Update `uprocessed` registry, collect storage roots (if any)
          buddy.registerStorageSlotsLeaf(kvp, slotKey, env)
          nLeafNodes.inc
        else:
          slots.nodes.check.add nodeSpecs[inx]

  when extraTraceMessages:
    let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
    trace logTxt "job done", peer, itCtx=buddy.healingCtx(kvp,env),
      nSlotLists=env.nSlotLists, nStorageQueue, nLeafNodes


proc healingIsComplete(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    env: SnapPivotRef;
      ): Future[bool]
      {.async.} =
  ## Check whether the storage trie can be completely inherited and prepare for
  ## healing if not.
  ##
  ## Returns `true` is the sub-trie is complete (probably inherited), and
  ## `false` if there are nodes left to be completed.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    accKey = kvp.data.accKey
    storageRoot = kvp.key

  # Check whether this work item can be completely inherited
  if kvp.data.inherit:
    let rc = db.inspectStorageSlotsTrie(peer, accKey, storageRoot)

    if rc.isErr:
      # Oops, not much we can do here (looping trie?)
      let nStorageQueue = env.fetchStorageFull.len + env.fetchStoragePart.len
      error logTxt "problem inspecting storage trie", peer,
        nSlotLists=env.nSlotLists, nStorageQueue, storageRoot, error=rc.error
      return false

    # Check whether the hexary trie can be inherited as-is.
    if rc.value.dangling.len == 0:
      return true # done

    # Full range covered by unprocessed items
    kvp.data.slots = SnapRangeBatchRef(
      nodes: SnapTodoNodes(
        missing: rc.value.dangling))
    kvp.data.slots.unprocessed.init()

  # Proceed with healing
  return await buddy.storageSlotsHealing(kvp, env)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healStorageSlots*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetching and merging missing slorage slots trie database nodes.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
  var
    (toBeHealed, nAcceptedAsIs) = buddy.assembleWorkItemsQueue(env)

  # Run against local batch
  let nHealerQueue = toBeHealed.len
  if 0 < nHealerQueue:
    when extraTraceMessages:
      block:
        let nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
        trace logTxt "processing", peer,
          nSlotLists=env.nSlotLists, nStoQu, nHealerQueue, nAcceptedAsIs

    for n in 0 ..< toBeHealed.len:
      let kvp = toBeHealed[n]

      if buddy.ctrl.running:
        if await buddy.healingIsComplete(kvp,env):
          env.nSlotLists.inc
          nAcceptedAsIs.inc
          continue

      if kvp.data.slots.isNil:
        env.fetchStorageFull.merge kvp # should be the exception
      else:
        env.fetchStoragePart.merge kvp

    when extraTraceMessages:
      let nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
      trace logTxt "done", peer, nSlotLists=env.nSlotLists, nStoQu,
        nHealerQueue, nAcceptedAsIs, runState=buddy.ctrl.state

  elif 0 < nAcceptedAsIs:
    let nStoQu = env.fetchStorageFull.len + env.fetchStoragePart.len
    trace logTxt "work items", peer, nSlotLists=env.nSlotLists,
      nStoQu, nHealerQueue, nAcceptedAsIs, runState=buddy.ctrl.state

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
