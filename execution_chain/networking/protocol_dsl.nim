# nimbus-execution-client
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/typetraits,
  stew/shims/macros,
  stew/byteutils,
  chronos,
  eth/rlp,
  snappy,
  chronicles,
  ./p2p_types,
  ./protocol_registry

# TODO: chronicles re-export here is added for the error
# "undeclared identifier: 'activeChroniclesStream'", when the code using p2p
# does not import chronicles. Need to resolve this properly.
export chronicles, p2p_types, protocol_registry

logScope:
  topics = "p2p rlpx"

#------------------------------------------------------------------------------
# Rlpx Private functions
#------------------------------------------------------------------------------

# TODO Rework the disconnect-and-raise flow to not do both raising
#      and disconnection - this results in convoluted control flow and redundant
#      disconnect calls
proc initFuture[T](loc: var Future[T]) =
  loc = newFuture[T]()

template raisePeerDisconnected(r: DisconnectionReason, msg: string) =
  var e = newException(PeerDisconnected, msg)
  e.reason = r
  raise e

proc disconnectAndRaise*(
    peer: Peer, reason: DisconnectionReason, msg: string
) {.async: (raises: [PeerDisconnected]).} =
  if reason == BreachOfProtocol:
    warn "TODO Raising protocol breach",
      remote = peer.remote, clientId = peer.clientId, msg
  if peer.disconnectPeer.isNil.not:
    await peer.disconnectPeer(peer, reason)
    raisePeerDisconnected(reason, msg)
  peer.disconnectPeer = nil

template compressMsg(peer: Peer, data: seq[byte]): seq[byte] =
  if peer.snappyEnabled:
    snappy.encode(data)
  else:
    data

proc sendMsg(
    peer: Peer, msgId: uint64, payload: seq[byte], sendDisconnect: static[bool]
): Future[void] {.async: (raises: [CancelledError, EthP2PError]).} =
  try:
    let
      msgIdBytes = rlp.encodeInt(msgId)
      payloadBytes = peer.compressMsg(payload)

    var msg = newSeqOfCap[byte](msgIdBytes.data.len + payloadBytes.len)
    msg.add msgIdBytes.data()
    msg.add payloadBytes

    trace "Sending message",
      remote = peer.remote,
      clientId = peer.clientId,
      msgId,
      data = toHex(msg.toOpenArray(0, min(255, msg.high))),
      payload = toHex(payload.toOpenArray(0, min(255, payload.high)))

    await peer.transport.sendMsg(msg)
  except TransportError as exc:
    when sendDisconnect:
      await peer.disconnectAndRaise(TcpError, exc.msg)
    else:
      raisePeerDisconnected(TcpError, exc.msg)
  except RlpxTransportError as exc:
    when sendDisconnect:
      await peer.disconnectAndRaise(BreachOfProtocol, exc.msg)
    else:
      raisePeerDisconnected(BreachOfProtocol, exc.msg)

proc registerRequest(
    peer: Peer, timeout: Duration, responseFuture: FutureBase, responseMsgId: uint64
): uint64 =
  result =
    if peer.lastReqId.isNone:
      0u64
    else:
      peer.lastReqId.value + 1u64
  peer.lastReqId = Opt.some(result)

  let timeoutAt = Moment.fromNow(timeout)
  let req = OutstandingRequest(id: result, future: responseFuture)
  peer.perMsgId[responseMsgId].outstandingRequest.addLast req

  doAssert(not peer.dispatcher.isNil)
  let requestResolver = peer.dispatcher.messages[responseMsgId].requestResolver
  proc timeoutExpired(udata: pointer) {.gcsafe.} =
    requestResolver(nil, responseFuture)

  discard setTimer(timeoutAt, timeoutExpired, nil)

proc messagePrinter[MsgType](msg: pointer): string {.gcsafe.} =
  result = ""
  # TODO: uncommenting the line below increases the compile-time
  # tremendously (for reasons not yet known)
  # result = $(cast[ptr MsgType](msg)[])

proc requestResolver[MsgType](msg: pointer, future: FutureBase) {.gcsafe.} =
  var f = Future[Opt[MsgType]](future)
  if not f.finished:
    if msg != nil:
      f.complete Opt.some(cast[ptr MsgType](msg)[])
    else:
      f.complete Opt.none(MsgType)

proc nextMsgResolver[MsgType](
    msgData: Rlp, future: FutureBase
) {.gcsafe, raises: [RlpError].} =
  var reader = msgData
  when MsgType is ref:
    # TODO: rlp support ref types
    type T = typeof(MsgType()[])
    var msg = MsgType()
    msg[] = reader.readRecordType(
      T, T.rlpFieldsCount > 1
    )
    Future[MsgType](future).complete msg
  else:
    Future[MsgType](future).complete reader.readRecordType(
      MsgType, MsgType.rlpFieldsCount > 1
    )

