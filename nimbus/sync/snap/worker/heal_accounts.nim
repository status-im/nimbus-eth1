# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Heal accounts DB:
## =================
##
## Flow chart for healing algorithm
## --------------------------------
## ::
##      START with {state-root}
##        |
##        |       +------------------------------------------------+
##        |       |                                                |
##        v       v                                                |
##      <inspect-accounts-trie> --> {missing-account-nodes}        |
##        |                             |                          |
##        v                             v                          |
##      {leaf-nodes}                <get-trie-nodes-via-snap/1>    |
##        |                             |                          |
##        v                             v                          |
##      <update-accounts-batch>     <merge-nodes-into-database>    |
##        |                             |                          |
##        v                             v                          |
##      {storage-roots}             {check-account-nodes} ---------+
##        |
##        v
##      <update-storage-processor-batch>
##
## Legend:
## * `<..>` some action, process, etc.
## * `{..}` some data set, list, or queue etc.
##
## Discussion of flow chart
## ------------------------
## * Input nodes for `<inspect-accounts-trie>` are checked for dangling child
##   node links which in turn are collected as output.
##
## * Nodes of the `{missing-account-nodes}` list are fetched from the network
##   and merged into the accounts trie database. Successfully processed nodes
##   are collected in the `{check-account-nodes}` list which is fed back into
##   the `<inspect-accounts-trie>` process.
##
## * If there is a problem with a node travelling from the source list
##   `{missing-account-nodes}` towards the target list `{check-account-nodes}`,
##   this problem node will simply held back in the source list.
##
##   In order to avoid unnecessary stale entries, the `{missing-account-nodes}`
##   list is regularly checked for whether nodes are still missing or some
##   other process has done the magic work of merging some of then into the
##   trie database.
##
## Competing with other trie algorithms
## ------------------------------------
## * Healing runs (semi-)parallel to processing `GetAccountRange` network
##   messages from the `snap/1` protocol. This is more network bandwidth
##   efficient in comparison with the healing algorithm. Here, leaf nodes are
##   transferred wholesale while with the healing algorithm, only the top node
##   of a sub-trie can be transferred at once (but for multiple sub-tries).
##
## * The healing algorithm visits all nodes of a complete trie unless it is
##   stopped in between.
##
## * If a trie node is missing, it can be fetched directly by the healing
##   algorithm or one can wait for another process to do the job. Waiting for
##   other processes to do the job also applies to problem nodes as indicated
##   in the last bullet item of the previous chapter.
##
## * Network bandwidth can be saved if nodes are fetched by a more efficient
##   process (if that is available.) This suggests that fetching missing trie
##   nodes by the healing algorithm should kick in very late when the trie
##   database is nearly complete.
##
## * Healing applies to a trie database associated with the currently latest
##   *state root*, which may change occasionally. It suggests to start the
##   healing algorithm very late altogether (not fetching nodes, only) because
##   most trie databases will never be completed by healing.
##

import
  std/sequtils,
  chronicles,
  chronos,
  eth/[common/eth_types, p2p, trie/trie_defs],
  stew/[interval_set, keyed_queue],
   ../../../utils/prettify,
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
# Helpers
# ------------------------------------------------------------------------------

proc coverageInfo(buddy: SnapBuddyRef): string =
  ## Logging helper ...
  let
    ctx = buddy.ctx
    env = buddy.data.pivotEnv
  env.fetchAccounts.emptyFactor.toPC(0) &
    "/" &
    ctx.data.coveredAccounts.fullFactor.toPC(0)

proc getCoveringRangeSet(buddy: SnapBuddyRef; pt: NodeTag): NodeTagRangeSet =
  ## Helper ...
  let env = buddy.data.pivotEnv
  for ivSet in env.fetchAccounts:
    if 0 < ivSet.covered(pt,pt):
      return ivSet

