# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.

{.used.}

import
  std/[heapqueue, sequtils, tables],
  unittest2,
  chronos,
  ../../execution_chain/networking/protocol_dsl {.all.}

type Response = ref object
  payload: seq[byte]

proc newPeer(messageCount = 1): Peer =
  result = Peer(
    dispatcher: Dispatcher(messages: newSeq[MessageInfo](messageCount)),
    perMsgId: newSeq[PerMsgId](messageCount),
  )
  for message in result.dispatcher.messages.mitems:
    message = MessageInfo(requestResolver: requestResolver[Response])

suite "RLPx request lifetime":
  test "successful response clears its timeout callback":
    let peer = newPeer()
    let future = newFuture[Opt[Response]]()
    let timersBefore = toSeq(getThreadDispatcher().timers.items)
    let id = peer.registerRequest(50.seconds, future, 0)
    var requestTimer: TimerCallback
    for timer in getThreadDispatcher().timers.items:
      if timer notin timersBefore:
        requestTimer = timer
    require requestTimer != nil
    check not requestTimer.function.function.isNil

    var response = Response(payload: newSeq[byte](1024 * 1024))
    peer.resolveResponseFuture(0, addr response, id)
    # Check the retaining reference directly; refc finalization is conservative.
    waitFor sleepAsync(1.milliseconds)
    check:
      future.completed
      future.read().get() == response
      peer.perMsgId[0].outstandingRequest.len == 0
      requestTimer.function.function.isNil

  test "timeout removes the outstanding request":
    let peer = newPeer()
    let future = newFuture[Opt[Response]]()
    discard peer.registerRequest(0.milliseconds, future, 0)
    check (waitFor future).isNone
    waitFor sleepAsync(1.milliseconds)
    check peer.perMsgId[0].outstandingRequest.len == 0

  test "send failure removes the outstanding request":
    let peer = newPeer()
    let future = newFuture[Opt[Response]]()
    let sendFuture = newFuture[void]()
    discard peer.registerRequest(50.seconds, future, 0)
    linkSendFailureToReqFuture(sendFuture, future)
    sendFuture.fail(newException(IOError, "send failed"))
    waitFor sleepAsync(1.milliseconds)
    check:
      future.failed
      peer.perMsgId[0].outstandingRequest.len == 0

  test "cancelling a request leaves other requests pending":
    let peer = newPeer()
    let first = newFuture[Opt[Response]]()
    let middle = newFuture[Opt[Response]]()
    let last = newFuture[Opt[Response]]()
    let firstId = peer.registerRequest(50.seconds, first, 0)
    discard peer.registerRequest(50.seconds, middle, 0)
    let lastId = peer.registerRequest(50.seconds, last, 0)
    waitFor middle.cancelAndWait()
    waitFor sleepAsync(1.milliseconds)
    check:
      middle.cancelled
      peer.perMsgId[0].outstandingRequest.len == 2
      peer.perMsgId[0].outstandingRequest.getOrDefault(firstId) == first
      peer.perMsgId[0].outstandingRequest.getOrDefault(lastId) == last
      not first.finished
      not last.finished
    waitFor first.cancelAndWait()
    waitFor last.cancelAndWait()
    waitFor sleepAsync(1.milliseconds)
    check peer.perMsgId[0].outstandingRequest.len == 0

  test "disconnect cleanup can remove requests before completion callbacks":
    let peer = newPeer()
    let future = newFuture[Opt[Response]]()
    discard peer.registerRequest(50.seconds, future, 0)
    let pending = move(peer.perMsgId[0].outstandingRequest)
    for request in pending.values:
      peer.dispatcher.messages[0].requestResolver(nil, request)
    waitFor sleepAsync(1.milliseconds)
    check:
      future.completed
      future.read().isNone
      peer.perMsgId[0].outstandingRequest.len == 0

  test "late and duplicate replies leave other requests pending":
    let peer = newPeer()
    let expired = newFuture[Opt[Response]]()
    let pending = newFuture[Opt[Response]]()
    let expiredId = peer.registerRequest(0.milliseconds, expired, 0)
    let pendingId = peer.registerRequest(50.seconds, pending, 0)
    check (waitFor expired).isNone
    waitFor sleepAsync(1.milliseconds)

    var response = Response(payload: @[1.byte])
    peer.resolveResponseFuture(0, addr response, expiredId)
    check not pending.finished
    peer.resolveResponseFuture(0, addr response, pendingId)
    peer.resolveResponseFuture(0, addr response, pendingId)
    waitFor sleepAsync(1.milliseconds)
    check:
      pending.completed
      pending.read().get().payload == @[1.byte]
      peer.perMsgId[0].outstandingRequest.len == 0

  test "out of order replies resolve the matching requests":
    let peer = newPeer()
    let first = newFuture[Opt[Response]]()
    let second = newFuture[Opt[Response]]()
    let firstId = peer.registerRequest(50.seconds, first, 0)
    let secondId = peer.registerRequest(50.seconds, second, 0)
    var response = Response(payload: @[2.byte])
    peer.resolveResponseFuture(0, addr response, secondId)
    check:
      second.completed
      second.read().get().payload == @[2.byte]
      not first.finished
    response = Response(payload: @[1.byte])
    peer.resolveResponseFuture(0, addr response, firstId)
    waitFor sleepAsync(1.milliseconds)
    check:
      first.completed
      first.read().get().payload == @[1.byte]
      peer.perMsgId[0].outstandingRequest.len == 0

  test "unknown IDs and wrong message types leave requests pending":
    let peer = newPeer(2)
    let first = newFuture[Opt[Response]]()
    let second = newFuture[Opt[Response]]()
    let firstId = peer.registerRequest(50.seconds, first, 0)
    let secondId = peer.registerRequest(50.seconds, second, 1)
    var response = Response(payload: @[1.byte])
    peer.resolveResponseFuture(0, addr response, secondId)
    peer.resolveResponseFuture(1, addr response, firstId)
    peer.resolveResponseFuture(0, addr response, secondId + 1)
    check:
      not first.finished
      not second.finished
      peer.perMsgId[0].outstandingRequest.len == 1
      peer.perMsgId[1].outstandingRequest.len == 1
    peer.resolveResponseFuture(0, addr response, firstId)
    peer.resolveResponseFuture(1, addr response, secondId)
    waitFor sleepAsync(1.milliseconds)
    check:
      first.completed
      second.completed
      peer.perMsgId[0].outstandingRequest.len == 0
      peer.perMsgId[1].outstandingRequest.len == 0
