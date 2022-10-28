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
## This module works similar to `heal_accounts` applied to each
## per-account storage slots hexary trie.

import
  std/sequtils,
  chronicles,
  chronos,
  eth/[common, p2p, trie/nibbles, trie/trie_defs, rlp],
  stew/[interval_set, keyed_queue],
  ../../../utils/prettify,
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/[com_error, get_trie_nodes],
  ./db/[hexary_desc, hexary_error, snapdb_storage_slots]

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
      ): string =
  let
    slots = kvp.data.slots
  "{" &
    "covered=" & slots.unprocessed.emptyFactor.toPC(0) & "," &
    "nCheckNodes=" & $slots.checkNodes.len & "," &
    "nMissingNodes=" & $slots.missingNodes.len & "}"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc acceptWorkItemAsIs(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
      ): Result[bool, HexaryDbError] =
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


proc updateMissingNodesList(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair) =
  ## Check whether previously missing nodes from the `missingNodes` list
  ## have been magically added to the database since it was checked last
  ## time. These nodes will me moved to `checkNodes` for further processing.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    env = buddy.data.pivotEnv
    accKey = kvp.data.accKey
    storageRoot = kvp.key
    slots = kvp.data.slots

  var delayed: seq[NodeSpecs]
  for w in slots.missingNodes:
    let rc = db.getStorageSlotsNodeKey(peer, accKey, storageRoot, w.partialPath)
    if rc.isOk:
      # Check nodes for dangling links
      slots.checkNodes.add w.partialPath
    else:
      # Node is still missing
      delayed.add w

  # Must not modify sequence while looping over it
  slots.missingNodes = slots.missingNodes & delayed


proc appendMoreDanglingNodesToMissingNodesList(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
      ): bool =
  ## Starting with a given set of potentially dangling intermediate trie nodes
  ## `checkNodes`, this set is filtered and processed. The outcome is fed back
  ## to the vey same list `checkNodes`
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    env = buddy.data.pivotEnv
    accKey = kvp.data.accKey
    storageRoot = kvp.key
    slots = kvp.data.slots

    rc = db.inspectStorageSlotsTrie(peer, accKey, storageRoot, slots.checkNodes)

  if rc.isErr:
    when extraTraceMessages:
      error logTxt "failed => stop", peer,
        itCtx=buddy.healingCtx(kvp), nSlotLists=env.nSlotLists,
        nStorageQueue=env.fetchStorage.len, error=rc.error
    # Attempt to switch peers, there is not much else we can do here
    buddy.ctrl.zombie = true
    return false

  # Update batch lists
  slots.checkNodes.setLen(0)
  slots.missingNodes = slots.missingNodes & rc.value.dangling

  true