proc commitLeafAccount(buddy:SnapBuddyRef; ivSet: NodeTagRangeSet; pt: NodeTag)=
  ## Helper ...
  discard ivSet.reduce(pt,pt)
  discard buddy.ctx.data.coveredAccounts.merge(pt,pt)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateMissingNodesList(buddy: SnapBuddyRef) =
  ## Check whether previously missing nodes from the `missingAccountNodes` list
  ## have been magically added to the database since it was checked last time.
  ## These nodes will me moved to `checkAccountNodes` for further processing.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot
  var
    nodes: seq[Blob]

  for accKey in env.missingAccountNodes:
    let rc = ctx.data.snapDb.getAccountNodeKey(peer, stateRoot, accKey)
    if rc.isOk:
      # Check nodes for dangling links
      env.checkAccountNodes.add acckey
    else:
      # Node is still missing
      nodes.add acckey

  env.missingAccountNodes = nodes


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
    let
      pt = accKey.to(NodeTag)
      ivSet = buddy.getCoveringRangeSet(pt)
    if not ivSet.isNil:
      let
        rc = ctx.data.snapDb.getAccountData(peer, stateRoot, accKey)
        accountHash = Hash256(data: accKey.ByteArray32)
      if rc.isOk:
        let storageRoot = rc.value.storageRoot
        when extraTraceMessages:
          let stRootStr = if storageRoot != emptyRlpHash: $storageRoot
                          else: "emptyRlpHash"
          trace "Registered isolated persistent account", peer, accountHash,
            storageRoot=stRootStr
        if storageRoot != emptyRlpHash:
          result.add AccountSlotsHeader(
            accHash:     accountHash,
            storageRoot: storageRoot)
        buddy.commitLeafAccount(ivSet, pt)
        env.nAccounts.inc
        continue

      when extraTraceMessages:
        let error = rc.error
        trace "Get persistent account problem", peer, accountHash, error


