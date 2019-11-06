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
  stew/ranges/ptr_arith, eth/[keys, rlp, p2p, async_utils],
  eth/p2p/rlpx_protocols/whisper_protocol,
  eth/p2p/[enode, peer_pool, bootnodes, whispernodes]

# TODO: If we really want/need this type of API for the keys, put it somewhere
# seperate as it is the same code for Whisper RPC
type
  WhisperKeys* = ref object
    asymKeys*: Table[string, KeyPair]
    symKeys*: Table[string, SymKey]

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
    source*: ref PublicKey
    recipientPublicKey*: ref PublicKey
    timestamp*: uint32
    ttl*: uint32
    topic*: Topic
    pow*: float64
    hash*: Hash

  CFilterOptions* = object
    symKeyID*: cstring
    privateKeyID*: cstring
    source*: ptr byte
    minPow*: float64
    topic*: Topic # lets go with one topic for now
    allowP2P*: bool

  CPostMessage* = object
    symKeyID*: cstring
    pubKey*: ptr byte
    sourceID*: cstring
    ttl*: uint32
    topic*: Topic
    payload*: ptr byte
    payloadLen*: csize
    padding*: ptr byte
    paddingLen*: csize
    powTime*: float64
    powTarget*: float64

  CTopic* = object
    topic*: Topic

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

proc setBootNodes(nodes: openArray[string]): seq[ENode] =
  var bootnode: ENode
  result = newSeqOfCap[ENode](nodes.len)
  for nodeId in nodes:
    # For now we can just do assert as we only pass our own const arrays.
    doAssert(initENode(nodeId, bootnode) == ENodeStatus.Success)
    result.add(bootnode)

proc connectToNodes(nodes: openArray[string]) =
  for nodeId in nodes:
    var whisperENode: ENode
    # For now we can just do assert as we only pass our own const arrays.
    doAssert(initENode(nodeId, whisperENode) == ENodeStatus.Success)

    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))

proc nimbus_start(port: uint16, startListening: bool, enableDiscovery: bool,
  minPow: float64, privateKey: ptr byte, staging: bool): bool {.exportc.} =
  # TODO: any async calls can still create `Exception`, why?
  let address = Address(
    udpPort: port.Port, tcpPort: port.Port, ip: parseIpAddress("0.0.0.0"))

  var keypair: KeyPair
  if privateKey.isNil:
    keypair = newKeyPair()
  else:
    try:
      let privKey = initPrivateKey(makeOpenArray(privateKey, 32))
      keypair = KeyPair(seckey: privKey, pubkey: privKey.getPublicKey())
    except EthKeysException:
      error "Passed an invalid privateKey"
      return false

  node = newEthereumNode(keypair, address, 1, nil, addAllCapabilities = false)
  node.addCapability Whisper

  node.protocolState(Whisper).config.powRequirement = minPow
  # TODO: should we start the node with an empty bloomfilter?
  # var bloom: Bloom
  # node.protocolState(Whisper).config.bloom = bloom

  let bootnodes = if staging: setBootNodes(StatusBootNodesStaging)
                  else: setBootNodes(StatusBootNodes)

  traceAsyncErrors node.connectToNetwork(bootnodes, startListening,
    enableDiscovery)

  # Connect to known Status Whisper fleet directly
  if staging: connectToNodes(WhisperNodesStaging)
  else: connectToNodes(WhisperNodes)

  result = true

proc nimbus_poll() {.exportc.} =
  poll()

proc nimbus_join_public_chat(channel: cstring,
                             handler: proc (msg: ptr CReceivedMessage)
                             {.gcsafe, cdecl.}) {.exportc.} =
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
proc nimbus_post_public(channel: cstring, payload: cstring) {.exportc.} =
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

proc nimbus_add_peer(nodeId: cstring): bool {.exportc.} =
  var
    whisperENode: ENode
    whisperNode: Node
  discard initENode($nodeId, whisperENode)
  try:
    whisperNode = newNode(whisperENode)
  except Secp256k1Exception:
    return false

  # TODO: call can create `Exception`, why?
  traceAsyncErrors node.peerPool.connectToNode(whisperNode)
  result = true

# Whisper API (Similar to Whisper RPC API)
# Mostly an example for now, lots of things to fix if continued like this.

