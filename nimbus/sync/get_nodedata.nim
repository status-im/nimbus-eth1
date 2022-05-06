# Nimbus - Robust support for `GetNodeData` network calls
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

## This module provides an async function to call `GetNodeData`, a request in
## the Ethereum DevP2P/ETH network protocol.  Parallel requests can be issued,
## maintaining a pipeline.
##
## Given a list of hashes, it returns a list of trie nodes or contract
## bytecodes matching those hashes.  The returned nodes may be any subset of
## those requested, including an empty list.  The returned nodes are not
## necessarily in the same order as the request, so a mapping from request
## items to node items is included.  On timeout or error, `nil` is returned.
##
## Only data passing hash verification is returned, so hashes don't need to be
## verified again.  No exceptions are raised, and no detail is returned about
## timeouts or errors, but systematically formatted trace messages are output
## if enabled, and show in detail if various events occur such as timeouts,
## bad hashes, mixed replies, network errors, etc.
##
## This tracks queued requests and individual request hashes, verifies received
## node data hashes, and matches them against requests.  When a peer replies in
## same order as requests are sent, and each reply contains nodes in the same
## order as requested, the matching process is efficient.  It avoids storing
## request details in a hash table when possible.  If replies or nodes are out
## of order, the process is still efficient but has to do a little more work.
##
## Empty replies:
##
## Empty replies are matched with requests using a queue draining technique.
## After an empty reply is received, we temporarily pause further requests and
## wait for more replies.  After we receive all outstanding replies, we know
## which requests the empty replies were for, and can complete those requests.
##
## Eth/66 protocol:
##
## Although Eth/66 simplifies by matching replies to requests, replies can still
## have data out of order or missing, so hashes still need to be verified and
## looked up.  Much of the code here is still required for Eth/66.
##
## References:
##
## - [Ethereum Wire Protocol (ETH)](https://github.com/ethereum/devp2p/blob/master/caps/eth.md)
## - [`GetNodeData` (0x0d)](https://github.com/ethereum/devp2p/blob/master/caps/eth.md#getnodedata-0x0d)
## - [`NodeData` (0x0e)](https://github.com/ethereum/devp2p/blob/master/caps/eth.md#nodedata-0x0e)
##
## Note:
##
## This should be made generic for other request types which need similar hash
## matching.  Before this module was written, we tended to accept whatever came
## and assume a lot about replies.  It often worked but wasn't robust enough.

{.push raises: [Defect].}

import
  std/[sequtils, sets, tables, hashes],
  chronos, stint, nimcrypto/keccak,
  eth/[common/eth_types, rlp, p2p],
  "."/[sync_types, protocol_eth65]

type
  NodeDataRequestQueue* = ref object of typeof SyncPeer().nodeDataRequestsBase
    liveRequests*:          HashSet[NodeDataRequest]
    empties*:               int
    # `OrderedSet` was considered instead of `seq` here, but it has a slow
    # implementation of `excl`, defeating the motivation for using it.
    waitingOnEmpties*:      seq[NodeDataRequest]
    beforeFirstHash*:       seq[NodeDataRequest]
    beforeFullHash*:        HashSet[NodeDataRequest]
    # We need to be able to lookup requests by the hash of reply data.
    # `ptr NodeHash` is used here so the table doesn't require an independent
    # copy of the hash.  The hash is part of the request object.
    itemHash*:              Table[ptr NodeHash, (NodeDataRequest, int)]

  NodeDataRequest* = ref object
    sp*:                    SyncPeer
    hashes*:                seq[NodeHash]
    future*:                Future[NodeDataReply]
    timer*:                 TimerCallback
    pathRange*:             (InteriorPath, InteriorPath)
    fullHashed*:            bool

  NodeDataReply* = ref object
    reverseMap:             seq[int]    # Access with `reversMap(i)` instead.
    hashVerifiedData*:      seq[Blob]

template reverseMap*(reply: NodeDataReply, index: int): int =
  ## Given an index into the request hash list, return index into the reply
  ## `hashVerifiedData`, or -1 if there is no data for that request hash.
  if index < reply.reverseMap.len: reply.reverseMap[index] - 1
  elif index < reply.hashVerifiedData.len: index
  else: -1

template nodeDataRequests*(sp: SyncPeer): auto =
  ## Make `sp.nodeDataRequests` available with the real object type.
  sync_types.nodeDataRequestsBase(sp).NodeDataRequestQueue

template nodeDataHash*(data: Blob): NodeHash = keccak256.digest(data).NodeHash

# The trace functions are all inline because we'd rather skip the call when the
# trace facility is turned off.