proc failResolver[MsgType](reason: DisconnectionReason, future: FutureBase) =
  Future[MsgType](future).fail(
    (ref PeerDisconnected)(msg: "Peer disconnected during handshake", reason: reason),
    warn = false,
  )

proc resolveResponseFuture(peer: Peer, msgId: uint64, msg: pointer) =
  ## This function is a split off from the previously combined version with
  ## the same name using optional request ID arguments. This here is the
  ## version without a request ID (there is the other part below.).
  ##
  ## Optional arguments for macro helpers seem easier to handle with
  ## polymorphic functions (than a `Opt[]` prototype argument.)
  ##
  let msgInfo = peer.dispatcher.messages[msgId]

  logScope:
    msg = msgInfo.name
    msgContents = msgInfo.printer(msg)
    receivedReqId = -1
    remotePeer = peer.remote

  template outstandingReqs(): auto =
    peer.perMsgId[msgId].outstandingRequest

  block: # no request ID
    # XXX: This is a response from an ETH-like protocol that doesn't feature
    # request IDs. Handling the response is quite tricky here because this may
    # be a late response to an already timed out request or a valid response
    # from a more recent one.
    #
    # We can increase the robustness by recording enough features of the
    # request so we can recognize the matching response, but this is not very
    # easy to do because our peers are allowed to send partial responses.
    #
    # A more generally robust approach is to maintain a set of the wanted
    # data items and then to periodically look for items that have been
    # requested long time ago, but are still missing. New requests can be
    # issues for such items potentially from another random peer.
    var expiredRequests = 0
    for req in outstandingReqs:
      if not req.future.finished:
        break
      inc expiredRequests
    outstandingReqs.shrink(fromFirst = expiredRequests)
    if outstandingReqs.len > 0:
      let oldestReq = outstandingReqs.popFirst
      msgInfo.requestResolver(msg, oldestReq.future)
    else:
      trace "late or dup RPLx reply ignored", msgId

proc resolveResponseFuture(peer: Peer, msgId: uint64, msg: pointer, reqId: uint64) =
  ## Variant of `resolveResponseFuture()` for request ID argument.
  let msgInfo = peer.dispatcher.messages[msgId]
  logScope:
    msg = msgInfo.name
    msgContents = msgInfo.printer(msg)
    receivedReqId = reqId
    remotePeer = peer.remote

  template outstandingReqs(): auto =
    peer.perMsgId[msgId].outstandingRequest

  block: # have request ID
    # TODO: This is not completely sound because we are still using a global
    # `reqId` sequence (the problem is that we might get a response ID that
    # matches a request ID for a different type of request). To make the code
    # correct, we can use a separate sequence per response type, but we have
    # to first verify that the other Ethereum clients are supporting this
    # correctly (because then, we'll be reusing the same reqIds for different
    # types of requests). Alternatively, we can assign a separate interval in
    # the `reqId` space for each type of response.
    if peer.lastReqId.isNone or reqId > peer.lastReqId.value:
      debug "RLPx response without matching request", msgId, reqId
      return

    var idx = 0
    while idx < outstandingReqs.len:
      template req(): auto =
        outstandingReqs()[idx]

      if req.future.finished:
        # Here we'll remove the expired request by swapping
        # it with the last one in the deque (if necessary):
        if idx != outstandingReqs.len - 1:
          req = outstandingReqs.popLast
          continue
        else:
          outstandingReqs.shrink(fromLast = 1)
          # This was the last item, so we don't have any
          # more work to do:
          return

      if req.id == reqId:
        msgInfo.requestResolver msg, req.future
        # Here we'll remove the found request by swapping
        # it with the last one in the deque (if necessary):
        if idx != outstandingReqs.len - 1:
          req = outstandingReqs.popLast
        else:
          outstandingReqs.shrink(fromLast = 1)
        return

      inc idx

    trace "late or dup RPLx reply ignored"

proc linkSendFailureToReqFuture[S, R](sendFut: Future[S], resFut: Future[R]) =
  sendFut.addCallback do(arg: pointer):
    # Avoiding potentially double future completions
    if not resFut.finished:
      if sendFut.failed:
        resFut.fail(sendFut.error)

proc registerMsg(
    protocol: ProtocolInfo,
    msgId: uint64,
    name: string,
    thunk: ThunkProc,
    printer: MessageContentPrinter,
    requestResolver: RequestResolver,
    nextMsgResolver: NextMsgResolver,
    failResolver: FailResolver,
) =
  if protocol.messages.len.uint64 <= msgId:
    protocol.messages.setLen(msgId + 1)
  protocol.messages[msgId] = MessageInfo(
    id: msgId,
    name: name,
    thunk: thunk,
    printer: printer,
    requestResolver: requestResolver,
    nextMsgResolver: nextMsgResolver,
    failResolver: failResolver,
  )