proc fetchDanglingNodesList(
    buddy: SnapBuddyRef
      ): Result[TrieNodeStat,HexaryDbError] =
  ## Starting with a given set of potentially dangling account nodes
  ## `checkAccountNodes`, this set is filtered and processed. The outcome
  ## is fed back to the vey same list `checkAccountNodes`
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

    maxLeaves = if env.checkAccountNodes.len == 0: 0
                else: maxHealingLeafPaths

    rc = ctx.data.snapDb.inspectAccountsTrie(
      peer, stateRoot, env.checkAccountNodes, maxLeaves)

  if rc.isErr:
    # Attempt to switch peers, there is not much else we can do here
    buddy.ctrl.zombie = true
    return err(rc.error)

  # Global/env batch list to be replaced by by `rc.value.leaves` return value
  env.checkAccountNodes.setLen(0)

  # Store accounts leaves on the storage batch list.
  let withStorage = buddy.mergeIsolatedAccounts(rc.value.leaves)
  if 0 < withStorage.len:
    discard env.fetchStorage.append SnapSlotQueueItemRef(q: withStorage)
    when extraTraceMessages:
      trace "Accounts healing storage nodes", peer,
        nAccounts=env.nAccounts,
        covered=buddy.coverageInfo(),
        nWithStorage=withStorage.len,
        nDangling=rc.value.dangling

  return ok(rc.value)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healAccountsDb*(buddy: SnapBuddyRef) {.async.} =
  ## Fetching and merging missing account trie database nodes.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

  # Only start healing if there is some completion level, already.
  #
  # We check against the global coverage factor, i.e. a measure for how
  # much of the total of all accounts have been processed. Even if the trie
  # database for the current pivot state root is sparsely filled, there
  # is a good chance that it can inherit some unchanged sub-trie from an
  # earlier pivor state root download. The healing process then works like
  # sort of glue.
  #
  if env.nAccounts == 0 or
     ctx.data.coveredAccounts.fullFactor < healAccountsTrigger:
    when extraTraceMessages:
      trace "Accounts healing postponed", peer,
        nAccounts=env.nAccounts,
        covered=buddy.coverageInfo(),
        nCheckAccountNodes=env.checkAccountNodes.len,
        nMissingAccountNodes=env.missingAccountNodes.len
    return

  when extraTraceMessages:
    trace "Start accounts healing", peer,
      nAccounts=env.nAccounts,
      covered=buddy.coverageInfo(),
      nCheckAccountNodes=env.checkAccountNodes.len,
      nMissingAccountNodes=env.missingAccountNodes.len

  # Update for changes since last visit
  buddy.updateMissingNodesList()

  # If `checkAccountNodes` is empty, healing is at the very start or
  # was postponed in which case `missingAccountNodes` is non-empty.
  var
    nodesMissing: seq[Blob]              # Nodes to process by this instance
    nLeaves = 0                          # For logging
  if 0 < env.checkAccountNodes.len or env.missingAccountNodes.len == 0:
    let rc = buddy.fetchDanglingNodesList()
    if rc.isErr:
      error "Accounts healing failed => stop", peer,
        nAccounts=env.nAccounts,
        covered=buddy.coverageInfo(),
        nCheckAccountNodes=env.checkAccountNodes.len,
        nMissingAccountNodes=env.missingAccountNodes.len,
        error=rc.error
      return

    nodesMissing = rc.value.dangling
    nLeaves = rc.value.leaves.len

  # Check whether the trie is complete.
  if nodesMissing.len == 0 and env.missingAccountNodes.len == 0:
    when extraTraceMessages:
      trace "Accounts healing complete", peer,
        nAccounts=env.nAccounts,
        covered=buddy.coverageInfo(),
        nCheckAccountNodes=0,
        nMissingAccountNodes=0,
        nNodesMissing=0,
        nLeaves
    return # nothing to do

  # Ok, clear global `env.missingAccountNodes` list and process `nodesMissing`.
  nodesMissing = nodesMissing & env.missingAccountNodes
  env.missingAccountNodes.setlen(0)

  # Fetch nodes, merge it into database and feed back results
  while 0 < nodesMissing.len:
    var fetchNodes: seq[Blob]
    # There is no point in processing too many nodes at the same time. So
    # leave the rest on the `nodesMissing` queue for a moment.
    if maxTrieNodeFetch < nodesMissing.len:
      let inxLeft = nodesMissing.len - maxTrieNodeFetch
      fetchNodes = nodesMissing[inxLeft ..< nodesMissing.len]
      nodesMissing.setLen(inxLeft)
    else:
      fetchNodes = nodesMissing
      nodesMissing.setLen(0)

    when extraTraceMessages:
      trace "Accounts healing loop", peer,
        nAccounts=env.nAccounts,
        covered=buddy.coverageInfo(),
        nCheckAccountNodes=env.checkAccountNodes.len,
        nMissingAccountNodes=env.missingAccountNodes.len,
        nNodesMissing=nodesMissing.len,
        nLeaves

    # Fetch nodes from the network
    let dd = block:
      let rc = await buddy.getTrieNodes(stateRoot, fetchNodes.mapIt(@[it]))
      if rc.isErr:
        env.missingAccountNodes = env.missingAccountNodes & fetchNodes
        when extraTraceMessages:
          trace "Error fetching account nodes for healing", peer,
            nAccounts=env.nAccounts,
            covered=buddy.coverageInfo(),
            nCheckAccountNodes=env.checkAccountNodes.len,
            nMissingAccountNodes=env.missingAccountNodes.len,
            nNodesMissing=nodesMissing.len,
            nLeaves,
            error=rc.error
        # Just run the next lap
        continue
      rc.value

    # Store to disk and register left overs for the next pass
    block:
      let rc = ctx.data.snapDb.importRawNodes(peer, dd.nodes)
      if rc.isOk:
        env.checkAccountNodes = env.checkAccountNodes & dd.leftOver.mapIt(it[0])
      elif 0 < rc.error.len and rc.error[^1][0] < 0:
        # negative index => storage error
        env.missingAccountNodes = env.missingAccountNodes & fetchNodes
      else:
        env.missingAccountNodes = env.missingAccountNodes &
          dd.leftOver.mapIt(it[0]) & rc.error.mapIt(dd.nodes[it[0]])

    # End while

  when extraTraceMessages:
    trace "Done accounts healing", peer,
      nAccounts=env.nAccounts,
      covered=buddy.coverageInfo(),
      nCheckAccountNodes=env.checkAccountNodes.len,
      nMissingAccountNodes=env.missingAccountNodes.len,
      nLeaves

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
