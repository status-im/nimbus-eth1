#
#                 Nimbus
#              (c) Copyright 2019
#       Status Research & Development GmbH
#
#            Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#            MIT license (LICENSE-MIT)

import
  chronos, chronicles, nimcrypto/[utils, hmac, pbkdf2, hash, sysrand], tables,
  stew/ranges/ptr_arith, eth/[keys, rlp, p2p, async_utils],
  eth/p2p/rlpx_protocols/whisper_protocol,
  eth/p2p/[peer_pool, bootnodes, whispernodes], ../nimbus/rpc/key_storage,
  ../nimbus/random_keys

# TODO: lots of overlap with Nimbus Whisper RPC here, however not all
# the same due to type conversion (no use of Option and such). Perhaps some
# parts can be refactored in sharing some of the code.

const idLen = 32

type
  Identifier = array[idLen, byte]

  CReceivedMessage* = object
    decoded*: ptr byte
    decodedLen*: int # csize_t
    source*: ptr byte
    recipientPublicKey*: ptr byte
    timestamp*: uint32
    ttl*: uint32
    topic*: Topic
    pow*: float64
    hash*: Hash

  CFilterOptions* = object
    symKeyID*: ptr byte
    privateKeyID*: ptr byte
    source*: ptr byte
    minPow*: float64
    topic*: Topic # lets go with one topic for now unless more are required
    allowP2P*: bool

  CPostMessage* = object
    symKeyID*: ptr byte
    pubKey*: ptr byte
    sourceID*: ptr byte
    ttl*: uint32
    topic*: Topic
    payload*: ptr byte
    payloadLen*: int # csize_t
    padding*: ptr byte
    paddingLen*: int # csize_t
    powTime*: float64
    powTarget*: float64

  CTopic* = object
    topic*: Topic

# Don't do this at home, you'll never get rid of ugly globals like this!
var
  node: EthereumNode
# You will only add more instead!
let whisperKeys = newKeyStorage()

proc generateRandomID(): Identifier =
  while true: # TODO: error instead of looping?
    if randomBytes(result) == idLen:
      break

proc setBootNodes(nodes: openArray[string]): seq[ENode] =
  result = newSeqOfCap[ENode](nodes.len)
  for nodeId in nodes:
    # For now we can just do assert as we only pass our own const arrays.
    let enode = ENode.fromString(nodeId).expect("correct enode")
    result.add(enode)

proc connectToNodes(nodes: openArray[string]) =
  for nodeId in nodes:
    # For now we can just do assert as we only pass our own const arrays.
    let enode = ENode.fromString(nodeId).expect("correct enode")

    traceAsyncErrors node.peerPool.connectToNode(newNode(enode))

# Setting up the node

proc nimbus_start(port: uint16, startListening: bool, enableDiscovery: bool,
  minPow: float64, privateKey: ptr byte, staging: bool): bool
    {.exportc, dynlib.} =
  # TODO: any async calls can still create `Exception`, why?
  let address = Address(
    udpPort: port.Port, tcpPort: port.Port, ip: parseIpAddress("0.0.0.0"))

  var keypair: KeyPair
  if privateKey.isNil:
    #var kp = KeyPair.random()
    #if kp.isErr:
      #error "Can't generate keypair", err = kp.error
      #return false
    #keypair = kp[]
    keypair = randomKeyPair()
  else:
    let
      privKey = PrivateKey.fromRaw(makeOpenArray(privateKey, 32))
    if privKey.isErr:
      error "Passed an invalid private key."
      return false

    keypair = privKey[].toKeyPair()

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

proc nimbus_poll() {.exportc, dynlib.} =
  poll()

proc nimbus_add_peer(nodeId: cstring): bool {.exportc, dynlib.} =
  var
    whisperNode: Node
  let enode = ENode.fromString($nodeId)
  if enode.isErr:
    return false
  try:
    whisperNode = newNode(enode[])
  except CatchableError:
    return false

  # TODO: call can create `Exception`, why?
  traceAsyncErrors node.peerPool.connectToNode(whisperNode)
  result = true

# Whisper API (Similar to Whisper JSON-RPC API)

proc nimbus_channel_to_topic(channel: cstring): CTopic
    {.exportc, dynlib, raises: [Defect].} =
  # Only used for the example, to conveniently convert channel to topic.
  doAssert(not channel.isNil, "Channel cannot be nil.")

  let hash = digest(keccak256, $channel)
  for i in 0..<4:
    result.topic[i] = hash.data[i]

# Asymmetric Keys

proc nimbus_new_keypair(id: var Identifier): bool
    {.exportc, dynlib, raises: [Defect].} =
  ## Caller needs to provide as id a pointer to 32 bytes allocation.
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")

  id = generateRandomID()
  try:
    whisperKeys.asymKeys.add(id.toHex(), randomKeyPair())
    result = true
  except CatchableError:
    # Don't think this can actually happen, comes from the `getPublicKey` part
    # in `newKeyPair`
    discard

