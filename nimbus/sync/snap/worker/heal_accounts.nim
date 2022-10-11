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
##        v
##      <inspect-trie> <-----------------------------------+
##        |                                                |
##        v                                                |
##      {missing-nodes}                                    |
##        |                                                |
##        v                                                |
##      <get-trie-nodes-via-snap/1>                        |
##        |                                                |
##        v                                                |
##      <merge-nodes-into-database> ---> {check-nodes} ----+
##        |
##        v
##      {leaf-nodes}
##        |
##        v
##      <update-accounts-batch>
##        |
##        v
##      {storage-roots}
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
## * Input nodes for `<inspect-trie>` are checked for dangling child node
##   links which in turn are collected as output.
##
## * Nodes of the `{missing-nodes}` list are fetched from the network and
##   merged into the accounts trie database. Successfully processed nodes
##   are collected in the `{check-nodes}` list which is fed back into
##   the `<inspect-trie>` process.
##
## * If there is a problem with a node travelling from the source list
##   `{missing-nodes}` towards the target list `{check-nodes}`, this problem
##   node will simply held back in the source list.
##
##   In order to avoid unnecessary stale entries, the `{missing-nodes}`
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
  eth/[common/eth_types, p2p, trie/nibbles, trie/trie_defs, rlp],
  stew/[interval_set, keyed_queue],
   ../../../utils/prettify,
  ../../sync_desc,
  ".."/[range_desc, worker_desc],
  ./com/[com_error, get_trie_nodes],
  ./db/[hexary_desc, snap_db]

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
  env.fetchAccounts.unprocessed.emptyFactor.toPC(0) &
    "/" &
    ctx.data.coveredAccounts.fullFactor.toPC(0)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc kvAccountLeaf(
    buddy: SnapBuddyRef;
    partialPath: Blob;
    node: Blob;
      ): (bool,NodeKey,Account)
      {.gcsafe, raises: [Defect,RlpError]} =
  let
    env = buddy.data.pivotEnv
    nodeRlp = rlpFromBytes node
    (_,prefix) = hexPrefixDecode partialPath
    (_,segment) = hexPrefixDecode nodeRlp.listElem(0).toBytes
    nibbles = prefix & segment
  if nibbles.len == 64:
    let data = nodeRlp.listElem(1).toBytes
    return (true, nibbles.getBytes.convertTo(NodeKey), rlp.decode(data,Account))

  when extraTraceMessages:
    trace "Isolated node path for healing => ignored", peer=buddy.peer,
      nAccounts=env.nAccounts,
      covered=buddy.coverageInfo(),
      pathLen=nibbles.len,
      nibbles=nibbles.getBytes


proc registerAccountLeaf(
    buddy: SnapBuddyRef;
    accKey: NodeKey;
    acc: Account;
    slots: var seq[AccountSlotsHeader]) =
  let
    peer = buddy.peer
    env = buddy.data.pivotEnv
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

  if acc.storageRoot != emptyRlpHash:
    slots.add AccountSlotsHeader(
      accHash:     Hash256(data: accKey.ByteArray32),
      storageRoot: acc.storageRoot)

  when extraTraceMessages:
    trace "Isolated node for healing", peer,
      nAccounts=env.nAccounts,
      covered=buddy.coverageInfo(),
      accKey=pt


proc updateMissingNodesList(buddy: SnapBuddyRef) =
  ## Check whether previously missing nodes from the `missingNodes` list
  ## have been magically added to the database since it was checked last
  ## time. These nodes will me moved to `checkNodes` for further processing.
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot
  var
    nodes: seq[Blob]

  for accKey in env.fetchAccounts.missingNodes:
    let rc = ctx.data.snapDb.getAccountNodeKey(peer, stateRoot, accKey)
    if rc.isOk:
      # Check nodes for dangling links
      env.fetchAccounts.checkNodes.add accKey
    else:
      # Node is still missing
      nodes.add acckey

  env.fetchAccounts.missingNodes = nodes


