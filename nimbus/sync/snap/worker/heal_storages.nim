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
  eth/[common/eth_types, p2p, trie/nibbles, trie/trie_defs, rlp],
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

proc healingCtx(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
      ): string =
  let
    slots = kvp.data.slots
  "[" &
    "covered=" & slots.unprocessed.emptyFactor.toPC(0) &
    "nCheckNodes=" & $slots.checkNodes.len & "," &
    "nMissingNodes=" & $slots.missingNodes.len & "]"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

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
    accHash = kvp.data.accHash
    storageRoot = kvp.key.to(Hash256)
    slots = kvp.data.slots
  var
    nodes: seq[Blob]

  when extraTraceMessages:
    trace "Start storage slots healing", peer, ctx=buddy.healingCtx(kvp)

  for slotKey in slots.missingNodes:
    let rc = db.getStorageSlotsNodeKey(peer, accHash, storageRoot, slotKey)
    if rc.isOk:
      # Check nodes for dangling links
      slots.checkNodes.add slotKey
    else:
      # Node is still missing
      nodes.add slotKey

  slots.missingNodes = nodes


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
    accHash = kvp.data.accHash
    storageRoot = kvp.key.to(Hash256)
    slots = kvp.data.slots

    rc = db.inspectStorageSlotsTrie(
      peer, accHash, storageRoot, slots.checkNodes)

  if rc.isErr:
    when extraTraceMessages:
      error "Storage slots healing failed => stop", peer,
        ctx=buddy.healingCtx(kvp), error=rc.error
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
      ): Future[seq[Blob]]
      {.async.} =
  ##  Extract from `missingNodes` the next batch of nodes that need
  ## to be merged it into the database
  let
    ctx = buddy.ctx
    peer = buddy.peer
    accHash = kvp.data.accHash
    storageRoot = kvp.key.to(Hash256)
    slots = kvp.data.slots

    nMissingNodes = slots.missingNodes.len
    inxLeft = max(0, nMissingNodes - maxTrieNodeFetch)

  # There is no point in processing too many nodes at the same time. So leave
  # the rest on the `missingNodes` queue to be handled later.
  let fetchNodes = slots.missingNodes[inxLeft ..< nMissingNodes]
  slots.missingNodes.setLen(inxLeft)

  # Fetch nodes from the network. Note that the remainder of the `missingNodes`
  # list might be used by another process that runs semi-parallel.
  let
    req = @[accHash.data.toSeq] & fetchNodes.mapIt(@[it])
    rc = await buddy.getTrieNodes(storageRoot, req)
  if rc.isOk:
    # Register unfetched missing nodes for the next pass
    slots.missingNodes = slots.missingNodes & rc.value.leftOver.mapIt(it[0])
    return rc.value.nodes

  # Restore missing nodes list now so that a task switch in the error checker
  # allows other processes to access the full `missingNodes` list.
  slots.missingNodes = slots.missingNodes & fetchNodes

  let error = rc.error
  if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
    discard
    when extraTraceMessages:
      trace "Error fetching storage slots nodes for healing => stop", peer,
        ctx=buddy.healingCtx(kvp), error
  else:
    discard
    when extraTraceMessages:
      trace "Error fetching storage slots nodes for healing", peer,
        ctx=buddy.healingCtx(kvp), error

  return @[]


