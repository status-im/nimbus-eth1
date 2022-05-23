# Nimbus - Robust support for `GetNodeData` network calls
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

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
## - `Ethereum Wire Protocol (ETH)
##    <https://github.com/ethereum/devp2p/blob/master/caps/eth.md>`_
## - `GetNodeData (0x0d)
##    <https://github.com/ethereum/devp2p/blob/master/caps/eth.md#getnodedata-0x0d>`_
## - `NodeData (0x0e)
##    <https://github.com/ethereum/devp2p/blob/master/caps/eth.md#nodedata-0x0e>`_
##
## Note:
##
## This should be made generic for other request types which need similar hash
## matching.  Before this module was written, we tended to accept whatever came
## and assume a lot about replies.  It often worked but wasn't robust enough.

import
  std/[sequtils, sets, tables, hashes],
  chronos,
  eth/[common/eth_types, p2p],
  "../.."/[protocol, protocol/trace_config, types],
  ../path_desc,
  "."/[timer_helper, worker_desc]

{.push raises: [Defect].}

logScope:
  topics = "snap reply"

type
  ReplyData* = ref object
    ## Opaque object handle for reply message
    reverseMap:         seq[int] ## for reading out the `hashVerifiedData[]`
    hashVerifiedData:   seq[Blob]

  ReplyDataType* = enum
    NoReplyData
    SingleEntryReply
    MultipleEntriesReply

  RequestData = ref object
    sp:                 WorkerBuddy
    hashes:             seq[NodeHash]
    future:             Future[ReplyData]
    timer:              TimerCallback
    pathRange:          (InteriorPath, InteriorPath)
    fullHashed:         bool

  RequestDataQueue = ref object of WorkerBuddyRequestsBase
    liveRequests:       HashSet[RequestData]
    empties:            int
    # `OrderedSet` was considered instead of `seq` here, but it has a slow
    # implementation of `excl`, defeating the motivation for using it.
    waitingOnEmpties:   seq[RequestData]
    beforeFirstHash:    seq[RequestData]
    beforeFullHash:     HashSet[RequestData]
    # We need to be able to lookup requests by the hash of reply data.
    # `ptr NodeHash` is used here so the table doesn't require an independent
    # copy of the hash.  The hash is part of the request object.
    itemHash:           Table[ptr NodeHash, (RequestData,int)]

proc hash(request: RequestData): Hash =
  hash(cast[pointer](request))

proc hash(hash: ptr Hash256): Hash =
  cast[ptr Hash](addr hash.data)[]

proc `==`(hash1, hash2: ptr Hash256): bool =
  hash1[] == hash2[]

proc requestsEx(sp: WorkerBuddy): RequestDataQueue =
  sp.requests.RequestDataQueue

proc `requestsEx=`(sp: WorkerBuddy; value: RequestDataQueue) =
  sp.requests = value

# ------------------------------------------------------------------------------
# Private logging helpers
# ------------------------------------------------------------------------------

template pathRange(request: RequestData): string =
  pathRange(request.pathRange[0], request.pathRange[1])

proc traceGetNodeDataSending(request: RequestData) =
  trace trEthSendSending & "GetNodeData", peer=request.sp,
    hashes=request.hashes.len, pathRange=request.pathRange

proc traceGetNodeDataDelaying(request: RequestData) =
  trace trEthSendDelaying & "GetNodeData",  peer=request.sp,
    hashes=request.hashes.len, pathRange=request.pathRange

proc traceGetNodeDataSendError(request: RequestData,
                               e: ref CatchableError) =
  trace trEthRecvError & "sending GetNodeData", peer=request.sp,
    error=e.msg, hashes=request.hashes.len, pathRange=request.pathRange

proc traceReplyDataError(request: RequestData,
                             e: ref CatchableError) =
  trace trEthRecvError & "waiting for reply to GetNodeData",
    peer=request.sp, error=e.msg,
    hashes=request.hashes.len, pathRange=request.pathRange

proc traceReplyDataTimeout(request: RequestData) =
  trace trEthRecvTimeoutWaiting & "for reply to GetNodeData",
    hashes=request.hashes.len, pathRange=request.pathRange, peer=request.sp

