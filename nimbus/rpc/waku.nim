import
  json_rpc/rpcserver, tables, options, sequtils,
  eth/[common, rlp, keys, p2p], eth/p2p/rlpx_protocols/waku_protocol,
  nimcrypto/[sysrand, hmac, sha2, pbkdf2],
  rpc_types, hexstrings, key_storage

from stew/byteutils import hexToSeqByte, hexToByteArray

# Blatant copy of Whisper RPC but for the Waku protocol

proc setupWakuRPC*(node: EthereumNode, keys: KeyStorage, rpcsrv: RpcServer) =

  rpcsrv.rpc("waku_version") do() -> string:
    ## Returns string of the current whisper protocol version.
    result = wakuVersionStr

  rpcsrv.rpc("waku_info") do() -> WhisperInfo:
    ## Returns diagnostic information about the whisper node.
    let config = node.protocolState(Waku).config
    result = WhisperInfo(minPow: config.powRequirement,
                         maxMessageSize: config.maxMsgSize,
                         memory: 0,
                         messages: 0)

  # TODO: uint32 instead of uint64 is OK here, but needs to be added in json_rpc
  rpcsrv.rpc("waku_setMaxMessageSize") do(size: uint64) -> bool:
    ## Sets the maximal message size allowed by this node.
    ## Incoming and outgoing messages with a larger size will be rejected.
    ## Whisper message size can never exceed the limit imposed by the underlying
    ## P2P protocol (10 Mb).
    ##
    ## size: Message size in bytes.
    ##
    ## Returns true on success and an error on failure.
    result = node.setMaxMessageSize(size.uint32)
    if not result:
      raise newException(ValueError, "Invalid size")

  rpcsrv.rpc("waku_setMinPoW") do(pow: float) -> bool:
    ## Sets the minimal PoW required by this node.
    ##
    ## pow: The new PoW requirement.
    ##
    ## Returns true on success and an error on failure.
    # Note: `setPowRequirement` does not raise on failures of sending the update
    # to the peers. Hence in theory this should not causes errors.
    await node.setPowRequirement(pow)
    result = true

  # TODO: change string in to ENodeStr with extra checks
  rpcsrv.rpc("waku_markTrustedPeer") do(enode: string) -> bool:
    ## Marks specific peer trusted, which will allow it to send historic
    ## (expired) messages.
    ## Note: This function is not adding new nodes, the node needs to exists as
    ## a peer.
    ##
    ## enode: Enode of the trusted peer.
    ##
    ## Returns true on success and an error on failure.
    # TODO: It will now require an enode://pubkey@ip:port uri
    # could also accept only the pubkey (like geth)?
    let peerNode = newNode(enode)
    result = node.setPeerTrusted(peerNode.id)
    if not result:
      raise newException(ValueError, "Not a peer")

  rpcsrv.rpc("waku_newKeyPair") do() -> Identifier:
    ## Generates a new public and private key pair for message decryption and
    ## encryption.
    ##
    ## Returns key identifier on success and an error on failure.
    result = generateRandomID().Identifier
    keys.asymKeys.add(result.string, newKeyPair())

  rpcsrv.rpc("waku_addPrivateKey") do(key: PrivateKey) -> Identifier:
    ## Stores the key pair, and returns its ID.
    ##
    ## key: Private key as hex bytes.
    ##
    ## Returns key identifier on success and an error on failure.
    result = generateRandomID().Identifier

    keys.asymKeys.add(result.string, key.toKeyPair().tryGet())

  rpcsrv.rpc("waku_deleteKeyPair") do(id: Identifier) -> bool:
    ## Deletes the specifies key if it exists.
    ##
    ## id: Identifier of key pair
    ##
    ## Returns true on success and an error on failure.
    var unneeded: KeyPair
    result = keys.asymKeys.take(id.string, unneeded)
    if not result:
      raise newException(ValueError, "Invalid key id")

  rpcsrv.rpc("waku_hasKeyPair") do(id: Identifier) -> bool:
    ## Checks if the whisper node has a private key of a key pair matching the
    ## given ID.
    ##
    ## id: Identifier of key pair
    ##
    ## Returns (true or false) on success and an error on failure.
    result = keys.asymkeys.hasKey(id.string)

  rpcsrv.rpc("waku_getPublicKey") do(id: Identifier) -> PublicKey:
    ## Returns the public key for identity ID.
    ##
    ## id: Identifier of key pair
    ##
    ## Returns public key on success and an error on failure.
    # Note: key not found exception as error in case not existing
    result = keys.asymkeys[id.string].pubkey

  rpcsrv.rpc("waku_getPrivateKey") do(id: Identifier) -> PrivateKey:
    ## Returns the private key for identity ID.
    ##
    ## id: Identifier of key pair
    ##
    ## Returns private key on success and an error on failure.
    # Note: key not found exception as error in case not existing
    result = keys.asymkeys[id.string].seckey

  rpcsrv.rpc("waku_newSymKey") do() -> Identifier:
    ## Generates a random symmetric key and stores it under an ID, which is then
    ## returned. Can be used encrypting and decrypting messages where the key is
    ## known to both parties.
    ##
    ## Returns key identifier on success and an error on failure.
    result = generateRandomID().Identifier
    var key: SymKey
    if randomBytes(key) != key.len:
      raise newException(KeyGenerationError, "Failed generating key")

    keys.symKeys.add(result.string, key)


  rpcsrv.rpc("waku_addSymKey") do(key: SymKey) -> Identifier:
    ## Stores the key, and returns its ID.
    ##
    ## key: The raw key for symmetric encryption as hex bytes.
    ##
    ## Returns key identifier on success and an error on failure.
    result = generateRandomID().Identifier

    keys.symKeys.add(result.string, key)

  rpcsrv.rpc("waku_generateSymKeyFromPassword") do(password: string) -> Identifier:
    ## Generates the key from password, stores it, and returns its ID.
    ##
    ## password: Password.
    ##
    ## Returns key identifier on success and an error on failure.
    ## Warning: an empty string is used as salt because the shh RPC API does not
    ## allow for passing a salt. A very good password is necessary (calculate
    ## yourself what that means :))
    var ctx: HMAC[sha256]
    var symKey: SymKey
    if pbkdf2(ctx, password, "", 65356, symKey) != sizeof(SymKey):
      raise newException(KeyGenerationError, "Failed generating key")

    result = generateRandomID().Identifier
    keys.symKeys.add(result.string, symKey)

  rpcsrv.rpc("waku_hasSymKey") do(id: Identifier) -> bool:
    ## Returns true if there is a key associated with the name string.
    ## Otherwise, returns false.
    ##
    ## id: Identifier of key.
    ##
    ## Returns (true or false) on success and an error on failure.
    result = keys.symkeys.hasKey(id.string)

  rpcsrv.rpc("waku_getSymKey") do(id: Identifier) -> SymKey:
    ## Returns the symmetric key associated with the given ID.
    ##
    ## id: Identifier of key.
    ##
    ## Returns Raw key on success and an error on failure.
    # Note: key not found exception as error in case not existing
    result = keys.symkeys[id.string]

  rpcsrv.rpc("waku_deleteSymKey") do(id: Identifier) -> bool:
    ## Deletes the key associated with the name string if it exists.
    ##
    ## id: Identifier of key.
    ##
    ## Returns (true or false) on success and an error on failure.
    var unneeded: SymKey
    result = keys.symKeys.take(id.string, unneeded)
    if not result:
      raise newException(ValueError, "Invalid key id")

  rpcsrv.rpc("waku_subscribe") do(id: string,
                                 options: WhisperFilterOptions) -> Identifier:
    ## Creates and registers a new subscription to receive notifications for
    ## inbound whisper messages. Returns the ID of the newly created
    ## subscription.
    ##
    ## id: identifier of function call. In case of Whisper must contain the
    ## value "messages".
    ## options: WhisperFilterOptions
    ##
    ## Returns the subscription ID on success, the error on failure.

    # TODO: implement subscriptions, only for WS & IPC?
    discard

  rpcsrv.rpc("waku_unsubscribe") do(id: Identifier) -> bool:
    ## Cancels and removes an existing subscription.
    ##
    ## id: Subscription identifier
    ##
    ## Returns true on success, the error on failure
    result  = node.unsubscribeFilter(id.string)
    if not result:
      raise newException(ValueError, "Invalid filter id")

  proc validateOptions[T,U,V](asym: Option[T], sym: Option[U], topic: Option[V]) =
    if (asym.isSome() and sym.isSome()) or (asym.isNone() and sym.isNone()):
      raise newException(ValueError,
                         "Either privateKeyID/pubKey or symKeyID must be present")
    if asym.isNone() and topic.isNone():
      raise newException(ValueError, "Topic mandatory with symmetric key")

  rpcsrv.rpc("waku_newMessageFilter") do(options: WhisperFilterOptions) -> Identifier:
    ## Create a new filter within the node. This filter can be used to poll for
    ## new messages that match the set of criteria.
    ##
    ## options: WhisperFilterOptions
    ##
    ## Returns filter identifier on success, error on failure

    # Check if either symKeyID or privateKeyID is present, and not both
    # Check if there are Topics when symmetric key is used
    validateOptions(options.privateKeyID, options.symKeyID, options.topics)

    var
      src: Option[PublicKey]
      privateKey: Option[PrivateKey]
      symKey: Option[SymKey]
      topics: seq[waku_protocol.Topic]
      powReq: float64
      allowP2P: bool

    src = options.sig

    if options.privateKeyID.isSome():
      privateKey = some(keys.asymKeys[options.privateKeyID.get().string].seckey)

    if options.symKeyID.isSome():
      symKey= some(keys.symKeys[options.symKeyID.get().string])

    if options.minPow.isSome():
      powReq = options.minPow.get()

    if options.topics.isSome():
      topics = options.topics.get()

    if options.allowP2P.isSome():
      allowP2P = options.allowP2P.get()

    let filter = initFilter(src, privateKey, symKey, topics, powReq, allowP2P)
    result = node.subscribeFilter(filter).Identifier

    # TODO: Should we do this here "automatically" or separate it in another
    # RPC call? Is there a use case for that?
    # Same could be said about bloomfilter, except that there is a use case
    # there to have a full node no matter what message filters.
    # Could also be moved to waku_protocol.nim
    let config = node.protocolState(Waku).config
    if config.topics.isSome():
      try:
        # TODO: an addTopics call would probably be more useful
        let result = await node.setTopicInterest(config.topics.get().concat(filter.topics))
        if not result:
          raise newException(ValueError, "Too many topics")
      except CatchableError:
        trace "setTopics error occured"
    elif config.isLightNode:
      try:
        await node.setBloomFilter(node.filtersToBloom())
      except CatchableError:
        trace "setBloomFilter error occured"

  rpcsrv.rpc("waku_deleteMessageFilter") do(id: Identifier) -> bool:
    ## Uninstall a message filter in the node.
    ##
    ## id: Filter identifier as returned when the filter was created.
    ##
    ## Returns true on success, error on failure.
    result = node.unsubscribeFilter(id.string)
    if not result:
      raise newException(ValueError, "Invalid filter id")

  rpcsrv.rpc("waku_getFilterMessages") do(id: Identifier) -> seq[WhisperFilterMessage]:
    ## Retrieve messages that match the filter criteria and are received between
    ## the last time this function was called and now.
    ##
    ## id: ID of filter that was created with `waku_newMessageFilter`.
    ##
    ## Returns array of messages on success and an error on failure.
    let messages = node.getFilterMessages(id.string)
    for msg in messages:
      result.add WhisperFilterMessage(
        sig: msg.decoded.src,
        recipientPublicKey: msg.dst,
        ttl: msg.ttl,
        topic: msg.topic,
        timestamp: msg.timestamp,
        payload: msg.decoded.payload,
        # Note: whisper_protocol padding is an Option as there is the
        # possibility of 0 padding in case of custom padding.
        padding: msg.decoded.padding.get(@[]),
        pow: msg.pow,
        hash: msg.hash)

  rpcsrv.rpc("waku_post") do(message: WhisperPostMessage) -> bool:
    ## Creates a whisper message and injects it into the network for
    ## distribution.
    ##
    ## message: Whisper message to post.
    ##
    ## Returns true on success and an error on failure.

    # Check if either symKeyID or pubKey is present, and not both
    # Check if there is a Topic when symmetric key is used
    validateOptions(message.pubKey, message.symKeyID, message.topic)

    var
      sigPrivKey: Option[PrivateKey]
      symKey: Option[SymKey]
      topic: waku_protocol.Topic
      padding: Option[Bytes]
      targetPeer: Option[NodeId]

    if message.sig.isSome():
      sigPrivKey = some(keys.asymKeys[message.sig.get().string].seckey)

    if message.symKeyID.isSome():
      symKey = some(keys.symKeys[message.symKeyID.get().string])

    # Note: If no topic it will be defaulted to 0x00000000
    if message.topic.isSome():
      topic = message.topic.get()

    if message.padding.isSome():
      padding = some(hexToSeqByte(message.padding.get().string))

    if message.targetPeer.isSome():
      targetPeer = some(newNode(message.targetPeer.get()).id)

    result = node.postMessage(message.pubKey,
                              symKey,
                              sigPrivKey,
                              ttl = message.ttl.uint32,
                              topic = topic,
                              payload = hexToSeqByte(message.payload.string),
                              padding = padding,
                              powTime = message.powTime,
                              powTarget = message.powTarget,
                              targetPeer = targetPeer)
    if not result:
      raise newException(ValueError, "Message could not be posted")
