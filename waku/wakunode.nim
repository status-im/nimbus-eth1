import
  confutils, config, strutils, chronos, json_rpc/rpcserver, metrics,
  chronicles/topics_registry, # TODO: What? Need this for setLoglevel, weird.
  eth/[keys, p2p, async_utils], eth/common/utils, eth/net/nat,
  eth/p2p/[discovery, enode, peer_pool, bootnodes, whispernodes],
  eth/p2p/rlpx_protocols/[whisper_protocol, waku_protocol, waku_bridge],
  ../nimbus/rpc/[waku, wakusim, key_storage]

const clientId = "Nimbus waku node"

let globalListeningAddr = parseIpAddress("0.0.0.0")

proc setBootNodes(nodes: openArray[string]): seq[ENode] =
  result = newSeqOfCap[ENode](nodes.len)
  for nodeId in nodes:
    # TODO: something more user friendly than an expect
    result.add(ENode.fromString(nodeId).expect("correct node"))

proc connectToNodes(node: EthereumNode, nodes: openArray[string]) =
  for nodeId in nodes:
    # TODO: something more user friendly than an assert
    let whisperENode = ENode.fromString(nodeId).expect("correct node")

    traceAsyncErrors node.peerPool.connectToNode(newNode(whisperENode))

proc setupNat(conf: WakuNodeConf): tuple[ip: IpAddress,
                                           tcpPort: Port,
                                           udpPort: Port] =
  # defaults
  result.ip = globalListeningAddr
  result.tcpPort = Port(conf.tcpPort + conf.portsShift)
  result.udpPort = Port(conf.udpPort + conf.portsShift)

  var nat: NatStrategy
  case conf.nat.toLowerAscii():
    of "any":
      nat = NatAny
    of "none":
      nat = NatNone
    of "upnp":
      nat = NatUpnp
    of "pmp":
      nat = NatPmp
    else:
      if conf.nat.startsWith("extip:") and isIpAddress(conf.nat[6..^1]):
        # any required port redirection is assumed to be done by hand
        result.ip = parseIpAddress(conf.nat[6..^1])
        nat = NatNone
      else:
        error "not a valid NAT mechanism, nor a valid IP address", value = conf.nat
        quit(QuitFailure)

  if nat != NatNone:
    let extIP = getExternalIP(nat)
    if extIP.isSome:
      result.ip = extIP.get()
      let extPorts = redirectPorts(tcpPort = result.tcpPort,
                                   udpPort = result.udpPort,
                                   description = clientId)
      if extPorts.isSome:
        (result.tcpPort, result.udpPort) = extPorts.get()

proc run(config: WakuNodeConf) =
  if config.logLevel != LogLevel.NONE:
    setLogLevel(config.logLevel)

  let
    (ip, tcpPort, udpPort) = setupNat(config)
    address = Address(ip: ip, tcpPort: tcpPort, udpPort: udpPort)

  # Set-up node
  var node = newEthereumNode(config.nodekey, address, 1, nil, clientId,
    addAllCapabilities = false)
  if not config.bootnodeOnly:
    node.addCapability Waku # Always enable Waku protocol
    var topicInterest: Option[seq[waku_protocol.Topic]]
    var bloom: Option[Bloom]
    if config.wakuTopicInterest:
      var topics: seq[waku_protocol.Topic]
      topicInterest = some(topics)
    else:
      bloom = some(fullBloom())
    let wakuConfig = WakuConfig(powRequirement: config.wakuPow,
                                bloom: bloom,
                                isLightNode: config.lightNode,
                                maxMsgSize: waku_protocol.defaultMaxMsgSize,
                                topics: topicInterest)
    node.configureWaku(wakuConfig)
    if config.whisper or config.whisperBridge:
      node.addCapability Whisper
      node.protocolState(Whisper).config.powRequirement = 0.002
    if config.whisperBridge:
      node.shareMessageQueue()

  # TODO: Status fleet bootnodes are discv5? That will not work.
  let bootnodes = if config.bootnodes.len > 0: setBootNodes(config.bootnodes)
                  elif config.fleet == prod: setBootNodes(StatusBootNodes)
                  elif config.fleet == staging: setBootNodes(StatusBootNodesStaging)
                  elif config.fleet == test : setBootNodes(StatusBootNodesTest)
                  else: @[]

  traceAsyncErrors node.connectToNetwork(bootnodes, not config.noListen,
    config.discovery)

  if not config.bootnodeOnly:
    # Optionally direct connect with a set of nodes
    if config.staticnodes.len > 0: connectToNodes(node, config.staticnodes)
    elif config.fleet == prod: connectToNodes(node, WhisperNodes)
    elif config.fleet == staging: connectToNodes(node, WhisperNodesStaging)
    elif config.fleet == test: connectToNodes(node, WhisperNodesTest)

  if config.rpc:
    let ta = initTAddress(config.rpcAddress,
      Port(config.rpcPort + config.portsShift))
    var rpcServer = newRpcHttpServer([ta])
    let keys = newKeyStorage()
    setupWakuRPC(node, keys, rpcServer)
    setupWakuSimRPC(node, rpcServer)
    rpcServer.start()

  when defined(insecure):
    if config.metricsServer:
      let
        address = config.metricsServerAddress
        port = config.metricsServerPort + config.portsShift
      info "Starting metrics HTTP server", address, port
      metrics.startHttpServer($address, Port(port))

  if config.logMetrics:
    proc logMetrics(udata: pointer) {.closure, gcsafe.} =
      {.gcsafe.}:
        let
          connectedPeers = connected_peers.value
          validEnvelopes = waku_protocol.valid_envelopes.value
          invalidEnvelopes = waku_protocol.dropped_expired_envelopes.value +
            waku_protocol.dropped_from_future_envelopes.value +
            waku_protocol.dropped_low_pow_envelopes.value +
            waku_protocol.dropped_too_large_envelopes.value +
            waku_protocol.dropped_bloom_filter_mismatch_envelopes.value +
            waku_protocol.dropped_topic_mismatch_envelopes.value +
            waku_protocol.dropped_benign_duplicate_envelopes.value +
            waku_protocol.dropped_duplicate_envelopes.value

      info "Node metrics", connectedPeers, validEnvelopes, invalidEnvelopes
      addTimer(Moment.fromNow(2.seconds), logMetrics)
    addTimer(Moment.fromNow(2.seconds), logMetrics)

  runForever()

when isMainModule:
  let conf = WakuNodeConf.load()
  run(conf)
