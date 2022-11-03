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
##        |   +--------------------------------+
##        |   |                                |
##        v   v                                |
##      <inspect-trie>                         |
##        |                                    |
##        |   +--------------------------+     |
##        |   |   +--------------------+ |     |
##        |   |   |                    | |     |
##        v   v   v                    | |     |
##      {missing-nodes}                | |     |
##        |                            | |     |
##        v                            | |     |
##      <get-trie-nodes-via-snap/1> ---+ |     |
##        |                              |     |
##        v                              |     |
##      <merge-nodes-into-database> -----+     |
##        |                 |                  |
##        v                 v                  |
##      {leaf-nodes}      {check-nodes} -------+
##        |
##        v                                 \
##      <update-accounts-batch>             |
##        |                                 |  similar actions for single leaf
##        v                                  \ nodes that otherwise would be
##      {storage-roots}                      / done for account hash ranges in
##        |                                 |  the function storeAccounts()
##        v                                 |
##      <update-storage-processor-batch>    /
##
## Legend:
## * `<..>`: some action, process, etc.
## * `{missing-nodes}`: list implemented as `env.fetchAccounts.missingNodes`
## * `(state-root}`: implicit argument for `getAccountNodeKey()` when
##   the argument list is empty
## * `{leaf-nodes}`: list is optimised out
## * `{check-nodes}`: list implemented as `env.fetchAccounts.checkNodes`
## * `{storage-roots}`: list implemented as pair of queues
##   `env.fetchStorageFull` and `env.fetchStoragePart`
##
## Discussion of flow chart
## ------------------------
## * Input nodes for `<inspect-trie>` are checked for dangling child node
##   links which in turn are collected as output.
##
## * Nodes of the `{missing-nodes}` list are fetched from the network and
##   merged into the persistent accounts trie database.
##   + Successfully merged non-leaf nodes are collected in the `{check-nodes}`
##     list which is fed back into the `<inspect-trie>` process.
##   + Successfully merged leaf nodes are processed as single entry accounts
##     node ranges.
##
## * If there is a problem with a node travelling from the source list
##   `{missing-nodes}` towards either target list `{leaf-nodes}` or
##   `{check-nodes}`, this problem node will fed back to the `{missing-nodes}`
##   source list.
##
## * In order to avoid double processing, the `{missing-nodes}` list is
##   regularly checked for whether nodes are still missing or some other
##   process has done the magic work of merging some of then into the
##   trie database.
##
## Competing with other trie algorithms
## ------------------------------------
## * Healing runs (semi-)parallel to processing *GetAccountRange* network
##   messages from the `snap/1` protocol (see `storeAccounts()`). Considering
##   network bandwidth, the *GetAccountRange* message processing is way more
##   efficient in comparison with the healing algorithm as there are no
##   intermediate trie nodes involved.
##
## * The healing algorithm visits all nodes of a complete trie unless it is
##   stopped in between.
##
## * If a trie node is missing, it can be fetched directly by the healing
##   algorithm or one can wait for another process to do the job. Waiting for
##   other processes to do the job also applies to problem nodes (and vice
##   versa.)
##
## * Network bandwidth can be saved if nodes are fetched by the more efficient
##   *GetAccountRange* message processing (if that is available.) This suggests
##   that fetching missing trie nodes by the healing algorithm should kick in
##   very late when the trie database is nearly complete.
##
## * Healing applies to a hexary trie database associated with the currently
##   latest *state root*, where tha latter may change occasionally. This
##   suggests to start the healing algorithm very late at a time when most of
##   the accounts have been updated by any *state root*, already. There is a
##   good chance that the healing algorithm detects and activates account data
##   from previous *state roots* that have not changed.

import
  std/sequtils,
  chronicles,
  chronos,
  eth/[common, p2p, trie/nibbles, trie/trie_defs, rlp],
  stew/[interval_set, keyed_queue],
  ../../../utils/prettify,
  ../../sync_desc,
  ".."/[constants, range_desc, worker_desc],
  ./com/[com_error, get_trie_nodes],
  ./db/[hexary_desc, hexary_error, snapdb_accounts]

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
  "Accounts healing " & info

proc healingCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string =
  let ctx = buddy.ctx
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "nAccounts=" & $env.nAccounts & "," &
    ("covered=" & env.fetchAccounts.unprocessed.emptyFactor.toPC(0) & "/" &
        ctx.data.coveredAccounts.fullFactor.toPC(0)) & "," &
    "nCheckNodes=" & $env.fetchAccounts.checkNodes.len & "," &
    "nMissingNodes=" & $env.fetchAccounts.missingNodes.len & "}"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc updateMissingNodesList(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) =
  ## Check whether previously missing nodes from the `missingNodes` list
  ## have been magically added to the database since it was checked last
  ## time. These nodes will me moved to `checkNodes` for further processing.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot

  var delayed: seq[NodeSpecs]
  for w in env.fetchAccounts.missingNodes:
    let rc = db.getAccountsNodeKey(peer, stateRoot, w.partialPath)
    if rc.isOk:
      # Check nodes for dangling links
      env.fetchAccounts.checkNodes.add w.partialPath
    else:
      # Node is still missing
      delayed.add w

  # Must not modify sequence while looping over it
  env.fetchAccounts.missingNodes = env.fetchAccounts.missingNodes & delayed