proc traceGetNodeDataDisconnected(request: RequestData) =
  trace trEthRecvError & "peer disconnected, not sending GetNodeData",
    peer=request.sp, hashes=request.hashes.len, pathRange=request.pathRange

proc traceReplyDataEmpty(sp: WorkerBuddy, request: RequestData) =
  # `request` can be `nil` because we don't always know which request
  # the empty reply goes with.  Therefore `sp` must be included.
  if request.isNil:
    trace trEthRecvGot & "EMPTY NodeData", peer=sp, got=0
  else:
    trace trEthRecvGot & "NodeData", peer=sp, got=0,
      requested=request.hashes.len, pathRange=request.pathRange

proc traceReplyDataUnmatched(sp: WorkerBuddy, got: int) =
  # There is no request for this reply.  Therefore `sp` must be included.
  trace trEthRecvProtocolViolation & "non-reply NodeData", peer=sp, got
  debug "Warning: Unexpected non-reply NodeData from peer"

proc traceReplyData(request: RequestData,
                        got, use, unmatched, other, duplicates: int) =
  when trEthTracePacketsOk:
    logScope: got=got
    logScope: requested=request.hashes.len
    logScope: pathRange=request.pathRange
    logScope: peer=request.sp
    if got > request.hashes.len and (unmatched + other) == 0:
      trace trEthRecvGot & "EXCESS reply NodeData"
    elif got == request.hashes.len or use != got:
      trace trEthRecvGot & "reply NodeData"
    elif got < request.hashes.len:
      trace trEthRecvGot & "TRUNCATED reply NodeData"

  if use != got:
    logScope:
      discarding=(got - use)
      keeping=use
      got=got
      requested=request.hashes.len
      pathRange=request.pathRange
      peer=request.sp
    if unmatched > 0:
      trace trEthRecvProtocolViolation & "incorrect hashes in NodeData"
      debug "Warning: NodeData has nodes with incorrect hashes"
    elif other > 0:
      trace trEthRecvProtocolViolation & "mixed request nodes in NodeData"
      debug "Warning: NodeData has nodes from mixed requests"
    elif got > request.hashes.len:
      # Excess without unmatched/other is only possible with duplicates > 0.
      trace trEthRecvProtocolViolation & "excess nodes in NodeData"
      debug "Warning: NodeData has more nodes than requested"
    else:
      trace trEthRecvProtocolViolation & "duplicate nodes in NodeData"
      debug "Warning: NodeData has duplicate nodes"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc nodeDataMatchRequest(
    rq: RequestDataQueue,
    data: openArray[Blob],
    reverseMap: var seq[int],
    use, unmatched, other, duplicates: var int
     ): RequestData =
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
  var request: RequestData = nil

  # Iterate through reply data, hashing and efficiently finding what matches.
  for i in 0 ..< data.len:
    var itemRequest: RequestData
    var index = 0
    let hash = data[i].toNodeHash
    if i == 0:
      # Efficiently guess the request belongs to the oldest queued request and
      # the items are in requested order.  This lets us skip storing any item
      # hashes in the global item hash table.  `beforeFirstHash` is ordered to
      # make sure we always find the oldest queued request first.
      var j = 0
      while j < rq.beforeFirstHash.len:
        let hashRequest = rq.beforeFirstHash[j].RequestData
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

proc nodeDataRequestEnqueue(rq: RequestDataQueue,
                            request: RequestData) =
  ## Add `request` to the data structures in `rq: RequestData`.
  doAssert not rq.liveRequests.containsOrIncl(request)
  rq.beforeFirstHash.add(request)

proc nodeDataRequestDequeue(rq: RequestDataQueue,
                            request: RequestData) =
  ## Remove `request` from the data structures in `rq: RequestData`.
  doAssert not rq.liveRequests.missingOrExcl(request)
  let index = rq.beforeFirstHash.find(request)
  if index >= 0:
    rq.beforeFirstHash.delete(index)
  rq.beforeFullHash.excl(request)
  for j in 0 ..< (if request.fullHashed: request.hashes.len else: 1):
    rq.itemHash.del(addr request.hashes[j])

