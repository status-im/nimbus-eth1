#
#                 Nimbus
#              (c) Copyright 2018
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import
  chronos, chronicles, nimcrypto/[utils, hmac, pbkdf2, hash], tables,
  eth/[keys, rlp, p2p], eth/p2p/rlpx_protocols/whisper_protocol,
  eth/p2p/[discovery, enode, peer_pool, bootnodes, whispernodes]

from stew/byteutils import hexToSeqByte, hexToByteArray

# TODO: If we really want/need this type of API for the keys, put it somewhere
# seperate as it is the same code for Whisper RPC
type
  WhisperKeys* = ref object
    asymKeys*: Table[string, KeyPair]
    symKeys*: Table[string, SymKey]

  KeyGenerationError = object of CatchableError

proc newWhisperKeys*(): WhisperKeys =
  new(result)
  result.asymKeys = initTable[string, KeyPair]()
  result.symKeys = initTable[string, SymKey]()

# TODO: again, lots of overlap with Nimbus whisper RPC here, however not all
# the same due to type conversion (no use of Option and such)
type
  CReceivedMessage* = object
    decoded*: ptr byte
    decodedLen*: csize
    source*: PublicKey
    recipientPublicKey*: PublicKey
    timestamp*: uint32
    ttl*: uint32
    topic*: Topic
    pow*: float64
    hash*: Hash

  CFilterOptions* = object
    symKeyID*: cstring
    privateKeyID*: cstring
    source*: ptr PublicKey
    minPow*: float64
    topic*: Topic # lets go with one topic for now
    allowP2P*: bool

  CPostMessage* = object
    symKeyID*: cstring
    pubKey*: ptr PublicKey
    sourceID*: cstring
    ttl*: uint32
    topic*: Topic
    payload*: cstring
    padding*: cstring
    powTime*: float64
    powTarget*: float64

  CTopic* = object
    topic*: Topic

template foreignThreadGc*(body: untyped) =
  setupForeignThreadGc()
  `body`
  tearDownForeignThreadGc()

proc `$`*(digest: SymKey): string =
  for c in digest: result &= hexChar(c.byte)

# Don't do this at home, you'll never get rid of ugly globals like this!
var
  node: EthereumNode
# You will only add more instead!
let whisperKeys = newWhisperKeys()

# TODO: Return filter ID if we ever want to unsubscribe
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

  tearDownForeignThreadGc()

proc nimbus_poll() {.exportc.} =
  setupForeignThreadGc()

  poll()

  tearDownForeignThreadGc()

proc nimbus_join_public_chat(channel: cstring,
                             handler: proc (msg: ptr CReceivedMessage)
                             {.gcsafe, cdecl.}) {.exportc.} =
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

  tearDownForeignThreadGc()

# TODO: Add signing key as parameter
# TODO: How would we do key management? In nimbus (like in rpc) or in status go?
proc nimbus_post_public(channel: cstring, payload: cstring) {.exportc.} =
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

  tearDownForeignThreadGc()

proc nimbus_add_peer(nodeId: cstring) {.exportc.} =
  setupForeignThreadGc()

  var whisperENode: ENode
  discard initENode($nodeId, whisperENode)
  var whisperNode = newNode(whisperENode)

  asyncCheck node.peerPool.connectToNode(whisperNode)

  tearDownForeignThreadGc()

# Whisper API (Similar to Whisper RPC API)
# Mostly an example for now, lots of things to fix if continued like this.

proc nimbus_string_to_topic(s: cstring): CTopic {.exportc.} =
  setupForeignThreadGc()

  let hash = digest(keccak256, $s)
  for i in 0..<4:
    result.topic[i] = hash.data[i]

  tearDownForeignThreadGc()

# Asymmetric Keys API

proc nimbus_new_keypair(): cstring {.exportc,foreignThreadGc.} =
  ## It is important that the caller makes a copy of the returned cstring before
  ## doing any other API calls.
  result = generateRandomID()
  whisperKeys.asymKeys.add($result, newKeyPair())

proc nimbus_add_keypair(key: ptr PrivateKey):
    cstring {.exportc,foreignThreadGc.} =
  ## It is important that the caller makes a copy of the returned cstring before
  ## doing any other API calls.
  result = generateRandomID()

  # Creating a KeyPair here does a copy of the key and so does the add
  whisperKeys.asymKeys.add($result, KeyPair(seckey: key[],
    pubkey: key[].getPublicKey()))

proc nimbus_delete_keypair(id: cstring): bool {.exportc,foreignThreadGc.} =
  var unneeded: KeyPair
  result = whisperKeys.asymKeys.take($id, unneeded)