template pathRange(request: NodeDataRequest): string =
  pathRange(request.pathRange[0], request.pathRange[1])
template `$`*(paths: (InteriorPath, InteriorPath)): string =
  pathRange(paths[0], paths[1])

proc traceGetNodeDataSending(request: NodeDataRequest) {.inline.} =
  tracePacket ">> Sending eth.GetNodeData (0x0d)",
    hashCount=request.hashes.len,
    pathRange=request.pathRange, peer=request.sp

proc traceGetNodeDataDelaying(request: NodeDataRequest) {.inline.} =
  tracePacket ">> Delaying eth.GetNodeData (0x0d)",
    hashCount=request.hashes.len,
    pathRange=request.pathRange, peer=request.sp

proc traceGetNodeDataSendError(request: NodeDataRequest,
                               e: ref CatchableError) {.inline.} =
  traceNetworkError ">> Error sending eth.GetNodeData (0x0d)",
    error=e.msg, hashCount=request.hashes.len,
    pathRange=request.pathRange, peer=request.sp

proc traceNodeDataReplyError(request: NodeDataRequest,
                             e: ref CatchableError) {.inline.} =
  traceNetworkError "<< Error waiting for reply to eth.GetNodeData (0x0d)",
    error=e.msg, hashCount=request.hashes.len,
    pathRange=request.pathRange, peer=request.sp

proc traceNodeDataReplyTimeout(request: NodeDataRequest) {.inline.} =
  traceTimeout "<< Timeout waiting for reply to eth.GetNodeData (0x0d)",
    hashCount=request.hashes.len,
    pathRange=request.pathRange, peer=request.sp

proc traceNodeDataReplyEmpty(sp: SyncPeer, request: NodeDataRequest) {.inline.} =
  # `request` can be `nil` because we don't always know which request
  # the empty reply goes with.  Therefore `sp` must be included.
  if request.isNil:
    tracePacket "<< Got EMPTY eth.NodeData (0x0e)",
      got=0, peer=sp
  else:
    tracePacket "<< Got eth.NodeData (0x0e)",
      got=0, requested=request.hashes.len,
      pathRange=request.pathRange, peer=sp

proc traceNodeDataReplyUnmatched(sp: SyncPeer, got: int) {.inline.} =
  # There is no request for this reply.  Therefore `sp` must be included.
  tracePacketError "<< Protocol violation, non-reply eth.NodeData (0x0e)",
    got, peer=sp
  debug "Sync: Warning: Unexpected non-reply eth.NodeData from peer", peer=sp

proc traceNodeDataReply(request: NodeDataRequest,
                        got, use, unmatched, other, duplicates: int) {.inline.} =
  if tracePackets:
    logScope: got=got
    logScope: requested=request.hashes.len
    logScope: pathRange=request.pathRange
    logScope: peer=request.sp
    if got > request.hashes.len and (unmatched + other) == 0:
      tracePacket "<< Got EXCESS reply eth.NodeData (0x0e)"
    elif got == request.hashes.len or use != got:
      tracePacket "<< Got reply eth.NodeData (0x0e)"
    elif got < request.hashes.len:
      tracePacket "<< Got TRUNCATED reply eth.NodeData (0x0e)"

  if use != got:
    logScope:
      discarding=(got - use)
      keeping=use
      got=got
      requested=request.hashes.len
      pathRange=request.pathRange
      peer=request.sp
    if unmatched > 0:
      tracePacketError "<< Protocol violation, incorrect hashes in eth.NodeData (0x0e)"
      debug "Sync: Warning: eth.NodeData has nodes with incorrect hashes"
    elif other > 0:
      tracePacketError "<< Protocol violation, mixed request nodes in eth.NodeData (0x0e)"
      debug "Sync: Warning: eth.NodeData has nodes from mixed requests"
    elif got > request.hashes.len:
      # Excess without unmatched/other is only possible with duplicates > 0.
      tracePacketError "<< Protocol violation, excess nodes in eth.NodeData (0x0e)"
      debug "Sync: Warning: eth.NodeData has more nodes than requested"
    else:
      tracePacketError "<< Protocol violation, duplicate nodes in eth.NodeData (0x0e)"
      debug "Sync: Warning: eth.NodeData has duplicate nodes"

proc hash(hash: ptr Hash256): Hash         = cast[ptr Hash](addr hash.data)[]
proc `==`(hash1, hash2: ptr Hash256): bool = hash1[] == hash2[]
proc hash(request: NodeDataRequest): Hash  = hash(cast[pointer](request))

