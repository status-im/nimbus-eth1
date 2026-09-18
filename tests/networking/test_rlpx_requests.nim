# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.

{.used.}

import
  std/deques,
  unittest2,
  chronos,
  ../../execution_chain/networking/protocol_dsl {.all.}

type Response = ref object
  payload: seq[byte]

var responsesFreed = 0

proc responseFreed(response: Response) {.gcsafe.} =
  inc responsesFreed

proc newPeer(): Peer =
  Peer(
    dispatcher: Dispatcher(messages: @[
      MessageInfo(requestResolver: requestResolver[Response])]),
    perMsgId: @[PerMsgId(outstandingRequest: initDeque[OutstandingRequest]())],
  )

proc completeResponse(peer: Peer) =
  let future = newFuture[Opt[Response]]()
  let id = peer.registerRequest(50.seconds, future, 0)
  var response: Response
  new(response, responseFreed)
  response.payload = newSeq[byte](1024 * 1024)
  peer.resolveResponseFuture(0, addr response, id)
  doAssert future.completed
  # Let completion callbacks run.
  waitFor sleepAsync(1.milliseconds)

suite "RLPx request lifetime":
  test "successful response is released before its timeout":
    let peer = newPeer()
    let before = responsesFreed
    completeResponse(peer)
    GC_fullCollect()
    check:
      peer.perMsgId[0].outstandingRequest.len == 0
      responsesFreed == before + 1

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

  test "cancelling a request preserves the order of remaining requests":
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
      peer.perMsgId[0].outstandingRequest[0].id == firstId
      peer.perMsgId[0].outstandingRequest[1].id == lastId
    waitFor first.cancelAndWait()
    waitFor last.cancelAndWait()
    waitFor sleepAsync(1.milliseconds)
    check peer.perMsgId[0].outstandingRequest.len == 0

  test "disconnect cleanup can remove requests before completion callbacks":
    let peer = newPeer()
    let future = newFuture[Opt[Response]]()
    discard peer.registerRequest(50.seconds, future, 0)
    let req = peer.perMsgId[0].outstandingRequest.popFirst()
    peer.dispatcher.messages[0].requestResolver(nil, req.future)
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