proc fetchDanglingNodesList(
    buddy: SnapBuddyRef
      ): Result[TrieNodeStat,HexaryDbError] =
  ## Starting with a given set of potentially dangling account nodes
  ## `checkNodes`, this set is filtered and processed. The outcome is
  ## fed back to the vey same list `checkNodes`
  let
    ctx = buddy.ctx
    peer = buddy.peer
    env = buddy.data.pivotEnv
    stateRoot = env.stateHeader.stateRoot

    rc = ctx.data.snapDb.inspectAccountsTrie(
      peer, stateRoot, env.fetchAccounts.checkNodes)

  if rc.isErr:
    # Attempt to switch peers, there is not much else we can do here
    buddy.ctrl.zombie = true
    return err(rc.error)

  # Global/env batch list to be replaced by by `rc.value.leaves` return value
  env.fetchAccounts.checkNodes.setLen(0)

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
        nCheckNodes=env.fetchAccounts.checkNodes.len,
        nMissingNodes=env.fetchAccounts.missingNodes.len
    return

  when extraTraceMessages:
    trace "Start accounts healing", peer,
      nAccounts=env.nAccounts,
      covered=buddy.coverageInfo(),
      nCheckNodes=env.fetchAccounts.checkNodes.len,
      nMissingNodes=env.fetchAccounts.missingNodes.len

  # Update for changes since last visit
  buddy.updateMissingNodesList()

  # If `checkNodes` is empty, healing is at the very start or was
  # postponed in which case `missingNodes` is non-empty.
  var
    doNodesMissing: seq[Blob] # Nodes to process by this instance

  if env.fetchAccounts.checkNodes.len != 0 or
     env.fetchAccounts.missingNodes.len == 0:
    let rc = buddy.fetchDanglingNodesList()
    if rc.isErr:
      error "Accounts healing failed => stop", peer,
        nAccounts=env.nAccounts,
        covered=buddy.coverageInfo(),
        nCheckNodes=env.fetchAccounts.checkNodes.len,
        nMissingNodes=env.fetchAccounts.missingNodes.len,
        error=rc.error
      return

    doNodesMissing = rc.value.dangling

  # Check whether the trie is complete.
  if doNodesMissing.len == 0 and env.fetchAccounts.missingNodes.len == 0:
    when extraTraceMessages:
      trace "Accounts healing complete", peer,
        nAccounts=env.nAccounts,
        covered=buddy.coverageInfo(),
        nCheckNodes=0,
        nMissingNodes=0,
        nDoNodesMissing=0
    return # nothing to do

  # Ok, clear global `env.missingNodes` list and process `doNodesMissing`.
  doNodesMissing = doNodesMissing & env.fetchAccounts.missingNodes
  env.fetchAccounts.missingNodes.setlen(0)

  # Fetch nodes, merge it into database and feed back results
  while 0 < doNodesMissing.len:
    var fetchNodes: seq[Blob]
    # There is no point in processing too many nodes at the same time. So
    # leave the rest on the `doNodesMissing` queue for a moment.
    if maxTrieNodeFetch < doNodesMissing.len:
      let inxLeft = doNodesMissing.len - maxTrieNodeFetch
      fetchNodes = doNodesMissing[inxLeft ..< doNodesMissing.len]
      doNodesMissing.setLen(inxLeft)
    else:
      fetchNodes = doNodesMissing
      doNodesMissing.setLen(0)

    when extraTraceMessages:
      trace "Accounts healing loop", peer,
        nAccounts=env.nAccounts,
        covered=buddy.coverageInfo(),
        nCheckNodes=env.fetchAccounts.checkNodes.len,
        nMissingNodes=env.fetchAccounts.missingNodes.len,
        nDoNodesMissing=doNodesMissing.len

    # Fetch nodes from the network
    let dd = block:
      let rc = await buddy.getTrieNodes(stateRoot, fetchNodes.mapIt(@[it]))
      if rc.isErr:
        env.fetchAccounts.missingNodes =
          env.fetchAccounts.missingNodes & fetchNodes
        let error = rc.error
        when extraTraceMessages:
          trace "Error fetching account nodes for healing", peer,
            nAccounts=env.nAccounts,
            covered=buddy.coverageInfo(),
            nCheckNodes=env.fetchAccounts.checkNodes.len,
            nMissingNodes=env.fetchAccounts.missingNodes.len,
            nDoNodesMissing=doNodesMissing.len,
            error
        if await buddy.ctrl.stopAfterSeriousComError(error, buddy.data.errors):
          env.fetchAccounts.missingNodes =
            env.fetchAccounts.missingNodes & doNodesMissing
          return
        continue # just run the next lap
      rc.value

    # Store to disk and register left overs for the next pass
    block:
      env.fetchAccounts.checkNodes =
        env.fetchAccounts.checkNodes & dd.leftOver.mapIt(it[0])

      let (_,report) = ctx.data.snapDb.importRawAccountNodes(peer, dd.nodes)
      if dd.nodes.len < report.len:
        # Storage error, just run the next lap
        env.fetchAccounts.missingNodes =
          env.fetchAccounts.missingNodes & fetchNodes

      else:
        var withStorage: seq[AccountSlotsHeader]

        # Filter out errors and leaf nodes
        for n,w in report:
          let nodePath = fetchNodes[n]
          if w.error != NothingSerious or w.kind.isNone:
            # error, try downloading again
            env.fetchAccounts.missingNodes.add nodePath

          elif w.kind.unsafeGet != Leaf:
            # re-check this node
            env.fetchAccounts.checkNodes.add nodePath

          else:
            # Node has been stored, double check
            let (ok, key, acc) = buddy.kvAccountLeaf(nodePath, dd.nodes[n])
            if ok:
              # Update `uprocessed` registry and collect storage root (if any)
              buddy.registerAccountLeaf(key, acc, withStorage)
            else:
              env.fetchAccounts.checkNodes.add nodePath

          # End `for`

        if 0 < withStorage.len:
          discard env.fetchStorage.append SnapSlotQueueItemRef(q: withStorage)

    # End while

  when extraTraceMessages:
    trace "Done accounts healing", peer,
      nAccounts=env.nAccounts,
      covered=buddy.coverageInfo(),
      nCheckNodes=env.fetchAccounts.checkNodes.len,
      nMissingNodes=env.fetchAccounts.missingNodes.len

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