proc appendMoreDanglingNodesToMissingNodesList(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): bool =
  ## Starting with a given set of potentially dangling account nodes
  ## `checkNodes`, this set is filtered and processed. The outcome is
  ## fed back to the vey same list `checkNodes`
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot

    rc = db.inspectAccountsTrie(peer, stateRoot, env.fetchAccounts.checkNodes)

  if rc.isErr:
    when extraTraceMessages:
      error logTxt "failed => stop", peer,
        ctx=buddy.healingCtx(env), error=rc.error
    # Attempt to switch peers, there is not much else we can do here
    buddy.ctrl.zombie = true
    return false

  # Global/env batch list to be replaced by by `rc.value.leaves` return value
  env.fetchAccounts.checkNodes.setLen(0)
  env.fetchAccounts.missingNodes =
    env.fetchAccounts.missingNodes & rc.value.dangling

  true


proc getMissingNodesFromNetwork(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ## Extract from `missingNodes` the next batch of nodes that need
  ## to be merged it into the database
  let
    ctx = buddy.ctx
    peer = buddy.peer
    stateRoot = env.stateHeader.stateRoot
    pivot = "#" & $env.stateHeader.blockNumber # for logging

    nMissingNodes = env.fetchAccounts.missingNodes.len
    inxLeft = max(0, nMissingNodes - snapTrieNodeFetchMax)

  # There is no point in processing too many nodes at the same time. So leave
  # the rest on the `missingNodes` queue to be handled later.
  let fetchNodes = env.fetchAccounts.missingNodes[inxLeft ..< nMissingNodes]
  env.fetchAccounts.missingNodes.setLen(inxLeft)

  # Initalise for `getTrieNodes()` for fetching nodes from the network
  var
    nodeKey: Table[Blob,NodeKey] # Temporary `path -> key` mapping
    pathList: seq[seq[Blob]]     # Function argument for `getTrieNodes()`
  for w in fetchNodes:
    pathList.add @[w.partialPath]
    nodeKey[w.partialPath] = w.nodeKey

  # Fetch nodes from the network. Note that the remainder of the `missingNodes`
  # list might be used by another process that runs semi-parallel.
  let rc = await buddy.getTrieNodes(stateRoot, pathList, pivot)
  if rc.isOk:
    # Reset error counts for detecting repeated timeouts, network errors, etc.
    buddy.data.errors.resetComError()

    # Register unfetched missing nodes for the next pass
    for w in rc.value.leftOver:
      env.fetchAccounts.missingNodes.add NodeSpecs(
        partialPath: w[0],
        nodeKey:     nodeKey[w[0]])
    return rc.value.nodes.mapIt(NodeSpecs(
      partialPath: it.partialPath,
      nodeKey:     nodeKey[it.partialPath],
      data:        it.data))

  # Restore missing nodes list now so that a task switch in the error checker
  # allows other processes to access the full `missingNodes` list.
  env.fetchAccounts.missingNodes = env.fetchAccounts.missingNodes & fetchNodes

  let error = rc.error
  if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
    discard
    when extraTraceMessages:
      trace logTxt "fetch nodes error => stop", peer,
        ctx=buddy.healingCtx(env), error
  else:
    discard
    when extraTraceMessages:
      trace logTxt "fetch nodes error", peer,
        ctx=buddy.healingCtx(env), error

  return @[]


proc kvAccountLeaf(
    buddy: SnapBuddyRef;
    node: NodeSpecs;
    env: SnapPivotRef;
      ): (bool,NodeKey,Account)
      {.gcsafe, raises: [Defect,RlpError]} =
  ## Re-read leaf node from persistent database (if any)
  let
    peer = buddy.peer

    nodeRlp = rlpFromBytes node.data
    (_,prefix) = hexPrefixDecode node.partialPath
    (_,segment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
    nibbles = prefix & segment
  if nibbles.len == 64:
    let data = nodeRlp.listElem(1).toBytes
    return (true, nibbles.getBytes.convertTo(NodeKey), rlp.decode(data,Account))

  when extraTraceMessages:
    trace logTxt "non-leaf node path", peer,
      ctx=buddy.healingCtx(env), nNibbles=nibbles.len


proc registerAccountLeaf(
    buddy: SnapBuddyRef;
    accKey: NodeKey;
    acc: Account;
    env: SnapPivotRef;
      ) =
  ## Process single account node as would be done with an interval by
  ## the `storeAccounts()` function
  let
    peer = buddy.peer
    pt = accKey.to(NodeTag)

  # Find range set (from list) containing `pt`
  var ivSet: NodeTagRangeSet
  block foundCoveringRange:
    for w in env.fetchAccounts.unprocessed:
      if 0 < w.covered(pt,pt):
        ivSet = w
        break foundCoveringRange
    return # already processed, forget this account leaf

  # Register this isolated leaf node that was added
  env.nAccounts.inc
  discard ivSet.reduce(pt,pt)
  discard buddy.ctx.data.coveredAccounts.merge(pt,pt)

  # Update storage slots batch
  if acc.storageRoot != emptyRlpHash:
    env.fetchStorageFull.merge AccountSlotsHeader(
      acckey:      accKey,
      storageRoot: acc.storageRoot)

# ------------------------------------------------------------------------------
# Private functions: do the healing for one round
# ------------------------------------------------------------------------------

proc accountsHealingImpl(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): Future[int]
      {.async.} =
  ## Fetching and merging missing account trie database nodes. It returns the
  ## number of nodes fetched from the network, and -1 upon error.
  let
    ctx = buddy.ctx
    db = ctx.data.snapDb
    peer = buddy.peer

  # Update for changes since last visit
  buddy.updateMissingNodesList(env)

  # If `checkNodes` is empty, healing is at the very start or was
  # postponed in which case `missingNodes` is non-empty.
  if env.fetchAccounts.checkNodes.len != 0 or
     env.fetchAccounts.missingNodes.len == 0:
    if not buddy.appendMoreDanglingNodesToMissingNodesList(env):
      return 0

  # Check whether the trie is complete.
  if env.fetchAccounts.missingNodes.len == 0:
    trace logTxt "complete", peer, ctx=buddy.healingCtx(env)
    return 0 # nothing to do

  # Get next batch of nodes that need to be merged it into the database
  let nodeSpecs = await buddy.getMissingNodesFromNetwork(env)
  if nodeSpecs.len == 0:
    return 0

  # Store nodes onto disk
  let report = db.importRawAccountsNodes(peer, nodeSpecs)
  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    error logTxt "error updating persistent database", peer,
      ctx=buddy.healingCtx(env), nNodes=nodeSpecs.len, error=report[^1].error
    env.fetchAccounts.missingNodes = env.fetchAccounts.missingNodes & nodeSpecs
    return -1

  # Filter out error and leaf nodes
  var nLeafNodes = 0 # for logging
  for w in report:
    if w.slot.isSome: # non-indexed entries appear typically at the end, though
      let
        inx = w.slot.unsafeGet
        nodePath = nodeSpecs[inx].partialPath

      if w.error != NothingSerious or w.kind.isNone:
        # error, try downloading again
        env.fetchAccounts.missingNodes.add nodeSpecs[inx]

      elif w.kind.unsafeGet != Leaf:
        # re-check this node
        env.fetchAccounts.checkNodes.add nodePath

      else:
        # Node has been stored, double check
        let (isLeaf, key, acc) = buddy.kvAccountLeaf(nodeSpecs[inx], env)
        if isLeaf:
          # Update `uprocessed` registry, collect storage roots (if any)
          buddy.registerAccountLeaf(key, acc, env)
          nLeafNodes.inc
        else:
          env.fetchAccounts.checkNodes.add nodePath

  when extraTraceMessages:
    trace logTxt "merged into database", peer,
      ctx=buddy.healingCtx(env), nNodes=nodeSpecs.len, nLeafNodes

  return nodeSpecs.len

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healAccounts*(buddy: SnapBuddyRef) {.async.} =
  ## Fetching and merging missing account trie database nodes.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv

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
    #when extraTraceMessages:
    #  trace logTxt "postponed", peer, ctx=buddy.healingCtx(env)
    return

  when extraTraceMessages:
    trace logTxt "started", peer, ctx=buddy.healingCtx(env)

  var
    nNodesFetched = 0
    nFetchLoop = 0
  # Stop after `snapAccountsHealBatchFetchMax` nodes have been fetched
  while nNodesFetched < snapAccountsHealBatchFetchMax:
    var nNodes = await buddy.accountsHealingImpl(env)
    if nNodes <= 0:
      break
    nNodesFetched.inc(nNodes)
    nFetchLoop.inc

  when extraTraceMessages:
    trace logTxt "job done", peer, ctx=buddy.healingCtx(env),
      nNodesFetched, nFetchLoop, runState=buddy.ctrl.state

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
