# Nimbus - Fetch account and storage states from peers by trie traversal
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## This module fetches the Ethereum account state trie from network peers by
## traversing the trie from the root, making network requests.
##
## Requests are batched, pipelined, sorted, sliced and load-balanced.
##
## - Batching and pipelining improve network performance to each peer.
##
## - Load-balancing allows the available of multiple peers to be used.
##
## - Sorting and slicing is a key part of the pie sync algorithm, which allows
##   the entire Ethereum state to be fetched, even following hash trie
##   pointers, without significant random access database I/O.

import
  std/[sets, tables, algorithm],
  chronos,
  eth/[common/eth_types, p2p],
  ../../trace_helper,
  ".."/[base_desc, get_nodedata, path_desc, types, validate_trienode],
  "."/[common, peer_desc, sync_desc]

{.push raises: [Defect].}

const
  maxBatchGetNodeData = 384
    ## Maximum number of node hashes to batch per `GetNodeData` request.

  maxParallelGetNodeData = 32
    ## Maximum number of `GetNodeData` requests in parallel to a single peer.

type
  SingleNodeRequestEx = ref object of SingleNodeRequestBase
    hash:                   NodeHash
    path:                   InteriorPath
    future:                 Future[Blob]

proc hash(n: SingleNodeRequestBase): NodeHash =
  n.SingleNodeRequestEx.hash

proc path(n: SingleNodeRequestBase): InteriorPath =
  n.SingleNodeRequestEx.path

proc future(n: SingleNodeRequestBase): Future[Blob] =
  n.SingleNodeRequestEx.future


# Forward declaration.
proc scheduleBatchGetNodeData(fetch: FetchState) {.gcsafe.}

# ---

proc wrapCallGetNodeData(fetch: FetchState, hashes: seq[NodeHash],
                         futures: seq[Future[Blob]],
                         pathFrom, pathTo: InteriorPath) {.async.} =
  inc fetch.nodeGetsInFlight
  let reply = await fetch.sp.getNodeData(hashes, pathFrom, pathTo)

  # Timeout, packet and packet error trace messages are done in `get_nodedata`,
  # where there is more context than here.  Here we always received just valid
  # data with hashes already verified, or empty list of `nil`.
  if reply.isNil:
    # Timeout or error.
    fetch.sp.ctrl.runState = SyncStopRequest
    for i in 0 ..< futures.len:
      futures[i].complete(@[])

  elif reply.hashVerifiedData.len == 0:
    # Empty reply, matched to request.
    # It means there are none of the nodes available, but it's not an error.
    fetch.sp.ctrl.runState = SyncStopRequest
    for i in 0 ..< futures.len:
      futures[i].complete(@[])

  else:
    # Non-empty reply.
    for i in 0 ..< futures.len:
      let index = reply.reverseMap(i)
      if index >= 0:
        futures[i].complete(reply.hashVerifiedData[index])
      else:
        futures[i].complete(@[])

  dec fetch.nodeGetsInFlight
  # Receiving a reply may allow more requests to be sent.
  if fetch.nodeGetQueue.len > 0 and not fetch.scheduledBatch:
    fetch.scheduleBatchGetNodeData()