proc getMissingNodesFromNetwork(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ##  Extract from `missingNodes` the next batch of nodes that need
  ## to be merged it into the database
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    accKey = kvp.data.accKey
    storageRoot = kvp.key
    slots = kvp.data.slots

    nMissingNodes = slots.missingNodes.len
    inxLeft = max(0, nMissingNodes - maxTrieNodeFetch)

  # There is no point in processing too many nodes at the same time. So leave
  # the rest on the `missingNodes` queue to be handled later.
  let fetchNodes = slots.missingNodes[inxLeft ..< nMissingNodes]
  slots.missingNodes.setLen(inxLeft)

  # Initalise for `getTrieNodes()` for fetching nodes from the network
  var
    nodeKey: Table[Blob,NodeKey] # Temporary `path -> key` mapping
    pathList: seq[seq[Blob]]     # Function argument for `getTrieNodes()`
  for w in fetchNodes:
    pathList.add @[w.partialPath]
    nodeKey[w.partialPath] = w.nodeKey

  # Fetch nodes from the network. Note that the remainder of the `missingNodes`
  # list might be used by another process that runs semi-parallel.
  let
    req = @[accKey.to(Blob)] & fetchNodes.mapIt(it.partialPath)
    rc = await buddy.getTrieNodes(storageRoot, @[req])
  if rc.isOk:
    # Register unfetched missing nodes for the next pass
    for w in rc.value.leftOver:
      for n in 1 ..< w.len:
        slots.missingNodes.add NodeSpecs(
          partialPath: w[n],
          nodeKey:     nodeKey[w[n]])
    return rc.value.nodes.mapIt(NodeSpecs(
      partialPath: it.partialPath,
      nodeKey:     nodeKey[it.partialPath],
      data:        it.data))

  # Restore missing nodes list now so that a task switch in the error checker
  # allows other processes to access the full `missingNodes` list.
  slots.missingNodes = slots.missingNodes & fetchNodes

  let error = rc.error
  if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
    discard
    when extraTraceMessages:
      trace logTxt "fetch nodes error => stop", peer,
        itCtx=buddy.healingCtx(kvp), nSlotLists=env.nSlotLists,
        nStorageQueue=env.fetchStorage.len, error
  else:
    discard
    when extraTraceMessages:
      trace logTxt "fetch nodes error", peer,
        itCtx=buddy.healingCtx(kvp), nSlotLists=env.nSlotLists,
        nStorageQueue=env.fetchStorage.len, error

  return @[]


proc kvStorageSlotsLeaf(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    node: NodeSpecs;
      ): (bool,NodeKey)
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Read leaf node from persistent database (if any)
  let
    peer = buddy.peer
    env = buddy.data.pivotEnv

    nodeRlp = rlpFromBytes node.data
    (_,prefix) = hexPrefixDecode node.partialPath
    (_,segment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
    nibbles = prefix & segment
  if nibbles.len == 64:
    return (true, nibbles.getBytes.convertTo(NodeKey))


proc registerStorageSlotsLeaf(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    slotKey: NodeKey) =
  ## Process single trie node as would be done with an interval by
  ## the `storeStorageSlots()` function
  let
    peer = buddy.peer
    env = buddy.data.pivotEnv
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
    trace logTxt "single node", peer,
      itCtx=buddy.healingCtx(kvp), nSlotLists=env.nSlotLists,
      nStorageQueue=env.fetchStorage.len, slotKey=pt

# ------------------------------------------------------------------------------
# Private functions: do the healing for one work item (sub-trie)
# ------------------------------------------------------------------------------

proc storageSlotsHealing(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
      ): Future[bool]
      {.async.} =
  ## Returns `true` is the sub-trie is complete (probably inherited), and
  ## `false` if there are nodes left to be completed.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    env = buddy.data.pivotEnv
    accKey = kvp.data.accKey
    slots = kvp.data.slots

  when extraTraceMessages:
    trace logTxt "started", peer, itCtx=buddy.healingCtx(kvp),
      nSlotLists=env.nSlotLists, nStorageQueue=env.fetchStorage.len

  # Update for changes since last visit
  buddy.updateMissingNodesList(kvp)

  # ???
  if slots.checkNodes.len != 0:
    if not buddy.appendMoreDanglingNodesToMissingNodesList(kvp):
      return false

  # Check whether the trie is complete.
  if slots.missingNodes.len == 0:
    trace logTxt "complete", peer, itCtx=buddy.healingCtx(kvp)
    return true

  # Get next batch of nodes that need to be merged it into the database
  let nodeSpecs = await buddy.getMissingNodesFromNetwork(kvp)
  if nodeSpecs.len == 0:
    return

  # Store nodes onto disk
  let report = db.importRawStorageSlotsNodes(peer, accKey, nodeSpecs)
  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    error logTxt "error updating persistent database", peer,
      itCtx=buddy.healingCtx(kvp), nSlotLists=env.nSlotLists,
      nStorageQueue=env.fetchStorage.len, nNodes=nodeSpecs.len,
      error=report[^1].error
    slots.missingNodes = slots.missingNodes & nodeSpecs
    return false

  when extraTraceMessages:
    trace logTxt "nodes merged into database", peer,
      itCtx=buddy.healingCtx(kvp), nSlotLists=env.nSlotLists,
      nStorageQueue=env.fetchStorage.len, nNodes=nodeSpecs.len

  # Filter out error and leaf nodes
  var nLeafNodes = 0 # for logging
  for w in report:
    if w.slot.isSome: # non-indexed entries appear typically at the end, though
      let
        inx = w.slot.unsafeGet
        nodePath = nodeSpecs[inx].partialPath

      if w.error != NothingSerious or w.kind.isNone:
        # error, try downloading again
        slots.missingNodes.add nodeSpecs[inx]

      elif w.kind.unsafeGet != Leaf:
        # re-check this node
        slots.checkNodes.add nodePath

      else:
        # Node has been stored, double check
        let (isLeaf, slotKey) =
          buddy.kvStorageSlotsLeaf(kvp, nodeSpecs[inx])
        if isLeaf:
          # Update `uprocessed` registry, collect storage roots (if any)
          buddy.registerStorageSlotsLeaf(kvp, slotKey)
          nLeafNodes.inc
        else:
          slots.checkNodes.add nodePath

  when extraTraceMessages:
    trace logTxt "job done", peer,
      itCtx=buddy.healingCtx(kvp), nSlotLists=env.nSlotLists,
      nStorageQueue=env.fetchStorage.len, nLeafNodes


proc healingIsComplete(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
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
    env = buddy.data.pivotEnv
    accKey = kvp.data.accKey
    storageRoot = kvp.key

  # Check whether this work item can be completely inherited
  if kvp.data.inherit:
    let rc = db.inspectStorageSlotsTrie(peer, accKey, storageRoot)

    if rc.isErr:
      # Oops, not much we can do here (looping trie?)
      error logTxt "problem inspecting storage trie", peer,
        nSlotLists=env.nSlotLists, nStorageQueue=env.fetchStorage.len,
        storageRoot, error=rc.error
      return false

    # Check whether the hexary trie can be inherited as-is.
    if rc.value.dangling.len == 0:
      return true # done

    # Set up healing structure for this work item
    let slots = SnapTrieRangeBatchRef(
      missingNodes: rc.value.dangling)
    kvp.data.slots = slots

    # Full range covered vy unprocessed items
    for n in 0 ..< kvp.data.slots.unprocessed.len:
      slots.unprocessed[n] = NodeTagRangeSet.init()
    discard slots.unprocessed[0].merge(
      NodeTagRange.new(low(NodeTag),high(NodeTag)))

  # Proceed with healing
  return await buddy.storageSlotsHealing(kvp)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healStorageSlots*(buddy: SnapBuddyRef) {.async.} =
  ## Fetching and merging missing slorage slots trie database nodes.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    env = buddy.data.pivotEnv
  var
    toBeHealed: seq[SnapSlotsQueuePair]
    nAcceptedAsIs = 0

  # Search the current slot item batch list for items to complete via healing
  for kvp in env.fetchStorage.nextPairs:

    # Marked items indicate that a partial sub-trie existsts which might have
    # been inherited from an earlier state root.
    if not kvp.data.inherit:
      let slots = kvp.data.slots

      # Otherwise check partally fetched sub-tries only if they have a certain
      # degree of completeness.
      if slots.isNil or slots.unprocessed.emptyFactor < healSlorageSlotsTrigger:
        continue

    # Remove `kvp` work item from the queue object (which is allowed within a
    # `for` loop over a `KeyedQueue` object type.)
    env.fetchStorage.del(kvp.key)

    # With some luck, the `kvp` work item refers to a complete storage trie
    # that can be be accepted as-is in wich case `kvp` can be just dropped.
    block:
      let rc = buddy.acceptWorkItemAsIs(kvp)
      if rc.isOk and rc.value:
        env.nSlotLists.inc
        nAcceptedAsIs.inc # for logging
        continue # dropping `kvp`

    # Add to local batch to be processed, below
    toBeHealed.add kvp
    if maxStoragesHeal <= toBeHealed.len:
      break

  # Run against local batch
  let nHealerQueue = toBeHealed.len
  if 0 < nHealerQueue:
    when extraTraceMessages:
      trace logTxt "processing", peer,
        nSlotLists=env.nSlotLists, nStorageQueue=env.fetchStorage.len,
        nHealerQueue, nAcceptedAsIs

    for n in 0 ..< toBeHealed.len:
      let
        kvp = toBeHealed[n]
        isComplete = await buddy.healingIsComplete(kvp)
      if isComplete:
        env.nSlotLists.inc
        nAcceptedAsIs.inc
      else:
        env.fetchStorage.merge kvp

      if buddy.ctrl.stopped:
        # Oops, peer has gone
        env.fetchStorage.merge toBeHealed[n+1 ..< toBeHealed.len]
        break

    when extraTraceMessages:
      trace logTxt "done", peer,
        nSlotLists=env.nSlotLists, nStorageQueue=env.fetchStorage.len,
        nHealerQueue, nAcceptedAsIs

  elif 0 < nAcceptedAsIs:
    trace logTxt "work items", peer,
      nSlotLists=env.nSlotLists, nStorageQueue=env.fetchStorage.len,
      nHealerQueue, nAcceptedAsIs

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