#------------------------------------------------------------------------------
# Mini Protocol DSL private helpers
#------------------------------------------------------------------------------

type
  Responder* = object
    peer*: Peer
    reqId*: uint64

proc `$`*(r: Responder): string =
  $r.peer & ": " & $r.reqId

func initResponder(peer: Peer, reqId: uint64): Responder =
  Responder(peer: peer, reqId: reqId)

template msgIdImpl(PROTO: type; peer: Peer, methId: uint64): uint64 =
  mixin protocolInfo, isSubProtocol
  when PROTO.isSubProtocol:
    perPeerMsgIdImpl(peer, PROTO.protocolInfo, methId)
  else:
    methId

macro countArgs(args: untyped): untyped =
  var count = 0
  for arg in args:
    let arg = if arg.kind == nnkHiddenStdConv: arg[1]
              else: arg
    if arg.kind == nnkArgList:
      for _ in arg:
        inc count
    else:
      inc count
  result = newLit(count)

macro appendArgs(writer: untyped, args: untyped): untyped =
  result = newStmtList()
  for arg in args:
    let arg = if arg.kind == nnkHiddenStdConv: arg[1]
              else: arg
    if arg.kind == nnkArgList:
      for subarg in arg:
        result.add quote do:
          append(`writer`, `subarg`)
    else:
      result.add quote do:
        append(`writer`, `arg`)

template constOrLet(PROTO: type, id: untyped, body: untyped) =
  mixin isSubProtocol
  when PROTO.isSubProtocol:
    let `id` {.inject.} = body
  else:
    const `id` {.inject.} = body

template rlpxSendImpl(PROTO: type,
                      peer: Peer,
                      msgId: static[uint64],
                      perPeerMsgId: untyped,
                      params: varargs[untyped]): auto =
  PROTO.constOrLet(perPeerMsgId):
    msgIdImpl(PROTO, peer, msgId)
  var writer = initRlpWriter()
  const paramsLen = countArgs([params])
  when paramsLen > 1:
    startList(writer, paramsLen)
  appendArgs(writer, [params])
  finish(writer)

proc checkedRlpRead(
    peer: Peer, r: var Rlp, MsgType: type
): auto {.raises: [RlpError].} =
  when defined(release):
    return r.read(MsgType)
  else:
    try:
      return r.read(MsgType)
    except rlp.RlpError as e:
      debug "Failed rlp.read",
        peer = peer, dataType = typetraits.name(MsgType), err = e.msg, errName = e.name
        #, rlpData = r.inspect -- don't use (might crash)

      raise e

macro checkedRlpFields(peer; rlp; packet; fields): untyped =
  result = newStmtList()
  for field in fields:
    result.add quote do:
      `packet`.`field` = checkedRlpRead(`peer`, `rlp`, typeof(`packet`.`field`))

macro countFields(fields): untyped =
  var count = 0
  for _ in fields:
    inc count
  result = newLit(count)

template wrapRlpxWithPacketException(MSGTYPE: type, peer: Peer, body): untyped =
  const
    msgName = astToStr(MSGTYPE)

  try:
    body
  except rlp.RlpError as exc:
    discard
    warn "TODO: RLP decoding failed for incoming message",
         msg = msgName, remote = peer.remote,
         clientId = peer.clientId, err = exc.msg
    await peer.disconnectAndRaise(BreachOfProtocol,
      "Invalid RLP in parameter list for " & msgName)

#------------------------------------------------------------------------------
# Mini Protocol DSL public templates
#------------------------------------------------------------------------------

template rlpxSendMessage*(PROTO: type, peer: Peer, msgId: static[uint64], params: varargs[untyped]): auto =
  let msgBytes = rlpxSendImpl(PROTO, peer, msgId, perPeerMsgId, params)
  sendMsg(peer, perPeerMsgId, msgBytes, sendDisconnect = true)

template rlpxSendDisconnect*(PROTO: type, peer: Peer, msgId: static[uint64], params: varargs[untyped]): auto =
  let msgBytes = rlpxSendImpl(PROTO, peer, msgId, perPeerMsgId, params)
  sendMsg(peer, perPeerMsgId, msgBytes, sendDisconnect = false) # Do not re send disconnect upon error

template rlpxSendMessage*(PROTO: type, responder: Responder, msgId: static[uint64], params: varargs[untyped]): auto =
  PROTO.constOrLet(perPeerMsgId):
    msgIdImpl(PROTO, responder.peer, msgId)
  var writer = initRlpWriter()
  const paramsLen = countArgs([params])
  when paramsLen > 0:
    startList(writer, paramsLen + 1)
  append(writer, responder.reqId)
  appendArgs(writer, [params])
  let msgBytes = finish(writer)
  sendMsg(responder.peer, perPeerMsgId, msgBytes, sendDisconnect = true)