proc batchGetNodeData(fetch: FetchState) =
  var i = fetch.nodeGetQueue.len
  if i == 0 or fetch.nodeGetsInFlight >= maxParallelGetNodeData:
    return

  # WIP NOTE: The algorithm below is out of date and is not the final algorithm
  # (which doesn't need to sort).  Below gets some of the job done, but it can
  # exhaust memory in pathological cases depending how the peers respond, and
  # it cannot track prograss or batch the leaves for storage.  Its replacement
  # is actually simpler but depends on a data structure which has yet to be
  # merged.  Also, it doesn't use `Future` so much.
  #
  # OLD NOTE: Sort individual requests in order of path.  The sort is
  # descending order but they are popped off the end of the sequence (for O(1)
  # removal) so are processed in ascending order of path.
  #
  # For large state tries, this is important magic:
  #
  # - This sort and the bounded max nodes/requests limits together cause
  #   trie traversal to use depth-first order instead of breadth-first.
  # - More precisely, it uses approximate depth-first order, but if that
  #   would result in any unused capacity in the network request pipelining,
  #   that capacity is used to fetch additional nodes instead of wasted.
  # - Depth-first (approximate) has an important effect of limiting memory used.
  #   With breadth-first it would use a vast amount of memory on large tries.
  #
  # - The pipelining modification to depth-first completely changes network
  #   behaviour.  It allows a pipeline to bootstrap until it's properly full.
  # - Without the modification, strict depth-first would be much slower as
  #   every request would wait for a round-trip before starting the next.
  #
  # - The trie traversal is also in left-to-right path order (also approximate).
  # - The leaves are fetched in left-to-right path order (also approximate).
  #
  # - The left-to-right order is very beneficial to the remote database reads.
  # - Even though hashes for lookup are randomly ordered, and the remote must
  #   use them in lookups, many remote databases store the leaves in some way
  #   indexed by path.  If so, this order will greatly improve lookup locality,
  #   which directly reduces the amount of storage I/O time and latency.
  # - The left-to-right order is beneficial to the local database writes too.
  # - If the local database indexes by path, the left-to-right write order will
  #   increase storage density by a lot in a B-tree compared with random order.
  # - If the local database doesn't index by path at all, but does use "rowid"
  #   internally (like SQLite by default), the left-to-right write order will
  #   improve read performance when other peers sync reading this local node.

  proc cmpSingleNodeRequest(x, y: SingleNodeRequestBase): int =
    # `x` and `y` are deliberately swapped to get descending order.  See above.
    cmp(y.path, x.path)
  sort(fetch.nodeGetQueue, cmpSingleNodeRequest)

  trace "Trie: Sort length", sortLen=i

  # If stopped, abort all waiting nodes, so they clean up.
  if fetch.sp.ctrl.runState != SyncRunningOk:
    while i > 0:
      fetch.nodeGetQueue[i].future.complete(@[])
      dec i
    fetch.nodeGetQueue.setLen(0)
    return

  var hashes = newSeqOfCap[NodeHash](maxBatchGetNodeData)
  var futures = newSeqOfCap[Future[Blob]](maxBatchGetNodeData)
  while i > 0 and fetch.nodeGetsInFlight < maxParallelGetNodeData:
    var pathToIndex = -1
    var pathFromIndex = -1
    while i > 0 and futures.len < maxBatchGetNodeData:
      dec i
      if pathToIndex < 0 or
         fetch.nodeGetQueue[i].path > fetch.nodeGetQueue[pathToIndex].path:
        pathToIndex = i
      if pathFromIndex < 0 or
         fetch.nodeGetQueue[i].path < fetch.nodeGetQueue[pathFromIndex].path:
        pathFromIndex = i
      hashes.add(fetch.nodeGetQueue[i].hash)
      futures.add(fetch.nodeGetQueue[i].future)
    asyncSpawn fetch.wrapCallGetNodeData(hashes, futures,
                                         fetch.nodeGetQueue[pathFromIndex].path,
                                         fetch.nodeGetQueue[pathToIndex].path)
    hashes.setLen(0)
    futures.setLen(0)
    fetch.nodeGetQueue.setLen(i)

proc scheduleBatchGetNodeData(fetch: FetchState) =
  if not fetch.scheduledBatch:
    fetch.scheduledBatch = true
    proc batchGetNodeData(arg: pointer) =
      let fetch = cast[FetchState](arg)
      fetch.scheduledBatch = false
      fetch.batchGetNodeData()
    # We rely on `callSoon` scheduling for the _end_ of the current run list,
    # after other async functions finish adding more single node requests.
    callSoon(batchGetNodeData, cast[pointer](fetch))

proc getNodeData(fetch: FetchState,
                 hash: TrieHash, path: InteriorPath): Future[Blob] {.async.} =
  ## Request _one_ item of trie node data asynchronously.  This function
  ## batches requested into larger `eth.GetNodeData` requests efficiently.
  traceIndividualNode "> Fetching individual NodeData", peer=fetch.sp,
    depth=path.depth, path, hash=($hash)

  let future = newFuture[Blob]()
  fetch.nodeGetQueue.add SingleNodeRequestEx(
    hash: hash.NodeHash,
    path: path,
    future: future)

  if not fetch.scheduledBatch:
    fetch.scheduleBatchGetNodeData()
  let nodeBytes = await future

  if fetch.sp.ctrl.runState != SyncRunningOk:
    return nodebytes

  if tracePackets:
    doAssert nodeBytes.len == 0 or nodeBytes.toNodeHash == hash

  if nodeBytes.len > 0:
    traceIndividualNode "< Received individual NodeData", peer=fetch.sp,
      depth=path.depth, path, hash=($hash),
      nodeLen=nodeBytes.len, nodeBytes
  else:
    traceIndividualNode "< Received EMPTY individual NodeData", peer=fetch.sp,
      depth=path.depth, path, hash,
      nodeLen=nodeBytes.len
  return nodeBytes

proc pathInRange(fetch: FetchState, path: InteriorPath): bool =
  # TODO: This method is ugly and unnecessarily slow.
  var compare = fetch.leafRange.leafLow.toInteriorPath
  while compare.depth > path.depth:
    compare.pop()
  if path < compare:
    return false
  compare = fetch.leafRange.leafHigh.toInteriorPath
  while compare.depth > path.depth:
    compare.pop()
  if path > compare:
    return false
  return true

