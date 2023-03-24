# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Heal accounts DB
## ================
##
## This module is a variation of the `swap-in` module in the sense that it
## searches for missing nodes in the database (which means that nodes which
## link to missing ones must exist), and then fetches the nodes from the
## network.
##
## Algorithm
## ---------
##
## * Run `swapInAccounts()` so that inheritable sub-tries are imported from
##   previous pivots.
##
## * Find dangling nodes in the current account trie via `findMissingNodes()`.
##
## * Install that nodes from the network.
##
## * Rinse and repeat
##
## Discussion
## ----------
##
## A worst case scenario of a portentally failing `findMissingNodes()` call
## must be solved by fetching and storing more accounts and running this
## healing algorithm again.
##

{.push raises: [].}

import
  std/[math, sequtils, sets, tables],
  chronicles,
  chronos,
  eth/[common, p2p, trie/nibbles, trie/trie_defs, rlp],
  stew/[byteutils, interval_set],
  ../../../../utils/prettify,
  "../../.."/[sync_desc, protocol, types],
  "../.."/[constants, range_desc, worker_desc],
  ../com/[com_error, get_trie_nodes],
  ../db/[hexary_desc, hexary_envelope, hexary_error, hexary_nearby,
         hexary_paths, hexary_range, snapdb_accounts],
  "."/[find_missing_nodes, storage_queue_helper, swap_in]

logScope:
  topics = "snap-heal"

const
  extraTraceMessages = false or true
    ## Enabled additional logging noise

  EmptyBlobSet = HashSet[Blob].default

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template logTxt(info: static[string]): static[string] =
  "Accounts healing " & info

proc `$`(node: NodeSpecs): string =
  node.partialPath.toHex

proc `$`(rs: NodeTagRangeSet): string =
  let ff = rs.fullFactor
  if 0.99 <= ff and ff < 1.0: "99%" else: ff.toPC(0)

proc `$`(iv: NodeTagRange): string =
  iv.fullFactor.toPC(3)

proc toPC(w: openArray[NodeSpecs]; n: static[int] = 3): string =
  let sumUp = w.mapIt(it.hexaryEnvelope.len).foldl(a+b, 0.u256)
  (sumUp.to(float) / (2.0^256)).toPC(n)

proc healingCtx(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ): string =
  let ctx = buddy.ctx
  "{" &
    "pivot=" & "#" & $env.stateHeader.blockNumber & "," &
    "nAccounts=" & $env.nAccounts & "," &
    ("covered=" & $env.fetchAccounts.processed & "/" &
                  $ctx.pool.coveredAccounts ) & "}"

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
    env: SnapPivotRef;
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ## Find some missing glue nodes in accounts database.
  let
    ctx = buddy.ctx
    peer {.used.} = buddy.peer
    rootKey = env.stateHeader.stateRoot.to(NodeKey)
    getFn = ctx.pool.snapDb.getAccountFn
    fa {.used.} = env.fetchAccounts

  # Import from earlier run
  if ctx.swapInAccounts(env) != 0:
    discard ctx.swapInAccounts(env)

  if not fa.processed.isFull:
    let mlv = await fa.findMissingNodes(
      rootKey, getFn,
      healAccountsInspectionPlanBLevel,
      healAccountsInspectionPlanBRetryMax,
      healAccountsInspectionPlanBRetryNapMSecs)

    # Clean up empty account ranges found while looking for nodes
    if not mlv.emptyGaps.isNil:
      for w in mlv.emptyGaps.increasing:
        discard env.fetchAccounts.processed.merge w
        env.fetchAccounts.unprocessed.reduce w
        discard buddy.ctx.pool.coveredAccounts.merge w

    when extraTraceMessages:
      trace logTxt "missing nodes", peer,
        ctx=buddy.healingCtx(env), nLevel=mlv.level, nVisited=mlv.visited,
        nResult=mlv.missing.len, result=mlv.missing.toPC

    return mlv.missing


