# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

const tracingEnabled = defined(p2pdump)

when tracingEnabled:
  import
    std/typetraits,
    json_serialization, chronicles #, chronicles_tail/configuration

  export
    # XXX: Nim visibility rules get in the way here.
    # It would be nice if the users of this module don't have to
    # import json_serializer, but this won't work at the moment,
    # because the `encode` call inside `logMsgEvent` has its symbols
    # mixed in from the module where `logMsgEvent` is called
    # (instead of from this module, which will be more logical).
    init, writeValue, getOutput
    # TODO: File this as an issue

  logStream p2pMessages[json[file(p2p_messages.json,truncate)]]
  # p2pMessages.useTailPlugin "p2p_tracing_ctail_plugin.nim"

  template logRecord(eventName: static[string], args: varargs[untyped]) =
    p2pMessages.log LogLevel.NONE, eventName, topics = "p2pdump", args

  proc initTracing*(baseProtocol: ProtocolInfo,
                    userProtocols: seq[ProtocolInfo]) =
    once:
      var s = init OutputStream
      var w = JsonWriter.init(s)

      proc addProtocol(p: ProtocolInfo) =
        w.writeFieldName p.name
        w.beginRecord()
        var i = 0
        for msg in p.messages:
          let msgId = i # msg.id
          w.writeField $msgId, msg.name
          inc i
        w.endRecordField()

      w.beginRecord()
      addProtocol baseProtocol
      for userProtocol in userProtocols:
        addProtocol userProtocol
      w.endRecord()

      logRecord "p2p_protocols", data = JsonString(s.getOutput(string))

  proc logMsgEventImpl*(eventName: static[string],
                       peer: Peer,
                       protocol: ProtocolInfo,
                       msgName: string,
                       json: string) =
    # this is kept as a separate proc to reduce the code bloat
    logRecord eventName, peer = $peer.remote,
                         protocol = protocol.name,
                         msg = msgName,
                         data = JsonString(json)

  template logMsgEventImpl*(eventName: static[string],
                            responder: Responder,
                            protocol: ProtocolInfo,
                            msgName: string,
                            json: string) =
    logMsgEventImpl(eventName, UntypedResponder(responder).peer,
                    protocol, msgName, json)

  proc logMsgEvent[Msg](eventName: static[string], peer: Peer, msg: Msg) =
    mixin msgProtocol, protocolInfo, msgId, RecType
    type R = RecType(Msg)
    logMsgEventImpl(eventName, peer,
                    Msg.msgProtocol.protocolInfo,
                    Msg.type.name,
                    Json.encode(R msg))

  template logSentMsg*(peer: Peer, msg: auto) =
    logMsgEvent("outgoing_msg", peer, msg)

  template logReceivedMsg*(peer: Peer, msg: auto) =
    logMsgEvent("incoming_msg", peer, msg)

  template logConnectedPeer*(p: Peer) =
    logRecord "peer_connected",
              port = int(p.network.address.tcpPort),
              peer = $p.remote

  template logAcceptedPeer*(p: Peer) =
    logRecord "peer_accepted",
              port = int(p.network.address.tcpPort),
              peer = $p.remote

  template logDisconnectedPeer*(p: Peer) =
    logRecord "peer_disconnected",
              port = int(p.network.address.tcpPort),
              peer = $p.remote

else:
  template initTracing*(baseProtocol: ProtocolInfo,
                       userProtocols: seq[ProtocolInfo])= discard
  template logSentMsg*(peer: Peer, msg: auto) = discard
  template logReceivedMsg*(peer: Peer, msg: auto) = discard
  template logConnectedPeer*(peer: Peer) = discard
  template logAcceptedPeer*(peer: Peer) = discard
  template logDisconnectedPeer*(peer: Peer) = discard

