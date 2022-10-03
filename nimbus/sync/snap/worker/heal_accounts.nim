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
  eth/[common/eth_types, p2p],
  stew/interval_set,
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
    nLeaves = 0            # For logging
    nodesNeeded: seq[Blob] # Trie nodes to process by this instance
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
    # Remove reported leaf paths from the accounts interval
    nLeaves = rc.value.leaves.len
    for accKey in rc.value.leaves:
      let pt = accKey.to(NodeTag)
      discard env.fetchAccounts.reduce(pt,pt)

  while 0 < nodesNeeded.len:
    var fetchNodes: seq[Blob]
    if maxTrieNodeFetch < nodesNeeded.len:
      # No point in processing more at the same time. So leave the rest on
      # the `dangling` queue.
      fetchNodes = nodesNeeded[maxTrieNodeFetch ..< nodesNeeded.len]
      nodesNeeded.setLen(maxTrieNodeFetch)
    else:
      fetchNodes = nodesNeeded
      nodesNeeded.setLen(0)

    when extraTraceMessages:
      let nDangling=env.danglAccountNodes.len
      trace "Accounts healing loop", peer, nDangling,
         nNodesNeeded=nodesNeeded.len, nLeaves

    # Fetch nodes
    let dd = block:
      let rc = await buddy.getTrieNodes(stateRoot, fetchNodes.mapIt(@[it]))
      if rc.isErr:
        env.danglAccountNodes = env.danglAccountNodes & fetchNodes
        when extraTraceMessages:
          let
            error = rc.error
            nDangling=env.danglAccountNodes.len
          trace "Error fetching account nodes for healing", peer,
            nDangling, nNodesNeeded=nodesNeeded.len, nLeaves, error
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
    trace "Done accounts healing", peer, nDangling, nLeaves

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
