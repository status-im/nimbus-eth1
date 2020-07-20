import
  json_rpc/rpcserver, tables, options,
  eth/[common, rlp, keys, p2p], eth/p2p/rlpx_protocols/whisper_protocol,
  nimcrypto/[sysrand, hmac, sha2, pbkdf2],
  rpc_types, hexstrings, key_storage, ../random_keys

from stew/byteutils import hexToSeqByte, hexToByteArray

template generateRandomID*(): string =
  generateRandomID(getRNG()[])

# Whisper RPC implemented mostly as in
# https://github.com/ethereum/go-ethereum/wiki/Whisper-v6-RPC-API

proc setupWhisperRPC*(node: EthereumNode, keys: KeyStorage, rpcsrv: RpcServer) =

  rpcsrv.rpc("shh_version") do() -> string:
    ## Returns string of the current whisper protocol version.
    result = whisperVersionStr

  rpcsrv.rpc("shh_info") do() -> WhisperInfo:
    ## Returns diagnostic information about the whisper node.
    let config = node.protocolState(Whisper).config
    result = WhisperInfo(minPow: config.powRequirement,
                         maxMessageSize: config.maxMsgSize,
                         memory: 0,
                         messages: 0)

  # TODO: uint32 instead of uint64 is OK here, but needs to be added in json_rpc
  rpcsrv.rpc("shh_setMaxMessageSize") do(size: uint64) -> bool:
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

  rpcsrv.rpc("shh_setMinPoW") do(pow: float) -> bool:
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
  rpcsrv.rpc("shh_markTrustedPeer") do(enode: string) -> bool:
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

  rpcsrv.rpc("shh_newKeyPair") do() -> Identifier:
    ## Generates a new public and private key pair for message decryption and
    ## encryption.
    ##
    ## Returns key identifier on success and an error on failure.
    result = generateRandomID().Identifier
    keys.asymKeys.add(result.string, randomKeyPair())

  rpcsrv.rpc("shh_addPrivateKey") do(key: PrivateKey) -> Identifier:
    ## Stores the key pair, and returns its ID.
    ##
    ## key: Private key as hex bytes.
    ##
    ## Returns key identifier on success and an error on failure.
    result = generateRandomID().Identifier

    keys.asymKeys.add(result.string, key.toKeyPair())

  rpcsrv.rpc("shh_deleteKeyPair") do(id: Identifier) -> bool:
    ## Deletes the specifies key if it exists.
    ##
    ## id: Identifier of key pair
    ##
    ## Returns true on success and an error on failure.
    var unneeded: KeyPair
    result = keys.asymKeys.take(id.string, unneeded)
    if not result:
      raise newException(ValueError, "Invalid key id")

  rpcsrv.rpc("shh_hasKeyPair") do(id: Identifier) -> bool:
    ## Checks if the whisper node has a private key of a key pair matching the
    ## given ID.
    ##
    ## id: Identifier of key pair
    ##
    ## Returns (true or false) on success and an error on failure.
    result = keys.asymkeys.hasKey(id.string)

  rpcsrv.rpc("shh_getPublicKey") do(id: Identifier) -> PublicKey:
    ## Returns the public key for identity ID.
    ##
    ## id: Identifier of key pair
    ##
    ## Returns public key on success and an error on failure.
    # Note: key not found exception as error in case not existing
    result = keys.asymkeys[id.string].pubkey

  rpcsrv.rpc("shh_getPrivateKey") do(id: Identifier) -> PrivateKey:
    ## Returns the private key for identity ID.
    ##
    ## id: Identifier of key pair
    ##
    ## Returns private key on success and an error on failure.
    # Note: key not found exception as error in case not existing
    result = keys.asymkeys[id.string].seckey

  rpcsrv.rpc("shh_newSymKey") do() -> Identifier:
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


  rpcsrv.rpc("shh_addSymKey") do(key: SymKey) -> Identifier:
    ## Stores the key, and returns its ID.
    ##
    ## key: The raw key for symmetric encryption as hex bytes.
    ##
    ## Returns key identifier on success and an error on failure.
    result = generateRandomID().Identifier

    keys.symKeys.add(result.string, key)

  rpcsrv.rpc("shh_generateSymKeyFromPassword") do(password: string) -> Identifier:
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

  rpcsrv.rpc("shh_hasSymKey") do(id: Identifier) -> bool:
    ## Returns true if there is a key associated with the name string.
    ## Otherwise, returns false.
    ##
    ## id: Identifier of key.
    ##
    ## Returns (true or false) on success and an error on failure.
    result = keys.symkeys.hasKey(id.string)

  rpcsrv.rpc("shh_getSymKey") do(id: Identifier) -> SymKey:
    ## Returns the symmetric key associated with the given ID.
    ##
    ## id: Identifier of key.
    ##
    ## Returns Raw key on success and an error on failure.
    # Note: key not found exception as error in case not existing
    result = keys.symkeys[id.string]

  rpcsrv.rpc("shh_deleteSymKey") do(id: Identifier) -> bool:
    ## Deletes the key associated with the name string if it exists.
    ##
    ## id: Identifier of key.
    ##
    ## Returns (true or false) on success and an error on failure.
    var unneeded: SymKey
    result = keys.symKeys.take(id.string, unneeded)
    if not result:
      raise newException(ValueError, "Invalid key id")

  rpcsrv.rpc("shh_subscribe") do(id: string,
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

  rpcsrv.rpc("shh_unsubscribe") do(id: Identifier) -> bool:
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

  rpcsrv.rpc("shh_newMessageFilter") do(options: WhisperFilterOptions) -> Identifier:
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
      topics: seq[whisper_protocol.Topic]
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

  rpcsrv.rpc("shh_deleteMessageFilter") do(id: Identifier) -> bool:
    ## Uninstall a message filter in the node.
    ##
    ## id: Filter identifier as returned when the filter was created.
    ##
    ## Returns true on success, error on failure.
    result = node.unsubscribeFilter(id.string)
    if not result:
      raise newException(ValueError, "Invalid filter id")

  rpcsrv.rpc("shh_getFilterMessages") do(id: Identifier) -> seq[WhisperFilterMessage]:
    ## Retrieve messages that match the filter criteria and are received between
    ## the last time this function was called and now.
    ##
    ## id: ID of filter that was created with `shh_newMessageFilter`.
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

  rpcsrv.rpc("shh_post") do(message: WhisperPostMessage) -> bool:
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
      topic: whisper_protocol.Topic
      padding: Option[seq[byte]]
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
