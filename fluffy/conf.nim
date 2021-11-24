# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/os,
  uri, confutils, confutils/std/net, chronicles,
  eth/keys, eth/net/nat, eth/p2p/discoveryv5/[enr, node],
  json_rpc/rpcproxy

proc defaultDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "Fluffy"
  elif defined(macosx):
    "Library" / "Application Support" / "Fluffy"
  else:
    ".cache" / "fluffy"

  getHomeDir() / dataDir

const
  DefaultListenAddress* = (static ValidIpAddress.init("0.0.0.0"))
  DefaultAdminListenAddress* = (static ValidIpAddress.init("127.0.0.1"))
  DefaultProxyAddress* = (static "http://127.0.0.1:8546")
  DefaultClientConfig* = getHttpClientConfig(DefaultProxyAddress)

  DefaultListenAddressDesc = $DefaultListenAddress
  DefaultAdminListenAddressDesc = $DefaultAdminListenAddress
  DefaultDataDirDesc = defaultDataDir()
  DefaultClientConfigDesc = $(DefaultClientConfig.httpUri)

type
  PortalCmd* = enum
    noCommand

  PortalConf* = object
    logLevel* {.
      defaultValue: LogLevel.DEBUG
      defaultValueDesc: $LogLevel.DEBUG
      desc: "Sets the log level"
      name: "log-level" .}: LogLevel

    udpPort* {.
      defaultValue: 9009
      desc: "UDP listening port"
      name: "udp-port" .}: uint16

    listenAddress* {.
      defaultValue: DefaultListenAddress
      defaultValueDesc: $DefaultListenAddressDesc
      desc: "Listening address for the Discovery v5 traffic"
      name: "listen-address" }: ValidIpAddress

    bootstrapNodes* {.
      desc: "ENR URI of node to bootstrap Discovery v5 from. Argument may be repeated"
      name: "bootstrap-node" .}: seq[Record]

    bootstrapNodesFile* {.
      desc: "Specifies a line-delimited file of ENR URIs to bootstrap Discovery v5 from"
      defaultValue: ""
      name: "bootstrap-file" }: InputFile

    nat* {.
      desc: "Specify method to use for determining public address. " &
            "Must be one of: any, none, upnp, pmp, extip:<IP>"
      defaultValue: NatConfig(hasExtIp: false, nat: NatAny)
      defaultValueDesc: "any"
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
      defaultValueDesc: "random"
      name: "nodekey" .}: PrivateKey

    dataDir* {.
      desc: "The directory where fluffy will store the content data"
      defaultValue: defaultDataDir()
      defaultValueDesc: $DefaultDataDirDesc
      name: "data-dir" }: OutDir

    # Note: This will add bootstrap nodes for each enabled Portal network.
    # No distinction is being made on bootstrap nodes for a specific network.
    portalBootstrapNodes* {.
      desc: "ENR URI of node to bootstrap the Portal networks from. Argument may be repeated"
      name: "portal-bootstrap-node" .}: seq[Record]

    portalBootstrapNodesFile* {.
      desc: "Specifies a line-delimited file of ENR URIs to bootstrap the Portal networks from"
      defaultValue: ""
      name: "portal-bootstrap-file" }: InputFile

    metricsEnabled* {.
      defaultValue: false
      desc: "Enable the metrics server"
      name: "metrics" .}: bool

    metricsAddress* {.
      defaultValue: DefaultAdminListenAddress
      defaultValueDesc: $DefaultAdminListenAddressDesc
      desc: "Listening address of the metrics server"
      name: "metrics-address" .}: ValidIpAddress

    metricsPort* {.
      defaultValue: 8008
      desc: "Listening HTTP port of the metrics server"
      name: "metrics-port" .}: Port

    rpcEnabled* {.
      desc: "Enable the JSON-RPC server"
      defaultValue: false
      name: "rpc" }: bool

    rpcPort* {.
      desc: "HTTP port for the JSON-RPC service"
      defaultValue: 8545
      name: "rpc-port" }: Port

    rpcAddress* {.
      desc: "Listening address of the RPC server"
      defaultValue: DefaultAdminListenAddress
      defaultValueDesc: $DefaultAdminListenAddressDesc
      name: "rpc-address" }: ValidIpAddress

    bridgeUri* {.
      defaultValue: none(string)
      defaultValueDesc: ""
      desc: "if provided, enables getting data from bridge node"
      name: "bridge-client-uri" .}: Option[string]

    # it makes little sense to have default value here in final release, but until then
    # it would be troublesome to add some fake uri param every time
    proxyUri* {.
      defaultValue: DefaultClientConfig
      defaultValueDesc: $DefaultClientConfigDesc
      desc: "URI of eth client where to proxy unimplemented rpc methods to"
      name: "proxy-uri" .}: ClientConfig

    case cmd* {.
      command
      defaultValue: noCommand .}: PortalCmd
    of noCommand:
      discard

proc parseCmdArg*(T: type enr.Record, p: TaintedString): T
    {.raises: [Defect, ConfigurationError].} =
  if not fromURI(result, p):
    raise newException(ConfigurationError, "Invalid ENR")

proc completeCmdArg*(T: type enr.Record, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type Node, p: TaintedString): T
    {.raises: [Defect, ConfigurationError].} =
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

proc parseCmdArg*(T: type PrivateKey, p: TaintedString): T
    {.raises: [Defect, ConfigurationError].} =
  try:
    result = PrivateKey.fromHex(string(p)).tryGet()
  except CatchableError:
    raise newException(ConfigurationError, "Invalid private key")

proc completeCmdArg*(T: type PrivateKey, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg*(T: type ClientConfig, p: TaintedString): T 
      {.raises: [Defect, ConfigurationError].} =
  let uri = parseUri(p)
  if (uri.scheme == "http" or uri.scheme == "https"):
    getHttpClientConfig(p)
  elif (uri.scheme == "ws" or uri.scheme == "wss"):
    getWebSocketClientConfig(p)
  else:
    raise newException(
      ConfigurationError, "Proxy uri should have defined scheme (http/https/ws/wss)"
    )

proc completeCmdArg*(T: type ClientConfig, val: TaintedString): seq[string] =
  return @[]
