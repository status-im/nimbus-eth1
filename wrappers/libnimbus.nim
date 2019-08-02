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
  eth/[keys, rlp, p2p], eth/p2p/rlpx_protocols/[whisper_protocol],
  eth/p2p/[discovery, enode, peer_pool], chronicles,
  ../nimbus/config

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

const
  # Whisper nodes taken from:
  # curl -s  https://raw.githubusercontent.com/status-im/status-react/develop/resources/config/fleets.json | jq '"\"" + .fleets["eth.beta"].whisper[] + "\","' -r
  WhisperNodes* = [
    "enode://9c2b82304d988cd78bf290a09b6f81c6ae89e71f9c0f69c41d21bd5cabbd1019522d5d73d7771ea933adf0727de5e847c89e751bd807ba1f7f6fc3a0cd88d997@47.52.91.239:443",
    "enode://66ba15600cda86009689354c3a77bdf1a97f4f4fb3ab50ffe34dbc904fac561040496828397be18d9744c75881ffc6ac53729ddbd2cdbdadc5f45c400e2622f7@206.189.243.176:443",
    "enode://0440117a5bc67c2908fad94ba29c7b7f2c1536e96a9df950f3265a9566bf3a7306ea8ab5a1f9794a0a641dcb1e4951ce7c093c61c0d255f4ed5d2ed02c8fce23@35.224.15.65:443",
    "enode://a80eb084f6bf3f98bf6a492fd6ba3db636986b17643695f67f543115d93d69920fb72e349e0c617a01544764f09375bb85f452b9c750a892d01d0e627d9c251e@47.89.16.125:443",
    "enode://4ea35352702027984a13274f241a56a47854a7fd4b3ba674a596cff917d3c825506431cf149f9f2312a293bb7c2b1cca55db742027090916d01529fe0729643b@206.189.243.178:443",
    "enode://552942cc4858073102a6bcd0df9fe4de6d9fc52ddf7363e8e0746eba21b0f98fb37e8270bc629f72cfe29e0b3522afaf51e309a05998736e2c0dad5288991148@130.211.215.133:443",
    "enode://aa97756bc147d74be6d07adfc465266e17756339d3d18591f4be9d1b2e80b86baf314aed79adbe8142bcb42bc7bc40e83ee3bbd0b82548e595bf855d548906a1@47.52.188.241:443",
    "enode://ce559a37a9c344d7109bd4907802dd690008381d51f658c43056ec36ac043338bd92f1ac6043e645b64953b06f27202d679756a9c7cf62fdefa01b2e6ac5098e@206.189.243.179:443",
    "enode://b33dc678589931713a085d29f9dc0efee1783dacce1d13696eb5d3a546293198470d97822c40b187336062b39fd3464e9807858109752767d486ea699a6ab3de@35.193.151.184:443",
    "enode://f34451823b173dc5f2ac0eec1668fdb13dba9452b174249a7e0272d6dce16fb811a01e623300d1b7a67c240ae052a462bff3f60e4a05e4c4bd23cc27dea57051@47.52.173.66:443",
    "enode://4e0a8db9b73403c9339a2077e911851750fc955db1fc1e09f81a4a56725946884dd5e4d11258eac961f9078a393c45bcab78dd0e3bc74e37ce773b3471d2e29c@206.189.243.171:443",
    "enode://eb4cc33c1948b1f4b9cb8157757645d78acd731cc8f9468ad91cef8a7023e9c9c62b91ddab107043aabc483742ac15cb4372107b23962d3bfa617b05583f2260@146.148.66.209:443",
    "enode://7c80e37f324bbc767d890e6381854ef9985d33940285413311e8b5927bf47702afa40cd5d34be9aa6183ac467009b9545e24b0d0bc54ef2b773547bb8c274192@47.91.155.62:443",
    "enode://a8bddfa24e1e92a82609b390766faa56cf7a5eef85b22a2b51e79b333c8aaeec84f7b4267e432edd1cf45b63a3ad0fc7d6c3a16f046aa6bc07ebe50e80b63b8c@206.189.243.172:443",
    "enode://c7e00e5a333527c009a9b8f75659d9e40af8d8d896ebaa5dbdd46f2c58fc010e4583813bc7fc6da98fcf4f9ca7687d37ced8390330ef570d30b5793692875083@35.192.123.253:443",
    "enode://4b2530d045b1d9e0e45afa7c008292744fe77675462090b4001f85faf03b87aa79259c8a3d6d64f815520ac76944e795cbf32ff9e2ce9ba38f57af00d1cc0568@47.90.29.122:443",
    "enode://887cbd92d95afc2c5f1e227356314a53d3d18855880ac0509e0c0870362aee03939d4074e6ad31365915af41d34320b5094bfcc12a67c381788cd7298d06c875@206.189.243.177:443",
    "enode://2af8f4f7a0b5aabaf49eb72b9b59474b1b4a576f99a869e00f8455928fa242725864c86bdff95638a8b17657040b21771a7588d18b0f351377875f5b46426594@35.232.187.4:443",
    "enode://76ee16566fb45ca7644c8dec7ac74cadba3bfa0b92c566ad07bcb73298b0ffe1315fd787e1f829e90dba5cd3f4e0916e069f14e50e9cbec148bead397ac8122d@47.91.226.75:443",
    "enode://2b01955d7e11e29dce07343b456e4e96c081760022d1652b1c4b641eaf320e3747871870fa682e9e9cfb85b819ce94ed2fee1ac458904d54fd0b97d33ba2c4a4@206.189.240.70:443",
    "enode://19872f94b1e776da3a13e25afa71b47dfa99e658afd6427ea8d6e03c22a99f13590205a8826443e95a37eee1d815fc433af7a8ca9a8d0df7943d1f55684045b7@35.238.60.236:443",
    "enode://960777f01b7dcda7c58319e3aded317a127f686631b1702a7168ad408b8f8b7616272d805ddfab7a5a6bc4bd07ae92c03e23b4b8cd4bf858d0f74d563ec76c9f@47.52.58.213:443",
    "enode://0d9d65fcd5592df33ed4507ce862b9c748b6dbd1ea3a1deb94e3750052760b4850aa527265bbaf357021d64d5cc53c02b410458e732fafc5b53f257944247760@167.99.18.187:443",
    "enode://d85b87dbcd251ca21bdc4085d938e54a9af3538dd6696e2b99ec9c4694bc3eb8c6689d191129f3d9ee67aac8f0174b089143e638369245c88b9b68b9291216ff@35.224.150.136:443",
  ]

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
