# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[options, strutils, tables],
  confutils,
  confutils/std/net,
  chronicles,
  chronicles/topics_registry,
  chronos,
  metrics,
  metrics/chronos_httpserver,
  stew/byteutils,
  results,
  nimcrypto/[hash, sha2],
  eth/[common/keys, net/nat],
  eth/p2p/discoveryv5/[enr, node],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../common/common_utils,
  ../database/content_db,
  ../network/wire/[portal_protocol, portal_stream, portal_protocol_config],
  ../network/history/[history_content, history_network]

const
  defaultListenAddress* = (static parseIpAddress("0.0.0.0"))
  defaultAdminListenAddress* = (static parseIpAddress("127.0.0.1"))

  defaultListenAddressDesc = $defaultListenAddress
  defaultAdminListenAddressDesc = $defaultAdminListenAddress
  # 100mb seems a bit smallish we may consider increasing defaults after some
  # network measurements
  defaultStorageSize* = uint32(1000 * 1000 * 100)

type
  PortalCmd* = enum
    noCommand
    ping
    findNodes
    findContent

  PortalCliConf* = object
    logLevel* {.
      defaultValue: LogLevel.DEBUG,
      defaultValueDesc: $LogLevel.DEBUG,
      desc: "Sets the log level",
      name: "log-level"
    .}: LogLevel

    udpPort* {.defaultValue: 9009, desc: "UDP listening port", name: "udp-port".}:
      uint16

    listenAddress* {.
      defaultValue: defaultListenAddress,
      defaultValueDesc: $defaultListenAddressDesc,
      desc: "Listening address for the Discovery v5 traffic",
      name: "listen-address"
    .}: IpAddress

    # Note: This will add bootstrap nodes for both Discovery v5 network and each
    # enabled Portal network. No distinction is made on bootstrap nodes per
    # specific network.
    bootstrapNodes* {.
      desc:
        "ENR URI of node to bootstrap Discovery v5 and the Portal networks from. Argument may be repeated",
      name: "bootstrap-node"
    .}: seq[Record]

    bootstrapNodesFile* {.
      desc:
        "Specifies a line-delimited file of ENR URIs to bootstrap Discovery v5 and Portal networks from",
      defaultValue: "",
      name: "bootstrap-file"
    .}: InputFile

    nat* {.
      desc:
        "Specify method to use for determining public address. " &
        "Must be one of: any, none, upnp, pmp, extip:<IP>",
      defaultValue: NatConfig(hasExtIp: false, nat: NatAny),
      defaultValueDesc: "any",
      name: "nat"
    .}: NatConfig

    enrAutoUpdate* {.
      defaultValue: false,
      desc:
        "Discovery can automatically update its ENR with the IP address " &
        "and UDP port as seen by other nodes it communicates with. " &
        "This option allows to enable/disable this functionality",
      name: "enr-auto-update"
    .}: bool

    networkKey* {.
      desc: "Private key (secp256k1) for the p2p network, hex encoded.",
      defaultValue: PrivateKey.random(keys.newRng()[]),
      defaultValueDesc: "random",
      name: "network-key"
    .}: PrivateKey

    metricsEnabled* {.
      defaultValue: false, desc: "Enable the metrics server", name: "metrics"
    .}: bool

    metricsAddress* {.
      defaultValue: defaultAdminListenAddress,
      defaultValueDesc: $defaultAdminListenAddressDesc,
      desc: "Listening address of the metrics server",
      name: "metrics-address"
    .}: IpAddress

    metricsPort* {.
      defaultValue: 8008,
      desc: "Listening HTTP port of the metrics server",
      name: "metrics-port"
    .}: Port

    protocolId* {.
      defaultValue: getProtocolId(PortalNetwork.mainnet, PortalSubnetwork.history),
      desc: "Portal wire protocol id for the network to connect to",
      name: "protocol-id"
    .}: PortalProtocolId

    # TODO maybe it is worth defining minimal storage size and throw error if
    # value provided is smaller than minimum
    storageSize* {.
      desc:
        "Maximum amount (in bytes) of content which will be stored " &
        "in local database.",
      defaultValue: defaultStorageSize,
      name: "storage-size"
    .}: uint32

    case cmd* {.command, defaultValue: noCommand.}: PortalCmd
    of noCommand:
      discard
    of ping:
      pingTarget* {.
        argument, desc: "ENR URI of the node to a send ping message", name: "node"
      .}: Node
    of findNodes:
      distance* {.
        defaultValue: 255,
        desc: "Distance parameter for the findNodes message",
        name: "distance"
      .}: uint16
      # TODO: Order here matters as else the help message does not show all the
      # information, see: https://github.com/status-im/nim-confutils/issues/15
      findNodesTarget* {.
        argument, desc: "ENR URI of the node to send a findNodes message", name: "node"
      .}: Node
    of findContent:
      findContentTarget* {.
        argument,
        desc: "ENR URI of the node to send a findContent message",
        name: "node"
      .}: Node

