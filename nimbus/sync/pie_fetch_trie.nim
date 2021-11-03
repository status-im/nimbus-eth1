# Nimbus - Fetch entire state from peers by trie traversal
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module fetches the entire Ethereum account state trie from network
## peers by traversing the trie from the root, making network requests.
##
## Requests are batched, pipelined, sorted, sliced and load-balanced.
##
## - Batching and pipelining improve network performance to each peer.
##
## - Load-balancing allows the available of multiple peers to be used.
##
## - Sorting and slicing is a key part of the pie sync algorithm, which
##   allows the entire Ethereum state to be fetched, following hashes,
##   without any significant random access I/O to the database.

{.push raises: [Defect].}

import
  std/[sets, tables, algorithm],
  chronos, stint, nimcrypto/keccak,
  eth/[common/eth_types, rlp, p2p],
  "."/[sync_types, get_nodedata, validate_trienode]

type
  LeafRange = object
    leafLow, leafHigh:      LeafPath

  SharedFetchState = ref object of typeof SyncPeer().sharedFetchBase
    ## Account fetching state that is shared among all peers.
    # Leaf path ranges not fetched or in progress on any peer.
    leafRanges:             seq[LeafRange]

  FetchState = ref object of typeof SyncPeer().fetchBase
    ## Account fetching state on a single peer.
    sp:                     SyncPeer
    nodeGetQueue:           seq[SingleNodeRequest]
    nodeGetsInFlight:       int
    scheduledBatch:         bool
    progressPrefix:         string
    progressCount:          int

  SingleNodeRequest = ref object
    hash:                   NodeHash
    path:                   InteriorPath
    future:                 Future[Blob]

template sharedFetch*(sp: SyncPeer): auto =
  sync_types.sharedFetchBase(sp).SharedFetchState

template fetch*(sp: SyncPeer): auto =
  sync_types.fetchBase(sp).FetchState

const
  maxBatchGetNodeData = 384
    ## Maximum number of node hashes to batch per `GetNodeData` request.

  maxParallelGetNodeData = 32
    ## Maximum number of `GetNodeData` requests in parallel to a single peer.

# Forward declaration.
proc scheduleBatchGetNodeData(fetch: FetchState) {.gcsafe.}

proc wrapCallGetNodeData(fetch: FetchState, hashes: seq[NodeHash],
                         futures: seq[Future[Blob]],
                         pathFrom, pathTo: InteriorPath) {.async.} =
  inc fetch.nodeGetsInFlight
  let reply = await fetch.sp.getNodeData(hashes, pathFrom, pathTo)

  # Timeout, packet and packet error trace messages are done in `onNodeData`
  # and `nodeDataTimeout`, where there is more context than here.  Here we
  # always received just valid data with hashes already verified, or `nil`.
  if reply.isNil:
    # Timeout or error.
    for i in 0 ..< futures.len:
      futures[i].complete(@[])
  elif reply.hashVerifiedData.len == 0:
    # Empty reply, matched to request.
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

  # Sort individual requests in order of path.  The sort is descending order
  # but they are popped off the end of the sequence (for O(1) removal) so are
  # processed in ascending order of path.
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
  # - The left-to-right order is beneficial to the local database writes as well.
  # - If the local database indexes by path, the left-to-right write order will
  #   increase storage density by a lot in a B-tree compared with random order.
  # - If the local database doesn't index by path at all, but does use "rowid"
  #   internally (like SQLite by default), the left-to-right write order will
  #   improve read performance when other peers sync reading this local node.

  proc cmpSingleNodeRequest(x, y: SingleNodeRequest): int =
    # `x` and `y` are deliberately swapped to get descending order.  See above.
    cmp(y.path, x.path)
  sort(fetch.nodeGetQueue, cmpSingleNodeRequest)

  trace "Trie: Sort length", sortLen=i

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
  if traceIndividualNodes:
    trace "> Fetching individual NodeData",
      depth=path.depth, path, hash=($hash), peer=fetch.sp

  let future = newFuture[Blob]()
  fetch.nodeGetQueue.add(SingleNodeRequest(
    hash: hash,
    path: path,
    future: future
  ))
  if not fetch.scheduledBatch:
    fetch.scheduleBatchGetNodeData()
  let nodeBytes = await future

  if tracePackets:
    doAssert nodeBytes.len == 0 or nodeDataHash(nodeBytes) == hash

  if traceIndividualNodes:
    if nodeBytes.len > 0:
      trace "< Received individual NodeData",
        depth=path.depth, path, hash=($hash),
        nodeLen=nodeBytes.len, nodeBytes=nodeBytes.toHex, peer=fetch.sp
    else:
      trace "< Received EMPTY individual NodeData",
        depth=path.depth, path, hash=($hash),
        nodeLen=nodeBytes.len, peer=fetch.sp
  return nodeBytes