template rlpxSendRequest*(PROTO: type, peer: Peer, timeout: Duration, msgId: static[uint64], params: varargs[untyped]) =
  PROTO.constOrLet(perPeerMsgId):
    msgIdImpl(PROTO, peer, msgId)
  var writer = initRlpWriter()
  const paramsLen = countArgs([params])
  if paramsLen > 0:
    startList(writer, paramsLen + 1)
  initFuture result
  let reqId = registerRequest(peer, timeout, result, perPeerMsgId + 1)
  append(writer, reqId)
  appendArgs(writer, [params])
  let msgBytes = finish(writer)
  linkSendFailureToReqFuture(sendMsg(peer, perPeerMsgId, msgBytes, sendDisconnect = true), result)

template rlpxWithPacketHandler*(PROTO: distinct type;
                        MSGTYPE: distinct type;
                        peer: Peer;
                        data: Rlp,
                        fields: untyped;
                        body): untyped =
  const
    numFields = countFields(fields)

  wrapRlpxWithPacketException(MSGTYPE, peer):
    var
      rlp = data
      packet {.inject.} = MSGTYPE()

    when numFields > 1:
      tryEnterList(rlp)

    checkedRlpFields(peer, rlp, packet, fields)
    body

template rlpxWithPacketResponder*(PROTO: distinct type;
                        MSGTYPE: distinct type;
                        peer: Peer;
                        data: Rlp,
                        body): untyped =
  wrapRlpxWithPacketException(MSGTYPE, peer):
    var rlp = data
    tryEnterList(rlp)
    let reqId = read(rlp, uint64)
    var
      response {.inject.} = initResponder(peer, reqId)
      packet {.inject.} = checkedRlpRead(peer, rlp, MSGTYPE)
    body

template rlpxWithFutureHandler*(PROTO: distinct type;
                        MSGTYPE: distinct type;
                        msgId: static[uint64];
                        peer: Peer;
                        data: Rlp,
                        fields: untyped): untyped =
  wrapRlpxWithPacketException(MSGTYPE, peer):
    var
      rlp = data
      packet = MSGTYPE()

    tryEnterList(rlp)
    let reqId = read(rlp, uint64)
    PROTO.constOrLet(perPeerMsgId):
      msgIdImpl(PROTO, peer, msgId)
    checkedRlpFields(peer, rlp, packet, fields)
    resolveResponseFuture(peer,
      perPeerMsgId, addr(packet), reqId)

template rlpxWithFutureHandler*(PROTO: distinct type;
                        MSGTYPE: distinct type;
                        PROTYPE: distinct type;
                        msgId: static[uint64];
                        peer: Peer;
                        data: Rlp,
                        fields: untyped): untyped =
  wrapRlpxWithPacketException(MSGTYPE, peer):
    var
      rlp = data
      packet: MSGTYPE

    tryEnterList(rlp)
    let reqId = read(rlp, uint64)
    PROTO.constOrLet(perPeerMsgId):
      msgIdImpl(PROTO, peer, msgId)
    checkedRlpFields(peer, rlp, packet, fields)
    var proType = packet.to(PROTYPE)
    resolveResponseFuture(peer,
      perPeerMsgId, addr(proType), reqId)

template registerMsg*(protocol: ProtocolInfo,
                     msgId: static[uint64],
                     msgName: static[string],
                     msgThunk: untyped,
                     MsgType: type) =
  registerMsg(protocol,
    msgId,
    msgName,
    msgThunk,
    messagePrinter[MsgType],
    requestResolver[MsgType],
    nextMsgResolver[MsgType],
    failResolver[MsgType])

template state*(response: Responder, PROTO: type): auto =
  state(response.peer, PROTO)

template supports*(response: Responder, PROTO: type): bool =
  response.peer.supports(PROTO.protocolInfo)

template networkState*(response: Responder, PROTO: type): auto =
  networkState(response.peer, PROTO)

proc nextMsg*(PROTO: distinct type,
              peer: Peer,
              MsgType: distinct type,
              msgId: static[uint64]): Future[MsgType]
              {.async: (raises: [CancelledError, EthP2PError], raw: true).} =
  ## This procs awaits a specific RLPx message.
  ## Any messages received while waiting will be dispatched to their
  ## respective handlers. The designated message handler will also run
  ## to completion before the future returned by `nextMsg` is resolved.
  mixin isSubProtocol
  when PROTO.isSubProtocol:
    let wantedId = msgIdImpl(PROTO, peer, msgId)
  else:
    const wantedId = msgIdImpl(PROTO, peer, msgId)

  let f = peer.perMsgId[wantedId].awaitedMessage
  if not f.isNil:
    return Future[MsgType].Raising([CancelledError, EthP2PError])(f)

  initFuture result
  peer.perMsgId[wantedId].awaitedMessage = result