proc nimbus_channel_to_topic(channel: cstring): CTopic {.exportc, raises: [].} =
  doAssert(not channel.isNil, "channel cannot be nil")

  let hash = digest(keccak256, $channel)
  for i in 0..<4:
    result.topic[i] = hash.data[i]

# Asymmetric Keys API

proc nimbus_new_keypair(): cstring {.exportc, raises: [].} =
  ## It is important that the caller makes a copy of the returned cstring before
  ## doing any other API calls. This might not hold for all types of GC.
  result = generateRandomID()
  try:
    whisperKeys.asymKeys.add($result, newKeyPair())
  except Secp256k1Exception:
    # Don't think this can actually happen, comes from the `getPublicKey` part
    # in `newKeyPair`
    result = ""

proc nimbus_add_keypair(privateKey: ptr byte):
    cstring {.exportc, raises: [OSError, IOError, ValueError].} =
  ## It is important that the caller makes a copy of the returned cstring before
  ## doing any other API calls. This might not hold for all types of GC.
  doAssert(not privateKey.isNil, "Passed a null pointer as privateKey")

  var keypair: KeyPair
  try:
    keypair.seckey = initPrivateKey(makeOpenArray(privateKey, 32))
    keypair.pubkey = keypair.seckey.getPublicKey()
  except EthKeysException, Secp256k1Exception:
    error "Passed an invalid privateKey"
    return ""

  result = generateRandomID()
  whisperKeys.asymKeys.add($result, keypair)

proc nimbus_delete_keypair(id: cstring): bool {.exportc, raises: [].} =
  doAssert(not id.isNil, "Key id cannot be nil")

  var unneeded: KeyPair
  result = whisperKeys.asymKeys.take($id, unneeded)

proc nimbus_get_private_key(id: cstring, privateKey: ptr PrivateKey):
    bool {.exportc, raises: [OSError, IOError, ValueError].} =
  doAssert(not id.isNil, "Key id cannot be nil")
  doAssert(not privateKey.isNil, "Passed a null pointer as privateKey")

  try:
    privateKey[] = whisperKeys.asymkeys[$id].seckey
    result = true
  except KeyError:
    error "Private key not found"
    result = false

# Symmetric Keys API

proc nimbus_add_symkey(symKey: ptr SymKey): cstring {.exportc, raises: [].} =
  ## It is important that the caller makes a copy of the returned cstring before
  ## doing any other API calls. This might not hold for all types of GC.
  doAssert(not symKey.isNil, "Passed a null pointer as symKey")

  result = generateRandomID().cstring

  # Copy of key happens at add
  whisperKeys.symKeys.add($result, symKey[])

proc nimbus_add_symkey_from_password(password: cstring):
    cstring {.exportc, raises: [].} =
  ## It is important that the caller makes a copy of the returned cstring before
  ## doing any other API calls. This might not hold for all types of GC.
  doAssert(not password.isNil, "password can not be nil")

  var ctx: HMAC[sha256]
  var symKey: SymKey
  if pbkdf2(ctx, $password, "", 65356, symKey) != sizeof(SymKey):
    return nil # TODO: Something else than nil? And, can this practically occur?

  result = generateRandomID()

  whisperKeys.symKeys.add($result, symKey)

proc nimbus_delete_symkey(id: cstring): bool {.exportc, raises: [].} =
  doAssert(not id.isNil, "Key id cannot be nil")

  var unneeded: SymKey
  result = whisperKeys.symKeys.take($id, unneeded)

proc nimbus_get_symkey(id: cstring, symKey: ptr SymKey):
    bool {.exportc, raises: [].} =
  doAssert(not id.isNil, "Key id cannot be nil")
  doAssert(not symKey.isNil, "Passed a null pointer as symKey")

  try:
    symKey[] = whisperKeys.symkeys[$id]
    result = true
  except KeyError:
    result = false

# Whisper message posting and receiving API