proc fetchMissingNodes(
    buddy: SnapBuddyRef;
    missingNodes: seq[NodeSpecs];       # Nodes to fetch from the network
    ignore: HashSet[Blob];              # Except for these partial paths listed
    env: SnapPivotRef;
      ): Future[seq[NodeSpecs]]
      {.async.} =
  ## Extract from `nodes.missing` the next batch of nodes that need
  ## to be merged it into the database
  let
    ctx {.used.} = buddy.ctx
    peer {.used.} = buddy.peer
    rootHash = env.stateHeader.stateRoot
    pivot = "#" & $env.stateHeader.blockNumber # for logging

  # Initalise for fetching nodes from the network via `getTrieNodes()`
  var
    nodeKey: Table[Blob,NodeKey] # Temporary `path -> key` mapping
    pathList: seq[SnapTriePaths] # Function argument for `getTrieNodes()`

  # There is no point in fetching too many nodes as it will be rejected. So
  # rest of the `missingNodes` list is ignored to be picked up later.
  for w in missingNodes:
    if w.partialPath notin ignore and not nodeKey.hasKey(w.partialPath):
      pathList.add SnapTriePaths(accPath: w.partialPath)
      nodeKey[w.partialPath] = w.nodeKey
      if fetchRequestTrieNodesMax <= pathList.len:
        break

  if 0 < pathList.len:
    # Fetch nodes from the network.
    let rc = await buddy.getTrieNodes(rootHash, pathList, pivot)
    if rc.isOk:
      # Reset error counts for detecting repeated timeouts, network errors, etc.
      buddy.only.errors.resetComError()

      # Forget about unfetched missing nodes, will be picked up later
      return rc.value.nodes.mapIt(NodeSpecs(
        partialPath: it.partialPath,
        nodeKey:     nodeKey[it.partialPath],
        data:        it.data))

    # Process error ...
    let
      error = rc.error
      ok = await buddy.ctrl.stopAfterSeriousComError(error, buddy.only.errors)
    when extraTraceMessages:
      trace logTxt "reply error", peer, ctx=buddy.healingCtx(env),
         error, stop=ok

  return @[]


proc kvAccountLeaf(
    buddy: SnapBuddyRef;
    node: NodeSpecs;
    env: SnapPivotRef;
      ): (bool,NodeKey,Account) =
  ## Re-read leaf node from persistent database (if any)
  let
    peer {.used.} = buddy.peer
  var
    nNibbles = -1

  discardRlpError("kvAccountLeaf"):
    let
      nodeRlp = rlpFromBytes node.data
      prefix = (hexPrefixDecode node.partialPath)[1]
      segment = (hexPrefixDecode nodeRlp.listElem(0).toBytes)[1]
      nibbles = prefix & segment

    nNibbles = nibbles.len
    if nNibbles == 64:
      let
        data = nodeRlp.listElem(1).toBytes
        nodeKey = nibbles.getBytes.convertTo(NodeKey)
        accData = rlp.decode(data,Account)
      return (true, nodeKey, accData)

  when extraTraceMessages:
    trace logTxt "non-leaf node path or corrupt data", peer,
      ctx=buddy.healingCtx(env), nNibbles


proc registerAccountLeaf(
    buddy: SnapBuddyRef;
    accKey: NodeKey;
    acc: Account;
    env: SnapPivotRef;
      ) =
  ## Process single account node as would be done with an interval by
  ## the `storeAccounts()` function
  let
    ctx = buddy.ctx
    peer = buddy.peer
    rootKey = env.stateHeader.stateRoot.to(NodeKey)
    getFn = ctx.pool.snapDb.getAccountFn
    pt = accKey.to(NodeTag)

  # Extend interval [pt,pt] if possible
  var iv: NodeTagRange
  try:
    iv = getFn.hexaryRangeInflate(rootKey, pt)
  except CatchableError as e:
    error logTxt "inflating interval oops", peer, ctx=buddy.healingCtx(env),
      accKey, name=($e.name), msg=e.msg
    iv = NodeTagRange.new(pt,pt)

  # Register isolated leaf node
  if 0 < env.fetchAccounts.processed.merge iv:
    env.nAccounts.inc
    env.fetchAccounts.unprocessed.reduce iv
    discard buddy.ctx.pool.coveredAccounts.merge iv

    # Update storage slots batch
    if acc.storageRoot != emptyRlpHash:
      env.storageQueueAppendFull(acc.storageRoot, accKey)

  #when extraTraceMessages:
  #  trace logTxt "registered single account", peer, ctx=buddy.healingCtx(env),
  #    leftSlack=(iv.minPt < pt), rightSlack=(pt < iv.maxPt)