proc nodeDataMatchRequest(rq: NodeDataRequestQueue, data: openArray[Blob],
                          reverseMap: var seq[int],
                          use, unmatched, other, duplicates: var int
                         ): NodeDataRequest =
  ## Verify hashes in the received node data and use them to find the matching
  ## request, and match individual nodes to indices in the request in case they
  ## are out of order, which is allowed.  Note, even if we know which request,
  ## (`eth/66`), we have to hash and match the indices anyway.
  ##
  ## The matched request is returned or `nil` if no match.
  ## `reverseMap` is updated, and it should be empty initially.
  ## The caller is responsible for applying `reverseMap` to the data.
  ##
  ## `use`, `unmatched`, `other` or `duplicates` are incremented for each node.
  ## If the last three happen, the reply has errors, but the caller can decide
  ## what to do.  Non-nil `request` may still be returned with those errors.
  var request: NodeDataRequest = nil

  # Iterate through reply data, hashing and efficiently finding what matches.
  for i in 0 ..< data.len:
    var itemRequest: NodeDataRequest
    var index = 0
    let hash = nodeDataHash(data[i])
    if i == 0:
      # Efficiently guess the request belongs to the oldest queued request and
      # the items are in requested order.  This lets us skip storing any item
      # hashes in the global item hash table.  `beforeFirstHash` is ordered to
      # make sure we always find the oldest queued request first.
      var j = 0
      while j < rq.beforeFirstHash.len:
        let hashRequest = rq.beforeFirstHash[j]
        if hashRequest.hashes[0] == hash:
          itemRequest = hashRequest
          break
        # Efficiently scan other requests, hashing the first item in each to
        # speed up future scans.  This lets us avoid storing all item hashes
        # in the global request table when replies have items in requested
        # order, even though replies themselves are out of order.
        if j == 0:
          (itemRequest, index) = rq.itemHash.getOrDefault(unsafeAddr hash)
          if not itemRequest.isNil:
            break
        rq.itemHash[addr hashRequest.hashes[0]] = (hashRequest, 0)
        rq.beforeFullHash.incl(hashRequest)
        inc j
      if j > 0:
        rq.beforeFirstHash.delete(0, j-1)
    elif not request.isNil:
      # Efficiently guess the items are in requested order.  This avoids
      # having to store individual item hashes in the global request table.
      if i < request.hashes.len and request.hashes[i] == hash:
        (itemRequest, index) = (request, i)

    # If hash-store avoiding heuristics didn't work, a full lookup is required.
    # If this succeeds, the reply must have items out of requested order.
    # If it fails, a peer sent a bad reply.
    if itemRequest.isNil:
      (itemRequest, index) = rq.itemHash.getOrDefault(unsafeAddr hash)
      if itemRequest.isNil:
        # Hash and search items in the current request first, if there is one.
        if not request.isNil and not request.fullHashed:
          request.fullHashed = true
          for j in 0 ..< request.hashes.len:
            rq.itemHash[addr request.hashes[j]] = (request, j)
          (itemRequest, index) =
            rq.itemHash.getOrDefault(unsafeAddr hash)
        if itemRequest.isNil:
          # Hash and search all items across all requests.
          if rq.beforeFirstHash.len + rq.beforeFullHash.len > 0:
            if rq.beforeFullHash.len > 0:
              rq.beforeFirstHash.add(rq.beforeFullHash.toSeq)
              rq.beforeFullHash.clear()
            for hashRequest in rq.beforeFirstHash:
              if not hashRequest.fullHashed:
                hashRequest.fullHashed = true
                for j in 0 ..< hashRequest.hashes.len:
                  rq.itemHash[addr hashRequest.hashes[j]] = (hashRequest, j)
            rq.beforeFirstHash.setLen(0)
            (itemRequest, index) = rq.itemHash.getOrDefault(unsafeAddr hash)
          if itemRequest.isNil:
            # Not found anywhere.
            inc unmatched
            continue

    # Matched now in `itemRequest`.  But is it the same request as before?
    if not request.isNil and itemRequest != request:
      inc other
      continue
    request = itemRequest

    # Matched now in `request`.  Is item in order?  Is it a duplicate?
    # Build `reverseMap` but efficiently skip doing so if items are in order.
    if index == i and reverseMap.len == 0:
      inc use
    else:
      if reverseMap.len == 0:
        newSeq[int](reverseMap, request.hashes.len)
        for j in 0 ..< i:
          reverseMap[j] = j
      if reverseMap[index] > 0:
        inc duplicates
        continue
      reverseMap[index] = i + 1
      inc use

  return request