# Forward declarations.
proc nodeDataTryEmpties(rq: RequestDataQueue)
proc nodeDataEnqueueAndSend(request: RequestData) {.async.}

proc nodeDataComplete(request: RequestData, reply: ReplyData,
                      insideTryEmpties = false) =
  ## Complete `request` with received data or other reply.
  if request.future.finished:
    # Subtle: Timer can trigger and its callback be added to Chronos run loop,
    # then data event trigger and call `clearTimer()`.  The timer callback
    # will then run but it must be ignored.
    debug "Warning: Resolved timer race over NodeData reply"
  else:
    request.timer.clearTimer()
    request.future.complete(reply)
    let rq = request.sp.requestsEx
    trace "nodeDataRequestDequeue", addr=cast[pointer](request).repr
    rq.nodeDataRequestDequeue(request)
    # It may now be possible to match empty replies to earlier requests.
    if not insideTryEmpties:
      rq.nodeDataTryEmpties()

proc nodeDataTimeout(request: RequestData) =
  ## Complete `request` with timeout.
  request.traceReplyDataTimeout()
  {.gcsafe.}: request.nodeDataComplete(nil)

proc nodeDataTryEmpties(rq: RequestDataQueue) =
  ## See if we can match queued empty replies to earlier requests.
  # TODO: This approach doesn't handle timeouts and errors correctly.
  # The problem is it's ambiguous whether an empty reply after timed out
  # request was intended by the peer for that request.
  if rq.empties > 0 and rq.empties >= rq.liveRequests.len:
    # Complete all live requests with empty results, now they are all matched.
    if rq.liveRequests.len > 0:
      # Careful: Use `.toSeq` below because we must not use the `HashSet`
      # iterator while the set is being changed.
      for request in rq.liveRequests.toSeq:
        # Constructed reply object, because empty is different from timeout.
        request.nodeDataComplete(ReplyData(), true)
    # Move all temporarily delayed requests to the live state, and send them.
    if rq.waitingOnEmpties.len > 0:
      var tmpList: seq[RequestData]
      swap(tmpList, rq.waitingOnEmpties)
      for i in 0 ..< tmpList.len:
        asyncSpawn nodeDataEnqueueAndSend(tmpList[i])

proc new(
    T: type RequestData,
    sp: WorkerBuddy,
    hashes: seq[NodeHash],
    pathFrom, pathTo: InteriorPath
     ): RequestData  =
  ## Make a new `RequestData` to receive a reply or timeout in future.  The
  ## caller is responsible for sending the `GetNodeData` request, and must do
  ## that after this setup (not before) to avoid race conditions.
  let request = RequestData(sp: sp, hashes: hashes,
                                pathRange: (pathFrom, pathTo))
  # TODO: Cache the time when making batches of requests, instead of calling
  # `Moment.fromNow()` which always does a system call.  `p2pProtocol` request
  # timeouts have the same issue (and is where we got 10 seconds default).
  #  request.timer = setTimer(Moment.fromNow(10.seconds),
  #                           nodeDataTimeout, cast[pointer](request))
  request.timer = safeSetTimer(Moment.fromNow(10.seconds),
                               nodeDataTimeout, request)
  request.future = newFuture[ReplyData]()
  return request

proc nodeDataEnqueueAndSend(request: RequestData) {.async.} =
  ## Helper function to send an `eth.GetNodeData` request.
  ## But not when we're draining the in flight queue to match empty replies.
  let sp = request.sp
  if sp.ctrl.runState == BuddyStopped:
    request.traceGetNodeDataDisconnected()
    request.future.complete(nil)
    return
  let rq = sp.requestsEx
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
    await sp.peer.getNodeData(request.hashes.untie)
  except CatchableError as e:
    request.traceGetNodeDataSendError(e)
    inc sp.stats.major.networkErrors
    sp.ctrl.runState = BuddyStopped
    request.future.fail(e)