proc nimbus_add_keypair(privateKey: ptr byte, id: var Identifier):
    bool {.exportc, dynlib, raises: [Defect, Exception].} =
  ## Caller needs to provide as id a pointer to 32 bytes allocation.
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")
  doAssert(not privateKey.isNil, "Private key cannot be nil.")

  var keypair: KeyPair
  if privateKey.isNil:
    #var kp = KeyPair.random()
    #if kp.isErr:
      #error "Can't generate keypair", err = kp.error
      #return false
    #keypair = kp[]
    keypair = randomKeyPair()
  else:
    let
      privKey = PrivateKey.fromRaw(makeOpenArray(privateKey, 32))
    if privKey.isErr:
      error "Passed an invalid private key."
      return false

    keypair = privKey[].toKeyPair()

  result = true
  id = generateRandomID()
  whisperKeys.asymKeys.add(id.toHex(), keypair)

proc nimbus_delete_keypair(id: Identifier): bool
    {.exportc, dynlib, raises: [].} =
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")

  var unneeded: KeyPair
  result = whisperKeys.asymKeys.take(id.toHex(), unneeded)

proc nimbus_get_private_key(id: Identifier, privateKey: var PrivateKey):
    bool {.exportc, dynlib, raises: [OSError, IOError, ValueError, Exception].} =
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")
  doAssert(not (unsafeAddr privateKey).isNil, "Private key cannot be nil.")

  try:
    privateKey = whisperKeys.asymkeys[id.toHex()].seckey
    result = true
  except KeyError:
    error "Private key not found."

# Symmetric Keys

proc nimbus_add_symkey(symKey: ptr SymKey, id: var Identifier): bool
    {.exportc, dynlib, raises: [Defect].} =
  ## Caller needs to provide as id a pointer to 32 bytes allocation.
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")
  doAssert(not symKey.isNil, "Symmetric key cannot be nil.")

  id = generateRandomID()
  result = true

  # Copy of key happens at add
  whisperKeys.symKeys.add(id.toHex, symKey[])

proc nimbus_add_symkey_from_password(password: cstring, id: var Identifier):
    bool {.exportc, dynlib, raises: [Defect].} =
  ## Caller needs to provide as id a pointer to 32 bytes allocation.
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")
  doAssert(not password.isNil, "Password cannot be nil.")

  var ctx: HMAC[sha256]
  var symKey: SymKey
  if pbkdf2(ctx, $password, "", 65356, symKey) != sizeof(SymKey):
    return false

  id = generateRandomID()
  result = true

  whisperKeys.symKeys.add(id.toHex(), symKey)

proc nimbus_delete_symkey(id: Identifier): bool
    {.exportc, dynlib, raises: [Defect].} =
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")

  var unneeded: SymKey
  result = whisperKeys.symKeys.take(id.toHex(), unneeded)

proc nimbus_get_symkey(id: Identifier, symKey: var SymKey):
    bool {.exportc, dynlib, raises: [Defect, Exception].} =
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")
  doAssert(not (unsafeAddr symKey).isNil, "Symmetric key cannot be nil.")

  try:
    symKey = whisperKeys.symkeys[id.toHex()]
    result = true
  except KeyError:
    error "Symmetric key not found."

# Whisper message posting and receiving