proc traverse(fetch: FetchState, hash: NodeHash, path: InteriorPath,
              fromExtension: bool) {.async.} =
  template errorReturn() =
    fetch.sp.ctrl.runState = SyncStopRequest
    dec fetch.nodesInFlight
    if fetch.nodesInFlight == 0:
      fetch.finish.complete()
    return

  # If something triggered stop earlier, don't request, and clean up now.
  if fetch.sp.ctrl.runState != SyncRunningOk:
    errorReturn()

  let nodeBytes = await fetch.getNodeData(hash.TrieHash, path)

  # If something triggered stop, clean up now.
  if fetch.sp.ctrl.runState != SyncRunningOk:
    errorReturn()
  # Don't keep emitting error messages after one error.  We'll allow 10.
  if fetch.getNodeDataErrors >= 10:
    errorReturn()

  var parseContext: TrieNodeParseContext # Default values are fine.
  try:
    fetch.sp.parseTrieNode(path, hash, nodeBytes, fromExtension, parseContext)
  except RlpError as e:
    fetch.sp.parseTrieNodeError(path, hash, nodeBytes, parseContext, e)

  if parseContext.errors > 0:
    debug "Aborting trie traversal due to errors", peer=fetch.sp
    inc fetch.getNodeDataErrors
    errorReturn()

  if parseContext.childQueue.len > 0:
    for i in 0 ..< parseContext.childQueue.len:
      let (nodePath, nodeHash, fromExtension) = parseContext.childQueue[i]
      # Discard traversals outside the current leaf range.
      if not fetch.pathInRange(nodePath):
        continue
      # Here, with `await` results in depth-first traversal and `asyncSpawn`
      # results in breadth-first.  Neither is what we really want.  Depth-first
      # is delayed by a round trip time for every node.  It's far too slow.
      # Pure breadth-first expands to an ever increasing pipeline of requests
      # until it runs out of memory, although network timing means that is
      # unlikely.  That's far too risky.  However the sorting in the request
      # dispatcher left-biases the traversal so that the out of memory
      # condition won't occur.
      inc fetch.nodesInFlight
      asyncSpawn fetch.traverse(nodeHash, nodePath, fromExtension)

  if parseContext.leafQueue.len > 0:
    for i in 0 ..< parseContext.leafQueue.len:
      let leafPtr = addr parseContext.leafQueue[i]
      template leafPath: auto = leafPtr[0]
      # Discard leaves outside the current leaf range.
      if leafPtr[0] < fetch.leafRange.leafLow or
         leafPtr[0] > fetch.leafRange.leafHigh:
        continue
      template leafBytes: auto = leafPtr[2]
      inc fetch.unwindAccounts
      fetch.unwindAccountBytes += leafBytes.len
      inc fetch.sp.nsx.sharedFetch.countAccounts
      fetch.sp.nsx.sharedFetch.countAccountBytes += leafBytes.len

  dec fetch.nodesInFlight
  if fetch.nodesInFlight == 0:
    fetch.finish.complete()

proc probeGetNodeData(sp: SnapPeerEx, stateRoot: TrieHash): Future[bool]
    {.async.} =
  # Before doing real trie traversal on this peer, send a probe request for
  # `stateRoot` to see if it's worth pursuing at all.  We will avoid reserving
  # a slice of leafspace, even temporarily, if no traversal will take place.
  #
  # Possible outcomes:
  #
  # - Trie root is returned.  Peers supporting `GetNodeData` do this as long as
  #   `stateRoot` is still in their pruning window, and isn't on a superseded
  #   chain branch.
  #
  # - Empty reply, meaning "I don't have the data".  Peers supporting
  #   `GetNodeData` do this when `stateRoot` is no longer available.
  #   OpenEthereum does this for all nodes from version 3.3.0-rc.8.
  #
  # - No reply at all (which is out of spec).  Erigon does this.  It should
  #   send an empty reply.  We don't want to cut off a peer for other purposes
  #   such as a source of blocks and transactions, just because it doesn't
  #   reply to `GetNodeData`.
  let reply = await sp.getNodeData(
    @[stateRoot.NodeHash], InteriorPath(), InteriorPath())
  return not reply.isNil and reply.hashVerifiedData.len == 1

proc trieFetch*(sp: SnapPeerEx, stateRoot: TrieHash,
                leafRange: LeafRange) {.async.} =
  if sp.fetchState.isNil:
    sp.fetchState = FetchState(sp: sp)
  template fetch: auto = sp.fetchState

  fetch.leafRange = leafRange
  fetch.finish = newFuture[void]()
  fetch.unwindAccounts = 0
  fetch.unwindAccountBytes = 0

  inc fetch.nodesInFlight
  await fetch.traverse(stateRoot.NodeHash, InteriorPath(), false)
  await fetch.finish
  if fetch.getNodeDataErrors == 0:
    sp.countSlice(leafRange, false)
  else:
    sp.nsx.sharedFetch.countAccounts -= fetch.unwindAccounts
    sp.nsx.sharedFetch.countAccountBytes -= fetch.unwindAccountBytes
    sp.putSlice(leafRange)

proc peerSupportsGetNodeData*(sp: SnapPeerEx): bool =
  sp.ctrl.runState != SyncStopped and
   (sp.fetchState.isNil or sp.fetchState.getNodeDataErrors == 0)