proc onNodeData(sp: WorkerBuddy, data: openArray[Blob]) =
  ## Handle an incoming `eth.NodeData` reply.
  ## Practically, this is also where all the incoming packet trace messages go.
  let rq = sp.requestsEx

  # Empty replies are meaningful, but we can only associate them with requests
  # when there are enough empty replies to cover all outstanding requests.  If
  # not, queue the empty reply and block further requests.  Existing other
  # requests in flight can still receive data.
  if data.len == 0:
    # If there are no requests, don't queue, just let processing fall
    # through until the "non-reply" protocol violation error.
    if rq.liveRequests.len > 0:
      sp.traceReplyDataEmpty(if rq.liveRequests.len != 1: nil
                                 else: rq.liveRequests.toSeq[0])
      inc rq.empties
      # It may now be possible to match empty replies to earlier requests.
      rq.nodeDataTryEmpties()
      return

  let reply = ReplyData()
  var (use, unmatched, other, duplicates) = (0, 0, 0, 0)
  let request = nodeDataMatchRequest(rq, data, reply.reverseMap,
                                     use, unmatched, other, duplicates)

  if request.isNil:
    sp.traceReplyDataUnmatched(data.len)
    return

  request.traceReplyData(data.len, use, unmatched, other, duplicates)

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

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc new*(
    T: type ReplyData,
    sp: WorkerBuddy,
    hashes: seq[NodeHash],
    pathFrom = InteriorPath(),
    pathTo = InteriorPath()
      ): Future[T] {.async.} =
  ## Async function to send a `GetNodeData` request to a peer, and when the
  ## peer replies, or on timeout or error, return `ReplyData`.
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

  let request = RequestData.new(sp, hashes, pathFrom, pathTo)
  # There is no "Sending..." trace message here, because it can be delayed
  # by the empty reply logic in `nodeDataEnqueueAndSend`.
  var reply: ReplyData = nil
  try:
    await request.nodeDataEnqueueAndSend()
    reply = await request.future
  except CatchableError as e:
    request.traceReplyDataError(e)
    inc sp.stats.major.networkErrors
    sp.ctrl.runState = BuddyStopped
    return nil

  # Timeout, packet and packet error trace messages are done in `onNodeData`
  # and `nodeDataTimeout`, where there is more context than here.  Here we
  # always received just valid data with hashes already verified, or `nil`.
  return reply

proc replyType*(reply: ReplyData): ReplyDataType =
  ## Fancy interface for evaluating the reply lengths for none, 1, or many.
  ## If the `reply` argument is `nil`, the result `NoReplyData` is returned
  ## which is the same as for zero lengths reply.
  if reply.isNil or reply.hashVerifiedData.len == 0:
    NoReplyData
  elif reply.hashVerifiedData.len == 1:
    SingleEntryReply
  else:
    MultipleEntriesReply

proc `[]`*(reply: ReplyData; inx: int): Blob =
  ## Returns the reverse indexed item from the reply cache (if any). If
  ## `reply` is `nil` or `inx` is out of bounds, an empty `Blob` (i.e. `@[]`)
  ## is returned.
  ##
  ## Note that the length of the `reply` list is limited by the `new()`
  ## contructor argument `hashes`. So there is no `len` directive used.
  if 0 <= inx:
    if inx < reply.reverseMap.len:
      let xni = reply.reverseMap[inx] - 1
      if 0 <= xni:
        return reply.hashVerifiedData[xni]
    if inx < reply.hashVerifiedData.len:
      return reply.hashVerifiedData[inx]

proc replyDataSetup*(sp: WorkerBuddy) =
  ## Initialise `WorkerBuddy` to support `NodeData` replies to `GetNodeData`
  ## requests issued by `new()`.

  if sp.requestsEx.isNil:
    sp.requestsEx = RequestDataQueue()

  sp.peer.state(eth).onNodeData =
    proc (_: Peer, data: openArray[Blob]) =
      {.gcsafe.}: onNodeData(sp, data)

  sp.peer.state(eth).onGetNodeData =
    proc (_: Peer, hashes: openArray[Hash256], data: var seq[Blob]) =
      ## Return empty nodes result.  This callback is installed to
      ## ensure we don't reply with nodes from the chainDb.
      discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
