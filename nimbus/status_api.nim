#
#                 Stratus
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import
  sequtils, options, strutils, parseopt, chronos, json, times,
  nimcrypto/[bcmode, hmac, rijndael, pbkdf2, sha2, sysrand, utils, keccak, hash],
  eth/keys, eth/rlp, eth/p2p, eth/p2p/rlpx_protocols/[whisper_protocol],
  eth/p2p/[discovery, enode, peer_pool], chronicles

let channel: string = "status-test-c"


proc `$`*(digest: SymKey): string =
  for c in digest: result &= hexChar(c.byte)

const
  MainBootnodes* = [
    "enode://a979fb575495b8d6db44f750317d0f4622bf4c2aa3365d6af7c284339968eef29b69ad0dce72a4d8db5ebb4968de0e3bec910127f134779fbcb0cb6d3331163c@52.16.188.185:30303",
    "enode://3f1d12044546b76342d59d4a05532c14b85aa669704bfe1f864fe079415aa2c02d743e03218e57a33fb94523adb54032871a6c51b2cc5514cb7c7e35b3ed0a99@13.93.211.84:30303",
    "enode://78de8a0916848093c73790ead81d1928bec737d565119932b98c6b100d944b7a95e94f847f689fc723399d2e31129d182f7ef3863f2b4c820abbf3ab2722344d@191.235.84.50:30303",
    "enode://158f8aab45f6d19c6cbf4a089c2670541a8da11978a2f90dbf6a502a4a3bab80d288afdbeb7ec0ef6d92de563767f3b1ea9e8e334ca711e9f8e2df5a0385e8e6@13.75.154.138:30303",
    "enode://1118980bf48b0a3640bdba04e0fe78b1add18e1cd99bf22d53daac1fd9972ad650df52176e7c7d89d1114cfef2bc23a2959aa54998a46afcf7d91809f0855082@52.74.57.123:30303",
    "enode://979b7fa28feeb35a4741660a16076f1943202cb72b6af70d327f053e248bab9ba81760f39d0701ef1d8f89cc1fbd2cacba0710a12cd5314d5e0c9021aa3637f9@5.1.83.226:30303",
  ]

  # Whisper nodes taken from:
  # https://github.com/status-im/status-react/blob/develop/resources/config/fleets.json
  WhisperNodes* = [
    "enode://2b01955d7e11e29dce07343b456e4e96c081760022d1652b1c4b641eaf320e3747871870fa682e9e9cfb85b819ce94ed2fee1ac458904d54fd0b97d33ba2c4a4@206.189.240.70:443",
    "enode://9c2b82304d988cd78bf290a09b6f81c6ae89e71f9c0f69c41d21bd5cabbd1019522d5d73d7771ea933adf0727de5e847c89e751bd807ba1f7f6fc3a0cd88d997@47.52.91.239:443",
    "enode://66ba15600cda86009689354c3a77bdf1a97f4f4fb3ab50ffe34dbc904fac561040496828397be18d9744c75881ffc6ac53729ddbd2cdbdadc5f45c400e2622f7@206.189.243.176:443",
    "enode://0440117a5bc67c2908fad94ba29c7b7f2c1536e96a9df950f3265a9566bf3a7306ea8ab5a1f9794a0a641dcb1e4951ce7c093c61c0d255f4ed5d2ed02c8fce23@35.224.15.65:443",
    "enode://a80eb084f6bf3f98bf6a492fd6ba3db636986b17643695f67f543115d93d69920fb72e349e0c617a01544764f09375bb85f452b9c750a892d01d0e627d9c251e@47.89.16.125:443",
    "enode://4ea35352702027984a13274f241a56a47854a7fd4b3ba674a596cff917d3c825506431cf149f9f2312a293bb7c2b1cca55db742027090916d01529fe0729643b@206.189.243.178:443",
    "enode://d85b87dbcd251ca21bdc4085d938e54a9af3538dd6696e2b99ec9c4694bc3eb8c6689d191129f3d9ee67aac8f0174b089143e638369245c88b9b68b9291216ff@35.224.150.136:443",
    "enode://0d9d65fcd5592df33ed4507ce862b9c748b6dbd1ea3a1deb94e3750052760b4850aa527265bbaf357021d64d5cc53c02b410458e732fafc5b53f257944247760@167.99.18.187:443",
    "enode://960777f01b7dcda7c58319e3aded317a127f686631b1702a7168ad408b8f8b7616272d805ddfab7a5a6bc4bd07ae92c03e23b4b8cd4bf858d0f74d563ec76c9f@47.52.58.213:443"
  ]

# Don't do this at home, you'll never get rid of ugly globals like this!
var
  node: EthereumNode

proc subscribeChannel(
    channel: string, handler: proc (msg: ReceivedMessage) {.gcsafe.}) =
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
  let address = Address(
    udpPort: port.Port, tcpPort: port.Port, ip: parseIpAddress("0.0.0.0"))

  let keys = newKeyPair()
  node = newEthereumNode(keys, address, 1, nil, addAllCapabilities = false)
  node.addCapability Whisper

  node.protocolState(Whisper).config.powRequirement = 0.000001

  var bootnodes: seq[ENode] = @[]
  for nodeId in MainBootnodes:
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
  poll()

type
  CReceivedMessage = object
    decoded*: ptr byte
    decodedLen*: csize
    timestamp*: uint32
    ttl*: uint32
    topic*: Topic
    pow*: float64
    hash*: Hash

proc nimbus_subscribe(channel: cstring, handler: proc (msg: ptr CReceivedMessage) {.gcsafe, cdecl.}) {.exportc.} =
  if handler.isNil:
    subscribeChannel($channel, nil)
  else:
    proc c_handler(msg: ReceivedMessage) =
      var cmsg = CReceivedMessage(
        decoded: unsafeAddr msg.decoded.payload[0],
        decodedLen: csize msg.decoded.payload.len(),
        timestamp: msg.timestamp
      )

      handler(addr cmsg)

    subscribeChannel($channel, c_handler)

proc nimbus_post(payload: cstring) {.exportc.} =
  let encPrivateKey = initPrivateKey("5dc5381cae54ba3174dc0d46040fe11614d0cc94d41185922585198b4fcef9d3")
  let encPublicKey = encPrivateKey.getPublicKey()

  var ctx: HMAC[sha256]
  var symKey: SymKey
  var npayload = cast[Bytes]($payload)
  discard ctx.pbkdf2(channel, "", 65356, symKey)

  let channelHash = digest(keccak256, channel)
  var topic: array[4, byte]
  for i in 0..<4:
    topic[i] = channelHash.data[i]

  discard node.postMessage(symKey = some(symKey),
                           src = some(encPrivateKey),
                           ttl = 20,
                           topic = topic,
                           payload = npayload,
                           powTarget = 0.002)

proc nimbus_add_peer(nodeId: cstring) {.exportc.} =
  var whisperENode: ENode
  discard initENode($nodeId, whisperENode)
  var whisperNode = newNode(whisperENode)

  asyncCheck node.peerPool.connectToNode(whisperNode)
