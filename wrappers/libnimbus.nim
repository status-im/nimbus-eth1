#
#                 Stratus
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import
  chronos, chronicles, nimcrypto/[utils, hmac, pbkdf2, hash],
  eth/[keys, rlp, p2p], eth/p2p/rlpx_protocols/whisper_protocol,
  eth/p2p/[discovery, enode, peer_pool, bootnodes, whispernodes]

type
  CReceivedMessage* = object
    decoded*: ptr byte
    decodedLen*: csize
    timestamp*: uint32
    ttl*: uint32
    topic*: Topic
    pow*: float64
    hash*: Hash

proc `$`*(digest: SymKey): string =
  for c in digest: result &= hexChar(c.byte)

# Don't do this at home, you'll never get rid of ugly globals like this!
var
  node: EthereumNode

# TODO: Return filter ID if we ever want to unsubscribe
proc subscribeChannel(
    channel: string, handler: proc (msg: ReceivedMessage) {.gcsafe.}) =
  setupForeignThreadGc()
  var ctx: HMAC[sha256]
  var symKey: SymKey
  discard ctx.pbkdf2(channel, "", 65356, symKey)

  let channelHash = digest(keccak256, channel)
  var topic: array[4, byte]
  for i in 0..<4:
    topic[i] = channelHash.data[i]

  info "Subscribing to channel", channel, topic, symKey

  discard node.subscribeFilter(newFilter(symKey = some(symKey),
                                          topics = @[topic]),
                              handler)

# proc handler(msg: ReceivedMessage) {.gcsafe.} =
#   try:
#     # ["~#c4",["dcasdc","text/plain","~:public-group-user-message",
#     #          154604971756901,1546049717568,[
#     #             "^ ","~:chat-id","nimbus-test","~:text","dcasdc"]]]
#     let
#       src =
#         if msg.decoded.src.isSome(): $msg.decoded.src.get()
#         else: ""
#       payload = cast[string](msg.decoded.payload)
#       data = parseJson(cast[string](msg.decoded.payload))
#       channel = data.elems[1].elems[5].elems[2].str
#       time = $fromUnix(data.elems[1].elems[4].num div 1000)
#       message = data.elems[1].elems[0].str

#     info "adding", full=(cast[string](msg.decoded.payload))
#   except:
#     notice "no luck parsing", message=getCurrentExceptionMsg()

proc nimbus_start(port: uint16 = 30303) {.exportc.} =
  setupForeignThreadGc()
  let address = Address(
    udpPort: port.Port, tcpPort: port.Port, ip: parseIpAddress("0.0.0.0"))

  let keys = newKeyPair()
  node = newEthereumNode(keys, address, 1, nil, addAllCapabilities = false)
  node.addCapability Whisper

  node.protocolState(Whisper).config.powRequirement = 0.000001

  var bootnodes: seq[ENode] = @[]
  for nodeId in MainnetBootnodes:
    var bootnode: ENode
    discard initENode(nodeId, bootnode)
    bootnodes.add(bootnode)

  asyncCheck node.connectToNetwork(bootnodes, true, true)
  # main network has mostly non SHH nodes, so we connect directly to SHH nodes
  for nodeId in WhisperNodes:
    var whisperENode: ENode
    discard initENode(nodeId, whisperENode)
    var whisperNode = newNode(whisperENode)

    asyncCheck node.peerPool.connectToNode(whisperNode)

proc nimbus_poll() {.exportc.} =
  setupForeignThreadGc()
  poll()

# TODO: Consider better naming to understand how it relates to public channels etc
proc nimbus_subscribe(channel: cstring, handler: proc (msg: ptr CReceivedMessage) {.gcsafe, cdecl.}) {.exportc.} =
  setupForeignThreadGc()

  if handler.isNil:
    subscribeChannel($channel, nil)
  else:
    proc c_handler(msg: ReceivedMessage) =
      var cmsg = CReceivedMessage(
        decoded: unsafeAddr msg.decoded.payload[0],
        decodedLen: csize msg.decoded.payload.len(),
        timestamp: msg.timestamp,
        ttl: msg.ttl,
        topic: msg.topic,
        pow: msg.pow,
        hash: msg.hash
      )

      handler(addr cmsg)

    subscribeChannel($channel, c_handler)

# TODO: Add signing key as parameter
# TODO: How would we do key management? In nimbus (like in rpc) or in status go?
proc nimbus_post(channel: cstring, payload: cstring) {.exportc.} =
  setupForeignThreadGc()
  let encPrivateKey = initPrivateKey("5dc5381cae54ba3174dc0d46040fe11614d0cc94d41185922585198b4fcef9d3")

  var ctx: HMAC[sha256]
  var symKey: SymKey
  var npayload = cast[Bytes]($payload)
  discard ctx.pbkdf2($channel, "", 65356, symKey)

  let channelHash = digest(keccak256, $channel)
  var topic: array[4, byte]
  for i in 0..<4:
    topic[i] = channelHash.data[i]

  # TODO: Handle error case
  discard node.postMessage(symKey = some(symKey),
                           src = some(encPrivateKey),
                           ttl = 20,
                           topic = topic,
                           payload = npayload,
                           powTarget = 0.002)

proc nimbus_add_peer(nodeId: cstring) {.exportc.} =
  setupForeignThreadGc()
  var whisperENode: ENode
  discard initENode($nodeId, whisperENode)
  var whisperNode = newNode(whisperENode)

  asyncCheck node.peerPool.connectToNode(whisperNode)