proc nimbus_post(message: ptr CPostMessage): bool {.exportc.} =
  ## Encryption is mandatory.
  ## A symmetric key or an asymmetric key must be provided. Both is not allowed.
  ## Providing a payload is mandatory, it cannot be nil, but can be of length 0.
  doAssert(not message.isNil, "Message pointer cannot be nil")

  var
    sigPrivKey: Option[PrivateKey]
    asymKey: Option[PublicKey]
    symKey: Option[SymKey]
    padding: Option[Bytes]
    payload: Bytes

  if not message.pubKey.isNil() and not message.symKeyID.isNil():
    warn "Both symmetric and asymmetric keys are provided, choose one."
    return false

  if message.pubKey.isNil() and message.symKeyID.isNil():
    warn "Both symmetric and asymmetric keys are nil, provide one."
    return false

  if not message.pubKey.isNil():
    try:
      asymKey = some(initPublicKey(makeOpenArray(message.pubKey, 64)))
    except EthKeysException:
      error "Passed an invalid public key for encryption"
      return false

  try:
    if not message.symKeyID.isNil():
      symKey = some(whisperKeys.symKeys[$message.symKeyID])
    if not message.sourceID.isNil():
      sigPrivKey = some(whisperKeys.asymKeys[$message.sourceID].seckey)
  except KeyError:
    warn "No key found with provided key ID."
    return false

  if not message.payload.isNil():
    # This will make a copy
    payload = @(makeOpenArray(message.payload, message.payloadLen))
  else:
    warn "Message payload was nil, post aborted."
    return false

  if not message.padding.isNil():
    # This will make a copy
    padding = some(@(makeOpenArray(message.padding, message.paddingLen)))

  # TODO: call can create `Exception`, why?
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
    handler: proc (msg: ptr CReceivedMessage, udata: pointer) {.gcsafe, cdecl.},
    udata: pointer = nil): cstring {.exportc.} =
  ## Encryption is mandatory.
  ## A symmetric key or an asymmetric key must be provided. Both is not allowed.
  ## In case of a passed handler, the received msg needs to be copied before the
  ## handler ends.
  doAssert(not options.isNil, "Options pointer cannot be nil")

  var
    src: Option[PublicKey]
    symKey: Option[SymKey]
    privateKey: Option[PrivateKey]

  if not options.privateKeyID.isNil() and not options.symKeyID.isNil():
    warn "Both symmetric and asymmetric keys are provided, choose one."
    return ""

  if options.privateKeyID.isNil() and options.symKeyID.isNil():
    warn "Both symmetric and asymmetric keys are nil, provide one."
    return ""

  if not options.source.isNil():
    try:
      src = some(initPublicKey(makeOpenArray(options.source, 64)))
    except EthKeysException:
      error "Passed an invalid public key as source"
      return ""

  try:
    if not options.symKeyID.isNil():
      symKey = some(whisperKeys.symKeys[$options.symKeyID])
    if not options.privateKeyID.isNil():
      privateKey = some(whisperKeys.asymKeys[$options.privateKeyID].seckey)
  except KeyError:
    return ""

  let filter = newFilter(src, privateKey, symKey, @[options.topic],
    options.minPow, options.allowP2P)

  if handler.isNil:
    # TODO: call can create `Exception`, why?
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

      # Should be GCed when handler goes out of scope
      var
        source: ref PublicKey
        recipientPublicKey: ref PublicKey
      if msg.decoded.src.isSome():
        new(source)
        source[] = msg.decoded.src.get()
        cmsg.source = source
      if msg.dst.isSome():
        new(recipientPublicKey)
        recipientPublicKey[] = msg.dst.get()
        cmsg.recipientPublicKey = recipientPublicKey

      handler(addr cmsg, udata)

    # TODO: call can create `Exception`, why?
    result = node.subscribeFilter(filter, c_handler)

  # Bloom filter has to follow only the subscribed topics
  # TODO: better to have an "adding" proc here
  # TODO: call can create `Exception`, why?
  traceAsyncErrors node.setBloomFilter(node.filtersToBloom())

proc nimbus_unsubscribe_filter(id: cstring): bool {.exportc, raises: [].} =
  doAssert(not id.isNil, "Filter id cannot be nil")

  result = node.unsubscribeFilter($id)

proc nimbus_get_min_pow(): float64 {.exportc, raises: [].} =
  result = node.protocolState(Whisper).config.powRequirement

proc nimbus_get_bloom_filter(bloom: ptr Bloom) {.exportc, raises: [].} =
  doAssert(not bloom.isNil, "Bloom pointer cannot be nil")

  bloom[] = node.protocolState(Whisper).config.bloom