proc kvStorageSlotsLeaf(
    buddy: SnapBuddyRef;
    kvp: SnapSlotsQueuePair;
    partialPath: Blob;
    node: Blob;
      ): (bool,NodeKey)
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Read leaf node from persistent database (if any)
  let
    peer = buddy.peer

    nodeRlp = rlpFromBytes node
    (_,prefix) = hexPrefixDecode partialPath
    (_,segment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
    nibbles = prefix & segment
  if nibbles.len == 64:
    return (true, nibbles.getBytes.convertTo(NodeKey))

  when extraTraceMessages:
    trace "Isolated node path for healing => ignored", peer,
      ctx=buddy.healingCtx(kvp)


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
    trace "Isolated storage slot for healing",
      peer, ctx=buddy.healingCtx(kvp), slotKey=pt

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
    accHash = kvp.data.accHash
    slots = kvp.data.slots

  # Update for changes since last visit
  buddy.updateMissingNodesList(kvp)

  # ???
  if slots.checkNodes.len != 0:
    if not buddy.appendMoreDanglingNodesToMissingNodesList(kvp):
      return false

  # Check whether the trie is complete.
  if slots.missingNodes.len == 0:
    trace "Storage slots healing complete", peer, ctx=buddy.healingCtx(kvp)
    return true

  # Get next batch of nodes that need to be merged it into the database
  let nodesData = await buddy.getMissingNodesFromNetwork(kvp)
  if nodesData.len == 0:
    return

  # Store nodes to disk
  let report = db.importRawStorageSlotsNodes(peer, accHash, nodesData)
  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    error "Storage slots healing, error updating persistent database", peer,
      ctx=buddy.healingCtx(kvp), nNodes=nodesData.len, error=report[^1].error
    slots.missingNodes = slots.missingNodes & nodesData
    return false

  when extraTraceMessages:
    trace "Storage slots healing, nodes merged into database", peer,
      ctx=buddy.healingCtx(kvp), nNodes=nodesData.len

  # Filter out error and leaf nodes
  for w in report:
    if w.slot.isSome: # non-indexed entries appear typically at the end, though
      let
        inx = w.slot.unsafeGet
        nodePath = nodesData[inx]

      if w.error != NothingSerious or w.kind.isNone:
        # error, try downloading again
        slots.missingNodes.add nodePath

      elif w.kind.unsafeGet != Leaf:
        # re-check this node
        slots.checkNodes.add nodePath

      else:
        # Node has been stored, double check
        let (isLeaf, slotKey) =
          buddy.kvStorageSlotsLeaf(kvp, nodePath, nodesData[inx])
        if isLeaf:
          # Update `uprocessed` registry, collect storage roots (if any)
          buddy.registerStorageSlotsLeaf(kvp, slotKey)
        else:
          slots.checkNodes.add nodePath

  when extraTraceMessages:
    trace "Storage slots healing job done", peer, ctx=buddy.healingCtx(kvp)


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
    accHash = kvp.data.accHash
    storageRoot = kvp.key.to(Hash256)

  # Check whether this work item can be completely inherited
  if kvp.data.inherit:
    let rc = db.inspectStorageSlotsTrie(peer, accHash, storageRoot)

    if rc.isErr:
      # Oops, not much we can do here (looping trie?)
      error "Problem inspecting storage trie", peer, storageRoot, error=rc.error
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

proc healStoragesDb*(buddy: SnapBuddyRef) {.async.} =
  ## Fetching and merging missing slorage slots trie database nodes.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    env = buddy.data.pivotEnv
  var
    toBeHealed: seq[SnapSlotsQueuePair]

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

    # Add to local batch to be processed, below
    env.fetchStorage.del(kvp.key)    # ok to delete this item from batch queue
    toBeHealed.add kvp               # to be held in local queue
    if maxStoragesHeal <= toBeHealed.len:
      break

  when extraTraceMessages:
    let nToBeHealed = toBeHealed.len
    if 0 < nToBeHealed:
      trace "Processing storage healing items", peer, nToBeHealed

  # Run against local batch
  for n in 0 ..< toBeHealed.len:
    let
      kvp = toBeHealed[n]
      isComplete = await buddy.healingIsComplete(kvp)
    if isComplete:
      env.nStorage.inc
    else:
      env.fetchStorage.merge kvp

    if buddy.ctrl.stopped:
      # Oops, peer has gone
      env.fetchStorage.merge toBeHealed[n+1 ..< toBeHealed.len]
      break

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