import std/strutils
proc updateProgress(fetch: FetchState,
                    path: string = "done", count: int = 0) =
  fetch.progressCount += count
  if fetch.progressPrefix.len == 0 or not path.startsWith(fetch.progressPrefix):
    trace "Sync: State trie leaves progress",
      count=fetch.progressCount, path, peer=fetch.sp
    fetch.progressPrefix = path[0..2]

proc traverse(fetch: FetchState, hash: NodeHash, path: InteriorPath,
              fromExtension: bool) {.async.} =
#  trace "Trie: Fetching node",
#    depth=path.depth, path=path.toHex(true), hash=($hash), peer=sp
  let nodeBytes = await fetch.getNodeData(hash, path)

  var context: TrieNodeParseContext # Default values are fine.
  try:
    fetch.sp.parseTrieNode(path, hash, nodeBytes, fromExtension, context)
  except RlpError as e:
    fetch.sp.parseTrieNodeError(path, hash, nodeBytes, context, e)

  if context.errors > 0:
    debug "Aborting trie traversal due to errors"
    return

  if context.childQueue.len > 0:
    for i in 0 ..< context.childQueue.len:
      let (nodePath, nodeHash, fromExtension) = context.childQueue[i]
      # Here, with `await` results in depth-first traversal and `asyncSpawn`
      # results in breadth-first.  Neither is what we really want.  Depth-first
      # is delayed by a round trip time for every node.  It's far too slow.
      # Pure breadth-first expands to an ever increasing pipeline of requests
      # until it runs out of memory, although network timing means that is
      # unlikely.  That's far too risky.  However the sorting in the request
      # dispatcher left-biases the traversal so that the out of memory
      # condition won't occur.
      asyncSpawn fetch.traverse(nodeHash, nodePath, fromExtension)

  if context.leafQueue.len > 0:
    for i in 0 ..< context.leafQueue.len:
      let (leafPath, nodeHash, leafBytes) = context.leafQueue[i]
      fetch.updateProgress($leafPath, 1)

proc getSlice(sp: SyncPeer, leafRange: var LeafRange): bool =
  const leafMaxFetchRange = (leafHigh - leafLow) div 1000

  if sp.sharedFetch.isNil:
    sp.sharedFetch = SharedFetchState(
      leafRanges: @[LeafRange(leafLow: leafLow, leafHigh: leafHigh)]
    )

  let sharedFetch = sp.sharedFetch
  if sharedFetch.leafRanges.len == 0:
    return false

  leafRange.leafLow = sharedFetch.leafRanges[0].leafLow
  leafRange.leafHigh = sharedFetch.leafRanges[0].leafHigh
  if leafRange.leafHigh - leafRange.leafLow <= leafMaxFetchRange:
    sharedFetch.leafRanges.delete(0)
  else:
    leafRange.leafHigh = leafRange.leafLow + leafMaxFetchRange
    sharedFetch.leafRanges[0].leafHigh = leafRange.leafHigh + 1
  return true

proc probeGetNodeData(sp: SyncPeer, stateRoot: TrieHash): Future[bool] {.async.} =
  # Before doing real trie traversal on this peer, send a probe request for
  # `stateRoot` to see if it's worth pursuing at all.  We will avoid reserving
  # a slice of leafspace, even temporarily, if no traversal will take place.
  #
  # Possible outcomes:
  #
  # - Trie root is returned.  Peers supporting `GetNodeData` do this as long as
  #   `stateRoot` is still in their pruning window, and isn't on a superceded
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
  let reply = await sp.getNodeData(@[stateRoot],
                                   leafLow.toInteriorPath,
                                   leafHigh.toInteriorPath)
  return not reply.isNil and reply.hashVerifiedData.len == 1

proc trieFetch*(sp: SyncPeer) {.async.} =
  let stateRoot = sp.syncStateRoot.get
  trace "Sync: Looking at stateRoot", stateRoot=($stateRoot)
  if sp.fetch.isNil:
    sp.fetch = FetchState(sp: sp)
  asyncSpawn sp.fetch.traverse(stateRoot.NodeHash, rootInteriorPath, false)