proc parseCmdArg*(T: type enr.Record, p: string): T =
  let res = enr.Record.fromURI(p)
  if res.isErr:
    raise newException(ValueError, "Invalid ENR: " & $res.error)

  res.value

proc completeCmdArg*(T: type enr.Record, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type Node, p: string): T =
  let res = enr.Record.fromURI(p)
  if res.isErr:
    raise newException(ValueError, "Invalid ENR: " & $res.error)

  let n = Node.fromRecord(res.value)
  if n.address.isNone():
    raise newException(ValueError, "ENR without address")

  n

proc completeCmdArg*(T: type Node, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type PrivateKey, p: string): T =
  try:
    result = PrivateKey.fromHex(p).tryGet()
  except CatchableError:
    raise newException(ValueError, "Invalid private key")

proc completeCmdArg*(T: type PrivateKey, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type PortalProtocolId, p: string): T =
  try:
    result = byteutils.hexToByteArray(p, 2)
  except ValueError:
    raise newException(ValueError, "Invalid protocol id, not a valid hex value")

proc completeCmdArg*(T: type PortalProtocolId, val: string): seq[string] =
  return @[]

proc discover(d: discv5_protocol.Protocol) {.async.} =
  while true:
    let discovered = await d.queryRandom()
    info "Lookup finished", nodes = discovered.len
    await sleepAsync(30.seconds)

proc testContentIdHandler(contentKey: ContentKeyByteList): results.Opt[ContentId] =
  # Note: Returning a static content id here, as in practice this depends
  # on the content key to content id derivation, which is different for the
  # different content networks. And we want these tests to be independent from
  # that.
  let idHash = sha256.digest("test")
  ok(readUintBE[256](idHash.data))

proc run(config: PortalCliConf) =
  let
    rng = newRng()
    bindIp = config.listenAddress
    udpPort = Port(config.udpPort)
    # TODO: allow for no TCP port mapping!
    (extIp, _, extUdpPort) =
      setupAddress(config.nat, config.listenAddress, udpPort, udpPort, "portalcli")

  var bootstrapRecords: seq[Record]
  loadBootstrapFile(string config.bootstrapNodesFile, bootstrapRecords)
  bootstrapRecords.add(config.bootstrapNodes)

  let d = newProtocol(
    config.networkKey,
    extIp,
    Opt.none(Port),
    extUdpPort,
    bootstrapRecords = bootstrapRecords,
    bindIp = bindIp,
    bindPort = udpPort,
    enrAutoUpdate = config.enrAutoUpdate,
    rng = rng,
  )

  d.open()

  let
    db = ContentDB.new(
      "", config.storageSize, defaultRadiusConfig, d.localNode.id, inMemory = true
    )
    sm = StreamManager.new(d)
    cq = newAsyncQueue[(Opt[NodeId], ContentKeysList, seq[seq[byte]])](50)
    stream = sm.registerNewStream(cq)
    portal = PortalProtocol.new(
      d,
      config.protocolId,
      testContentIdHandler,
      createGetHandler(db),
      createStoreHandler(db, defaultRadiusConfig),
      createContainsHandler(db),
      createRadiusHandler(db),
      stream,
      bootstrapRecords = bootstrapRecords,
    )

  if config.metricsEnabled:
    let
      address = config.metricsAddress
      port = config.metricsPort
      url = "http://" & $address & ":" & $port & "/metrics"

      server = MetricsHttpServerRef.new($address, port).valueOr:
        error "Could not instantiate metrics HTTP server", url, error
        quit QuitFailure

    info "Starting metrics HTTP server", url
    try:
      waitFor server.start()
    except MetricsError as exc:
      fatal "Could not start metrics HTTP server",
        url, error_msg = exc.msg, error_name = exc.name
      quit QuitFailure

  case config.cmd
  of ping:
    let pong = waitFor portal.ping(config.pingTarget)

    if pong.isOk():
      echo pong.get()
    else:
      echo pong.error
  of findNodes:
    let distances = @[config.distance]
    let nodes = waitFor portal.findNodes(config.findNodesTarget, distances)

    if nodes.isOk():
      for node in nodes.get():
        echo $node.record & " - " & shortLog(node)
    else:
      echo nodes.error
  of findContent:
    # For now just some bogus bytes
    let contentKey = ContentKeyByteList.init(@[1'u8])

    let foundContent = waitFor portal.findContent(config.findContentTarget, contentKey)

    if foundContent.isOk():
      echo foundContent.get()
    else:
      echo foundContent.error
  of noCommand:
    d.start()
    portal.start()
    waitFor(discover(d))

when isMainModule:
  let config = PortalCliConf.load()

  setLogLevel(config.logLevel)

  run(config)