proc nimbus_post(message: ptr CPostMessage): bool {.exportc, dynlib.} =
  ## Encryption is mandatory.
  ## A symmetric key or an asymmetric key must be provided. Both is not allowed.
  ## Providing a payload is mandatory, it cannot be nil, but can be of length 0.
  doAssert(not message.isNil, "Message pointer cannot be nil.")

  var
    sigPrivKey: Option[PrivateKey]
    asymKey: Option[PublicKey]
    symKey: Option[SymKey]
    padding: Option[seq[byte]]
    payload: seq[byte]

  if not message.pubKey.isNil() and not message.symKeyID.isNil():
    warn "Both symmetric and asymmetric keys are provided, choose one."
    return false

  if message.pubKey.isNil() and message.symKeyID.isNil():
    warn "Both symmetric and asymmetric keys are nil, provide one."
    return false

  if not message.pubKey.isNil():
    let pubkey = PublicKey.fromRaw(makeOpenArray(message.pubKey, 64))
    if pubkey.isErr:
      error "Passed an invalid public key for encryption."
      return false
    asymKey = some(pubkey[])

  try:
    if not message.symKeyID.isNil():
      let symKeyId = makeOpenArray(message.symKeyID, idLen).toHex()
      symKey = some(whisperKeys.symKeys[symKeyId])
    if not message.sourceID.isNil():
      let sourceId = makeOpenArray(message.sourceID, idLen).toHex()
      sigPrivKey = some(whisperKeys.asymKeys[sourceId].seckey)
  except KeyError:
    warn "No key found with provided key id."
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
    udata: pointer = nil, id: var Identifier): bool {.exportc, dynlib.} =
  ## Encryption is mandatory.
  ## A symmetric key or an asymmetric key must be provided. Both is not allowed.
  ## The received message needs to be copied before the passed handler ends.
  doAssert(not (unsafeAddr id).isNil, "Key id cannot be nil.")
  doAssert(not options.isNil, "Filter options pointer cannot be nil.")
  doAssert(not handler.isNil, "Filter handler cannot be nil." )

  var
    src: Option[PublicKey]
    symKey: Option[SymKey]
    privateKey: Option[PrivateKey]

  if not options.privateKeyID.isNil() and not options.symKeyID.isNil():
    warn "Both symmetric and asymmetric keys are provided, choose one."
    return false

  if options.privateKeyID.isNil() and options.symKeyID.isNil():
    warn "Both symmetric and asymmetric keys are nil, provide one."
    return false

  if not options.source.isNil():
    let pubkey = PublicKey.fromRaw(makeOpenArray(options.source, 64))
    if pubkey.isErr:
      error "Passed an invalid public key as source."
      return false
    src = some(pubkey[])

  try:
    if not options.symKeyID.isNil():
      let symKeyId = makeOpenArray(options.symKeyID, idLen).toHex()
      symKey = some(whisperKeys.symKeys[symKeyId])
    if not options.privateKeyID.isNil():
      let privKeyId = makeOpenArray(options.privateKeyID, idLen).toHex()
      privateKey = some(whisperKeys.asymKeys[privKeyId].seckey)
  except KeyError:
    return false

  let filter = initFilter(src, privateKey, symKey, @[options.topic],
    options.minPow, options.allowP2P)

  proc c_handler(msg: ReceivedMessage) {.gcsafe.} =
    var cmsg = CReceivedMessage(
      decoded: unsafeAddr msg.decoded.payload[0],
      decodedLen: msg.decoded.payload.len(),
      timestamp: msg.timestamp,
      ttl: msg.ttl,
      topic: msg.topic,
      pow: msg.pow,
      hash: msg.hash
    )

    # Could also allocate here, but this should stay in scope until handler
    # finishes so it should be fine.
    var
      source: array[RawPublicKeySize, byte]
      recipientPublicKey: array[RawPublicKeySize, byte]
    if msg.decoded.src.isSome():
      # Need to pass the serialized form
      source = msg.decoded.src.get().toRaw()
      cmsg.source = addr source[0]
    if msg.dst.isSome():
      # Need to pass the serialized form
      recipientPublicKey = msg.decoded.src.get().toRaw()
      cmsg.recipientPublicKey = addr recipientPublicKey[0]

    handler(addr cmsg, udata)

  # TODO: call can create `Exception`, why?
  # TODO: if we decide to internally also work with other IDs, we don't need
  # to do this hex conversion back and forth.
  hexToBytes(node.subscribeFilter(filter, c_handler), id)

  # Bloom filter has to follow only the subscribed topics
  # TODO: better to have an "adding" proc here
  # TODO: call can create `Exception`, why?
  traceAsyncErrors node.setBloomFilter(node.filtersToBloom())
  result = true

proc nimbus_unsubscribe_filter(id: Identifier): bool
    {.exportc, dynlib, raises: [].} =
  doAssert(not(unsafeAddr id).isNil, "Filter id cannot be nil.")

  result = node.unsubscribeFilter(id.toHex())

proc nimbus_get_min_pow(): float64 {.exportc, dynlib, raises: [].} =
  result = node.protocolState(Whisper).config.powRequirement

proc nimbus_get_bloom_filter(bloom: var Bloom) {.exportc, dynlib, raises: [].} =
  doAssert(not (unsafeAddr bloom).isNil, "Bloom pointer cannot be nil.")

  bloom = node.protocolState(Whisper).config.bloom

# Nimbus limited Status chat API

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

  discard node.subscribeFilter(initFilter(symKey = some(symKey),
                                         topics = @[topic]),
                                         handler)

proc nimbus_join_public_chat(channel: cstring,
                             handler: proc (msg: ptr CReceivedMessage)
                             {.gcsafe, cdecl.}) {.exportc, dynlib.} =
  if handler.isNil:
    subscribeChannel($channel, nil)
  else:
    proc c_handler(msg: ReceivedMessage) =
      var cmsg = CReceivedMessage(
        decoded: unsafeAddr msg.decoded.payload[0],
        decodedLen: msg.decoded.payload.len(),
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
proc nimbus_post_public(channel: cstring, payload: cstring)
    {.exportc, dynlib.} =
  let encPrivateKey = PrivateKey.fromHex("5dc5381cae54ba3174dc0d46040fe11614d0cc94d41185922585198b4fcef9d3")[]

  var ctx: HMAC[sha256]
  var symKey: SymKey
  var npayload = cast[seq[byte]]($payload)
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