proc nimbus_get_private_key(id: cstring, privateKey: ptr PrivateKey):
    bool {.exportc,foreignThreadGc.} =
  try:
    privateKey[] = whisperKeys.asymkeys[$id].seckey
    result = true
  except KeyError:
    result = false

# Symmetric Keys API

proc nimbus_add_symkey(key: ptr SymKey): cstring {.exportc,foreignThreadGc.} =
  ## It is important that the caller makes a copy of the returned cstring before
  ## doing any other API calls.
  result = generateRandomID().cstring

  # Copy of key happens at add
  whisperKeys.symKeys.add($result, key[])

proc nimbus_add_symkey_from_password(password: cstring):
    cstring {.exportc,foreignThreadGc.} =
  ## It is important that the caller makes a copy of the returned cstring before
  ## doing any other API calls.
  var ctx: HMAC[sha256]
  var symKey: SymKey
  if pbkdf2(ctx, $password, "", 65356, symKey) != sizeof(SymKey):
    return nil # TODO: Something else than nil? And, can this practically occur?

  result = generateRandomID()

  whisperKeys.symKeys.add($result, symKey)

proc nimbus_delete_symkey(id: cstring): bool {.exportc,foreignThreadGc.} =
  var unneeded: SymKey
  result = whisperKeys.symKeys.take($id, unneeded)

proc nimbus_get_symkey(id: cstring, symKey: ptr SymKey):
    bool {.exportc,foreignThreadGc.} =
  try:
    symKey[] = whisperKeys.symkeys[$id]
    result = true
  except KeyError:
    result = false

# Whisper message posting and receiving API

proc nimbus_post(message: ptr CPostMessage): bool {.exportc,foreignThreadGc.} =
  ## Encryption is not mandatory.
  ## A symKey, an asymKey, or nothing can be provided. asymKey has precedence.
  ## Providing a payload is mandatory.
  var
    sigPrivKey: Option[PrivateKey]
    asymKey: Option[PublicKey]
    symKey: Option[SymKey]
    padding: Option[Bytes]
    payload: Bytes

  if not message.pubKey.isNil():
    asymKey = some(message.pubKey[])

  try:
    if not message.symKeyID.isNil():
      symKey = some(whisperKeys.symKeys[$message.symKeyID])
    if not message.sourceID.isNil():
      sigPrivKey = some(whisperKeys.asymKeys[$message.sourceID].seckey)
  except KeyError:
    return false

  if not message.payload.isNil():
    # TODO: Is this cast OK?
    payload = cast[Bytes]($message.payload)
  else:
    return false

  if not message.padding.isNil():
    padding = some(cast[Bytes]($message.padding))

  result = node.postMessage(asymKey,
                            symKey,
                            sigPrivKey,
                            ttl = message.ttl,
                            topic = message.topic,
                            payload = payload,
                            padding = padding,
                            powTime = message.powTime,
                            powTarget = message.powTarget)

proc nimbus_subscribe_filter(options: ptr CFilterOptions,
    handler: proc (msg: ptr CReceivedMessage) {.gcsafe, cdecl.}):
    cstring {.exportc, foreignThreadGc.} =
  ## In case of a passed handler, the received msg needs to be copied before the
  ## handler ends.
  ## TODO: provide some user context passing here else this is rather useless?
  var filter: Filter
  if not options.source.isNil():
    filter.src = some(options.source[])

  try:
    if not options.symKeyID.isNil():
      filter.symKey= some(whisperKeys.symKeys[$options.symKeyID])
    if not options.privateKeyID.isNil():
      filter.privateKey= some(whisperKeys.asymKeys[$options.privateKeyID].seckey)
  except KeyError:
    return nil

  filter.powReq = options.minPow
  filter.topics = @[options.topic]
  filter.allowP2P = options.allowP2P

  if handler.isNil:
    result = node.subscribeFilter(filter, nil)
  else:
    proc c_handler(msg: ReceivedMessage) {.gcsafe.} =
      var cmsg = CReceivedMessage(
        decoded: unsafeAddr msg.decoded.payload[0],
        decodedLen: csize msg.decoded.payload.len(),
        timestamp: msg.timestamp,
        ttl: msg.ttl,
        topic: msg.topic,
        pow: msg.pow,
        hash: msg.hash
      )

      # TODO: change this to ptr, so that C/go code can check on nil?
      if msg.decoded.src.isSome():
        cmsg.source = msg.decoded.src.get()
      if msg.dst.isSome():
        cmsg.recipientPublicKey = msg.decoded.src.get()

      handler(addr cmsg)

    result = node.subscribeFilter(filter, c_handler)

proc nimbus_unsubscribe_filter(id: cstring): bool {.exportc.} =
  result = node.unsubscribeFilter($id)
