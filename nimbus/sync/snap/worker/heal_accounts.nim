# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  std/sequtils,
  chronicles,
  chronos,
  eth/[common/eth_types, p2p, trie/trie_defs],
  stew/[interval_set, keyed_queue],
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/get_trie_nodes,
  ./db/snap_db

{.push raises: [Defect].}

logScope:
  topics = "snap-fetch"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc mergeIsolatedAccounts(
    buddy: SnapBuddyRef;
    paths: openArray[NodeKey];
      ): seq[AccountSlotsHeader] =
  ## Process leaves found with nodes inspection, returns a list of
  ## storage slots for these nodes.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Remove reported leaf paths from the accounts interval
  for accKey in paths:
    let pt = accKey.to(NodeTag)
    if 0 < env.fetchAccounts.covered(pt,pt):

      let
        rc = ctx.data.snapDb.getAccountData(peer, stateRoot, accKey)
        accountHash = Hash256(data: accKey.ByteArray32)
      if rc.isOk:
        let storageRoot = rc.value.storageRoot
        if storageRoot != emptyRlpHash:
          result.add AccountSlotsHeader(
            accHash:     accountHash,
            storageRoot: storageRoot)
        discard env.fetchAccounts.reduce(pt,pt)
        when extraTraceMessages:
          let stRootStr = if storageRoot != emptyRlpHash: $storageRoot
                          else: "emptyRlpHash"
          trace "Registered isolated persistent account", peer, accountHash,
            storageRoot=stRootStr
        continue

      when extraTraceMessages:
        let error = rc.error
        trace "Get persistent account problem", peer, accountHash, error

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc fetchAndHealAccounts*(buddy: SnapBuddyRef) {.async.} =
  ## Fetch missing account nodes
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  trace "Start accounts healing", peer, nDangling=env.danglAccountNodes.len

  # Starting with a given set of potentially dangling account nodes
  # `env.danglAccountNodes`, this set is filtered and processed. The outcome
  # is fed back to the vey same list `env.danglAccountNodes`
  var
    nodesNeeded: seq[Blob] # Trie nodes to process by this instance
    nLeaves = 0            # For logging
    nWithStorage = 0       # For logging
  block:
    let
      maxLeaves = if env.danglAccountNodes.len == 0: 0 else: maxHealingLeafPaths
      rc = ctx.data.snapDb.inspectAccountsTrie(
        peer, stateRoot, env.danglAccountNodes, maxLeaves)
    if rc.isErr:
      let
        error = rc.error
        nDangling = env.danglAccountNodes.len
      if error == TrieIsEmpty:
        when extraTraceMessages:
          trace "Accounts healing on healthy trie", peer, nDangling, error
      else:
        # FIXME: This is typically a trie loop error, appears with a corrupted
        #        database.
        error "Accounts healing failed => stop", peer, nDangling, error
        buddy.ctrl.zombie = true
      return

    # Replace global/env batch list by preprocessed local one.
    nodesNeeded = rc.value.dangling
    env.danglAccountNodes.setLen(0)
    nLeaves = rc.value.leaves.len

    # Store accounts leaves on the storage batch list.
    let withStorage = buddy.mergeIsolatedAccounts(rc.value.leaves)
    if 0 < withStorage.len:
      nWithStorage = withStorage.len
      discard env.fetchStorage.append SnapSlotQueueItemRef(q: withStorage)

  while 0 < nodesNeeded.len:
    var fetchNodes: seq[Blob]
    if maxTrieNodeFetch < nodesNeeded.len:
      # No point in processing more at the same time. So leave the rest on
      # the `danglAccountNodes` queue.
      fetchNodes = nodesNeeded[maxTrieNodeFetch ..< nodesNeeded.len]
      nodesNeeded.setLen(maxTrieNodeFetch)
    else:
      fetchNodes = nodesNeeded
      nodesNeeded.setLen(0)

    when extraTraceMessages:
      let
        nDangling = env.danglAccountNodes.len
        nNodesNeeded = nodesNeeded.len
      trace "Accounts healing loop", peer, nDangling,
         nNodesNeeded, nLeaves, nWithStorage

    # Fetch nodes
    let dd = block:
      let rc = await buddy.getTrieNodes(stateRoot, fetchNodes.mapIt(@[it]))
      if rc.isErr:
        env.danglAccountNodes = env.danglAccountNodes & fetchNodes
        when extraTraceMessages:
          let
            error = rc.error
            nDangling = env.danglAccountNodes.len
            nNodesNeeded = nodesNeeded.len
          trace "Error fetching account nodes for healing", peer, nDangling,
            nNodesNeeded, nLeaves, nWithStorage, error
        # Just try the next round
        continue
      rc.value

    # Store to disk and register left overs for the next pass
    block:
      let rc = ctx.data.snapDb.importRawNodes(peer, dd.nodes)
      if rc.isOk:
        env.danglAccountNodes = env.danglAccountNodes & dd.leftOver.mapIt(it[0])
      elif 0 < rc.error.len and rc.error[^1][0] < 0:
        # negative index => storage error
        env.danglAccountNodes = env.danglAccountNodes & fetchNodes
      else:
        env.danglAccountNodes = env.danglAccountNodes &
          dd.leftOver.mapIt(it[0]) & rc.error.mapIt(dd.nodes[it[0]])

    # End while

  when extraTraceMessages:
    let nDangling=env.danglAccountNodes.len
    trace "Done accounts healing", peer, nDangling, nLeaves, nWithStorage

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