proc nodeDataRequestEnqueue(rq: NodeDataRequestQueue,
                            request: NodeDataRequest) {.inline.} =
  ## Add `request` to the data structures in `rq: NodeDataRequest`.
  doAssert not rq.liveRequests.containsOrIncl(request)
  rq.beforeFirstHash.add(request)

proc nodeDataRequestDequeue(rq: NodeDataRequestQueue,
                            request: NodeDataRequest) {.inline.} =
  ## Remove `request` from the data structures in `rq: NodeDataRequest`.
  doAssert not rq.liveRequests.missingOrExcl(request)
  let index = rq.beforeFirstHash.find(request)
  if index >= 0:
    rq.beforeFirstHash.delete(index)
  rq.beforeFullHash.excl(request)
  for j in 0 ..< (if request.fullHashed: request.hashes.len else: 1):
    rq.itemHash.del(addr request.hashes[j])

# Forward declarations.
proc nodeDataTryEmpties(rq: NodeDataRequestQueue)
proc nodeDataEnqueueAndSend(request: NodeDataRequest) {.async.}

proc nodeDataComplete(request: NodeDataRequest, reply: NodeDataReply) =
  ## Complete `request` with received data or other reply.
  if request.future.finished:
    # Subtle: Timer can trigger and its callback be added to Chronos run loop,
    # then data event trigger and call `clearTimer()`.  The timer callback
    # will then run but it must be ignored.
    debug "Sync: Warning: Resolved timer race over eth.NodeData reply"
  else:
    request.timer.clearTimer()
    request.future.complete(reply)
    let rq = request.sp.nodeDataRequests
    rq.nodeDataRequestDequeue(request)
    # It may now be possible to match empty replies to earlier requests.
    rq.nodeDataTryEmpties()

proc nodeDataTimeout(arg: pointer) =
  ## Complete `request` with timeout.  (`arg` because it's a Chronos timer.)
  let request = cast[NodeDataRequest](arg)
  request.traceNodeDataReplyTimeout()
  {.gcsafe.}: request.nodeDataComplete(nil)

proc nodeDataTryEmpties(rq: NodeDataRequestQueue) =
  ## See if we can match queued empty replies to earlier requests.
  # TODO: This approach doesn't handle timeouts and errors correctly.
  # The problem is it's ambiguous whether an empty reply after timed out
  # request was intended by the peer for that request.
  if rq.empties > 0 and rq.empties >= rq.liveRequests.len:
    rq.empties = 0
    # Complete all live requests with empty results, now we know.
    while rq.liveRequests.len > 0:
      template popSilenceRaises[T](s: HashSet[ref T]): ref T =
        try: s.pop() except KeyError as e: raise newException(Defect, e.msg)
      let request = rq.liveRequests.popSilenceRaises()
      # Construct reply object, because empty is different from timeout.
      request.nodeDataComplete(NodeDataReply())
    # Move all temporarily delayed requests to the live state, and send them.
    var tmpList: seq[NodeDataRequest]
    swap(tmpList, rq.waitingOnEmpties)
    for i in 0 ..< tmpList.len:
      asyncSpawn nodeDataEnqueueAndSend(tmpList[i])

proc nodeDataNewRequest(sp: SyncPeer, hashes: seq[NodeHash],
                        pathFrom, pathTo: InteriorPath
                       ): NodeDataRequest {.inline.} =
  ## Make a new `NodeDataRequest` to receive a reply or timeout in future.  The
  ## caller is responsible for sending the `GetNodeData` request, and must do
  ## that after this setup (not before) to avoid race conditions.
  let request = NodeDataRequest(sp: sp, hashes: hashes,
                                pathRange: (pathFrom, pathTo))
  # TODO: Cache the time when making batches of requests, instead of calling
  # `Moment.fromNow()` which always does a system call.  `p2pProtocol` request
  # timeouts have the same issue (and is where we got 10 seconds default).
  request.timer = setTimer(Moment.fromNow(10.seconds),
                           nodeDataTimeout, cast[pointer](request))
  request.future = newFuture[NodeDataReply]()
  return request

proc nodeDataEnqueueAndSend(request: NodeDataRequest) {.async.} =
  ## Helper function to send an `eth.GetNodeData` request.
  ## But not when we're draining the in flight queue to match empty replies.
  let rq = request.sp.nodeDataRequests
  let sp = request.sp
  if rq.empties > 0:
    request.traceGetNodeDataDelaying()
    rq.waitingOnEmpties.add(request)
    return

  request.traceGetNodeDataSending()
  rq.nodeDataRequestEnqueue(request)
  inc sp.stats.ok.getNodeData
  try:
    # TODO: What exactly does this `await` do, wait for space in send buffer?
    # TODO: Check if this copies the hashes redundantly.
    await sp.peer.getNodeData(request.hashes)
  except CatchableError as e:
    request.traceGetNodeDataSendError(e)
    inc sp.stats.major.networkErrors
    sp.stopped = true
    request.future.fail(e)