# ------------------------------------------------------------------------------
# Private functions: do the healing for one round
# ------------------------------------------------------------------------------

proc accountsHealingImpl(
    buddy: SnapBuddyRef;
    ignore: HashSet[Blob];
    env: SnapPivotRef;
      ): Future[(int,HashSet[Blob])]
      {.async.} =
  ## Fetching and merging missing account trie database nodes. It returns the
  ## number of nodes fetched from the network, and -1 upon error.
  let
    ctx = buddy.ctx
    db = ctx.pool.snapDb
    peer = buddy.peer

  # Import from earlier runs (if any)
  while ctx.swapInAccounts(env) != 0:
    discard

  # Update for changes since last visit
  let missingNodes = await buddy.compileMissingNodesList(env)
  if missingNodes.len == 0:
    # Nothing to do
    trace logTxt "nothing to do", peer, ctx=buddy.healingCtx(env)
    return (0,EmptyBlobSet) # nothing to do

  # Get next batch of nodes that need to be merged it into the database
  let fetchedNodes = await buddy.fetchMissingNodes(missingNodes, ignore, env)
  if fetchedNodes.len == 0:
    return (0,EmptyBlobSet)

  # Store nodes onto disk
  let
    nFetchedNodes = fetchedNodes.len
    report = db.importRawAccountsNodes(peer, fetchedNodes)

  if 0 < report.len and report[^1].slot.isNone:
    # Storage error, just run the next lap (not much else that can be done)
    error logTxt "error updating persistent database", peer,
      ctx=buddy.healingCtx(env), nFetchedNodes, error=report[^1].error
    return (-1,EmptyBlobSet)

  # Filter out error and leaf nodes
  var
    nLeafNodes = 0 # for logging
    rejected: HashSet[Blob]
  for w in report:
    if w.slot.isSome: # non-indexed entries appear typically at the end, though
      let inx = w.slot.unsafeGet

      # Node error, will need to pick up later and download again. Node that
      # there need not be an expicit node specs (so `kind` is opted out.)
      if w.kind.isNone or w.error != HexaryError(0):
        rejected.incl fetchedNodes[inx].partialPath

      elif w.kind.unsafeGet == Leaf:
        # Leaf node has been stored, double check
        let (isLeaf, key, acc) = buddy.kvAccountLeaf(fetchedNodes[inx], env)
        if isLeaf:
          # Update `unprocessed` registry, collect storage roots (if any)
          buddy.registerAccountLeaf(key, acc, env)
          nLeafNodes.inc

  when extraTraceMessages:
    trace logTxt "merged into database", peer, ctx=buddy.healingCtx(env),
      nFetchedNodes, nLeafNodes, nRejected=rejected.len

  return (nFetchedNodes - rejected.len, rejected)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc healAccounts*(
    buddy: SnapBuddyRef;
    env: SnapPivotRef;
      ) {.async.} =
  ## Fetching and merging missing account trie database nodes.
  when extraTraceMessages:
    let
      ctx {.used.} = buddy.ctx
      peer {.used.} = buddy.peer
    trace logTxt "started", peer, ctx=buddy.healingCtx(env)

  let
    fa = env.fetchAccounts
  var
    nNodesFetched = 0
    nFetchLoop = 0
    ignore: HashSet[Blob]

  while not fa.processed.isFull() and
        buddy.ctrl.running and
        not env.archived:
    var (nNodes, rejected) = await buddy.accountsHealingImpl(ignore, env)
    if nNodes <= 0:
      break
    ignore = ignore + rejected
    nNodesFetched.inc(nNodes)
    nFetchLoop.inc

  when extraTraceMessages:
    trace logTxt "job done", peer, ctx=buddy.healingCtx(env),
      nNodesFetched, nFetchLoop, nIgnore=ignore.len, runState=buddy.ctrl.state

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
