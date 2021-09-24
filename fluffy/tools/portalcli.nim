# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/[options, strutils, tables],
  confutils, confutils/std/net, chronicles, chronicles/topics_registry,
  chronos, metrics, metrics/chronos_httpserver, stew/byteutils,
  nimcrypto/[hash, sha2],
  eth/[keys, net/nat],
  eth/p2p/discoveryv5/[enr, node],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../network/wire/[messages, portal_protocol],
  ../network/state/state_content

type
  PortalCmd* = enum
    noCommand
    ping
    findnode
    findcontent

  DiscoveryConf* = object
    logLevel* {.
      defaultValue: LogLevel.DEBUG
      desc: "Sets the log level"
      name: "log-level" .}: LogLevel

    udpPort* {.
      defaultValue: 9009
      desc: "UDP listening port"
      name: "udp-port" .}: uint16

    listenAddress* {.
      defaultValue: defaultListenAddress(config)
      desc: "Listening address for the Discovery v5 traffic"
      name: "listen-address" }: ValidIpAddress

    bootnodes* {.
      desc: "ENR URI of node to bootstrap discovery with. Argument may be repeated"
      name: "bootnode" .}: seq[enr.Record]

    nat* {.
      desc: "Specify method to use for determining public address. " &
            "Must be one of: any, none, upnp, pmp, extip:<IP>"
      defaultValue: NatConfig(hasExtIp: false, nat: NatAny)
      name: "nat" .}: NatConfig

    enrAutoUpdate* {.
      defaultValue: false
      desc: "Discovery can automatically update its ENR with the IP address " &
            "and UDP port as seen by other nodes it communicates with. " &
            "This option allows to enable/disable this functionality"
      name: "enr-auto-update" .}: bool

    nodeKey* {.
      desc: "P2P node private key as hex",
      defaultValue: PrivateKey.random(keys.newRng()[])
      name: "nodekey" .}: PrivateKey

    portalBootnodes* {.
      desc: "ENR URI of node to bootstrap the Portal protocol with. Argument may be repeated"
      name: "portal-bootnode" .}: seq[Record]

    metricsEnabled* {.
      defaultValue: false
      desc: "Enable the metrics server"
      name: "metrics" .}: bool

    metricsAddress* {.
      defaultValue: defaultAdminListenAddress(config)
      desc: "Listening address of the metrics server"
      name: "metrics-address" .}: ValidIpAddress

    metricsPort* {.
      defaultValue: 8008
      desc: "Listening HTTP port of the metrics server"
      name: "metrics-port" .}: Port

    case cmd* {.
      command
      defaultValue: noCommand }: PortalCmd
    of noCommand:
      discard
    of ping:
      pingTarget* {.
        argument
        desc: "ENR URI of the node to a send ping message"
        name: "node" .}: Node
    of findnode:
      distance* {.
        defaultValue: 255
        desc: "Distance parameter for the findNode message"
        name: "distance" .}: uint16
      # TODO: Order here matters as else the help message does not show all the
      # information, see: https://github.com/status-im/nim-confutils/issues/15
      findNodeTarget* {.
        argument
        desc: "ENR URI of the node to send a findNode message"
        name: "node" .}: Node
    of findcontent:
      findContentTarget* {.
        argument
        desc: "ENR URI of the node to send a findContent message"
        name: "node" .}: Node

func defaultListenAddress*(conf: DiscoveryConf): ValidIpAddress =
  (static ValidIpAddress.init("0.0.0.0"))

func defaultAdminListenAddress*(conf: DiscoveryConf): ValidIpAddress =
  (static ValidIpAddress.init("127.0.0.1"))

proc parseCmdArg*(T: type enr.Record, p: TaintedString): T =
  if not fromURI(result, p):
    raise newException(ConfigurationError, "Invalid ENR")

proc completeCmdArg*(T: type enr.Record, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type Node, p: TaintedString): T =
  var record: enr.Record
  if not fromURI(record, p):
    raise newException(ConfigurationError, "Invalid ENR")

  let n = newNode(record)
  if n.isErr:
    raise newException(ConfigurationError, $n.error)

  if n[].address.isNone():
    raise newException(ConfigurationError, "ENR without address")

  n[]

proc completeCmdArg*(T: type Node, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type PrivateKey, p: TaintedString): T =
  try:
    result = PrivateKey.fromHex(string(p)).tryGet()
  except CatchableError:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type PrivateKey, val: TaintedString): seq[string] =
  return @[]

proc discover(d: discv5_protocol.Protocol) {.async.} =
  while true:
    let discovered = await d.queryRandom()
    info "Lookup finished", nodes = discovered.len
    await sleepAsync(30.seconds)

proc testHandler(contentKey: state_content.ByteList): ContentResult =
  # Note: We don't incorperate storage in this tool so we always return
  # missing content. For now we are using the state network derivation but it
  # could be selective based on the network the tool is used for.
  ContentResult(kind: ContentMissing, contentId: toContentId(contentKey))

proc run(config: DiscoveryConf) =
  let
    rng = newRng()
    bindIp = config.listenAddress
    udpPort = Port(config.udpPort)
    # TODO: allow for no TCP port mapping!
    (extIp, _, extUdpPort) = setupAddress(config.nat,
      config.listenAddress, udpPort, udpPort, "dcli")

  let d = newProtocol(config.nodeKey,
          extIp, none(Port), extUdpPort,
          bootstrapRecords = config.bootnodes,
          bindIp = bindIp, bindPort = udpPort,
          enrAutoUpdate = config.enrAutoUpdate,
          rng = rng)

  d.open()

  let portal = PortalProtocol.new(d, "portal".toBytes(), testHandler,
    bootstrapRecords = config.portalBootnodes)

  if config.metricsEnabled:
    let
      address = config.metricsAddress
      port = config.metricsPort
    notice "Starting metrics HTTP server",
      url = "http://" & $address & ":" & $port & "/metrics"
    try:
      chronos_httpserver.startMetricsHttpServer($address, port)
    except CatchableError as exc: raise exc
    except Exception as exc: raiseAssert exc.msg # TODO fix metrics

  case config.cmd
  of ping:
    let pong = waitFor portal.ping(config.pingTarget)

    if pong.isOk():
      echo pong.get()
    else:
      echo pong.error
  of findnode:
    let distances = List[uint16, 256](@[config.distance])
    let nodes = waitFor portal.findNode(config.findNodeTarget, distances)

    if nodes.isOk():
      echo nodes.get()
    else:
      echo nodes.error
  of findcontent:
    proc random(T: type UInt256, rng: var BrHmacDrbgContext): T =
      var key: UInt256
      brHmacDrbgGenerate(addr rng, addr key, csize_t(sizeof(key)))

      key

    # For now just some random bytes
    let contentKey = List.init(@[1'u8], 2048)

    let foundContent = waitFor portal.findContent(config.findContentTarget,
      contentKey)

    if foundContent.isOk():
      echo foundContent.get()
    else:
      echo foundContent.error

  of noCommand:
    d.start()
    portal.start()
    waitfor(discover(d))

when isMainModule:
  let config = DiscoveryConf.load()

  setLogLevel(config.logLevel)

  run(config)