proc onNodeData(sp: SyncPeer, data: openArray[Blob]) {.inline.} =
  ## Handle an incoming `eth.NodeData` reply.
  ## Practically, this is also where all the incoming packet trace messages go.
  let rq = sp.nodeDataRequests

  # Empty replies are meaningful, but we can only associate them with requests
  # when there are enough empty replies to cover all outstanding requests.  If
  # not, queue the empty reply and block further requests.  Existing other
  # requests in flight can still receive data.
  if data.len == 0:
    # If there are no requests, don't queue, just let processing fall
    # through until the "non-reply" protocol violation error.
    if rq.liveRequests.len > 0:
      sp.traceNodeDataReplyEmpty(if rq.liveRequests.len != 1: nil
                                 else: rq.liveRequests.toSeq[0])
      inc rq.empties
      # It may now be possible to match empty replies to earlier requests.
      rq.nodeDataTryEmpties()
      return

  let reply = NodeDataReply()
  var (use, unmatched, other, duplicates) = (0, 0, 0, 0)
  let request = nodeDataMatchRequest(rq, data, reply.reverseMap,
                                     use, unmatched, other, duplicates)

  if request.isNil:
    sp.traceNodeDataReplyUnmatched(data.len)
    return

  request.traceNodeDataReply(data.len, use, unmatched, other, duplicates)

  # TODO: Speed improvement possible here.
  if reply.reverseMap.len == 0:
    reply.hashVerifiedData = if use == data.len: @data
                             else: @data[0 .. (use-1)]
  else:
    reply.hashVerifiedData = newSeqOfCap[Blob](use)
    var j = 0
    for i in 0 ..< request.hashes.len:
      let index = reply.reverseMap[i] - 1
      if index >= 0:
        reply.hashVerifiedData.add(data[index])
        reply.reverseMap[i] = j + 1
        inc j

  doAssert reply.hashVerifiedData.len == use
  request.nodeDataComplete(reply)

proc getNodeData*(sp: SyncPeer, hashes: seq[NodeHash],
                  pathFrom, pathTo: InteriorPath): Future[NodeDataReply] {.async.} =
  ## Async function to send a `GetNodeData` request to a peer, and when the
  ## peer replies, or on timeout or error, return `NodeDataReply`.
  ##
  ## The request is a list of hashes.  The reply is a list of trie nodes or
  ## contract bytecodes matching those hashes, not necessarily in the same
  ## order as the request.  The returned list may be any subset of the
  ## requested nodes, including an empty list.  On timeout or error `nil` is
  ## returned.  Use `reply.reverseMap(i)` to map request items to reply data.
  ##
  ## Only data passing hash verification is returned, so hashes don't need to
  ## be verified again.  No exceptions are raised, and no detail is returned
  ## about timeouts or errors.
  ##
  ## `pathFrom` and `pathTo` are not used except for logging.

  let request = sp.nodeDataNewRequest(hashes, pathFrom, pathTo)
  # There is no "Sending..." trace message here, because it can be delayed
  # by the empty reply logic in `nodeDataEnqueueAndSend`.
  var reply: NodeDataReply = nil
  try:
    await request.nodeDataEnqueueAndSend()
    reply = await request.future
  except CatchableError as e:
    request.traceNodeDataReplyError(e)
    inc sp.stats.major.networkErrors
    sp.stopped = true
    return nil
  # Timeout, packet and packet error trace messages are done in `onNodeData`
  # and `nodeDataTimeout`, where there is more context than here.  Here we
  # always received just valid data with hashes already verified, or `nil`.
  return reply

proc setupGetNodeData*(sp: SyncPeer) =
  ## Initialise `SyncPeer` to support `getNodeData` calls.

  if sp.nodeDataRequests.isNil:
    sp.nodeDataRequests = NodeDataRequestQueue()

  sp.peer.state(eth).onNodeData =
    proc (_: Peer, data: openArray[Blob]) =
      {.gcsafe.}: onNodeData(sp, data)

  sp.peer.state(eth).onGetNodeData =
    proc (_: Peer, hashes: openArray[NodeHash], data: var seq[Blob]) =
      # Return empty nodes result.  This callback is installed to
      # ensure we don't reply with nodes from the chainDb.
      discard
