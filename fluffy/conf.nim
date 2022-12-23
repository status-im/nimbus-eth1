# Nimbus
# Copyright (c) 2021-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [Defect].}

import
  std/os,
  uri, confutils, confutils/std/net, chronicles,
  eth/keys, eth/net/nat, eth/p2p/discoveryv5/[enr, node],
  json_rpc/rpcproxy,
  nimcrypto/hash,
  stew/byteutils,
  ./network/wire/portal_protocol_config

proc defaultDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "Fluffy"
  elif defined(macosx):
    "Library" / "Application Support" / "Fluffy"
  else:
    ".cache" / "fluffy"

  getHomeDir() / dataDir

const
  defaultListenAddress* = (static ValidIpAddress.init("0.0.0.0"))
  defaultAdminListenAddress* = (static ValidIpAddress.init("127.0.0.1"))
  defaultProxyAddress* = (static "http://127.0.0.1:8546")
  defaultClientConfig* = getHttpClientConfig(defaultProxyAddress)

  defaultListenAddressDesc = $defaultListenAddress
  defaultAdminListenAddressDesc = $defaultAdminListenAddress
  defaultDataDirDesc = defaultDataDir()
  defaultClientConfigDesc = $(defaultClientConfig.httpUri)
  # 100mb seems a bit smallish we may consider increasing defaults after some
  # network measurements
  defaultStorageSize* = uint32(1000 * 1000 * 100)
  defaultStorageSizeDesc* = $defaultStorageSize

type
  TrustedDigest* = MDigest[32 * 8]

  PortalCmd* = enum
    noCommand

  PortalNetwork* = enum
    none
    testnet0

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
      defaultValue: defaultListenAddress
      defaultValueDesc: $defaultListenAddressDesc
      desc: "Listening address for the Discovery v5 traffic"
      name: "listen-address" .}: ValidIpAddress

    portalNetwork* {.
      desc:
        "Select which Portal network to join. This will currently only " &
        "set the network specific bootstrap nodes automatically"
      defaultValue: PortalNetwork.none
      defaultValueDesc: "none"
      name: "network" }: PortalNetwork

    # Note: This will add bootstrap nodes for both Discovery v5 network and each
    # enabled Portal network. No distinction is made on bootstrap nodes per
    # specific network.
    bootstrapNodes* {.
      desc: "ENR URI of node to bootstrap Discovery v5 and the Portal networks from. Argument may be repeated"
      name: "bootstrap-node" .}: seq[Record]

    bootstrapNodesFile* {.
      desc: "Specifies a line-delimited file of ENR URIs to bootstrap Discovery v5 and Portal networks from"
      defaultValue: ""
      name: "bootstrap-file" .}: InputFile

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

    dataDir* {.
      desc: "The directory where fluffy will store the content data"
      defaultValue: defaultDataDir()
      defaultValueDesc: $defaultDataDirDesc
      name: "data-dir" .}: OutDir

    networkKeyFile* {.
      desc: "Source of network (secp256k1) private key file"
      defaultValue: config.dataDir / "netkey",
      name: "netkey-file" }: string

    networkKey* {.
      hidden
      desc: "Private key (secp256k1) for the p2p network, hex encoded.",
      defaultValue: none(PrivateKey)
      defaultValueDesc: "none"
      name: "netkey-unsafe" .}: Option[PrivateKey]

    accumulatorFile* {.
      desc:
        "Get the master accumulator snapshot from a file containing an " &
        "pre-build SSZ encoded master accumulator."
      defaultValue: none(InputFile)
      defaultValueDesc: "none"
      name: "accumulator-file" .}: Option[InputFile]

    metricsEnabled* {.
      defaultValue: false
      desc: "Enable the metrics server"
      name: "metrics" .}: bool

    metricsAddress* {.
      defaultValue: defaultAdminListenAddress
      defaultValueDesc: $defaultAdminListenAddressDesc
      desc: "Listening address of the metrics server"
      name: "metrics-address" .}: ValidIpAddress

    metricsPort* {.
      defaultValue: 8008
      desc: "Listening HTTP port of the metrics server"
      name: "metrics-port" .}: Port

    rpcEnabled* {.
      desc: "Enable the JSON-RPC server"
      defaultValue: false
      name: "rpc" .}: bool

    rpcPort* {.
      desc: "HTTP port for the JSON-RPC server"
      defaultValue: 8545
      name: "rpc-port" .}: Port

    rpcAddress* {.
      desc: "Listening address of the RPC server"
      defaultValue: defaultAdminListenAddress
      defaultValueDesc: $defaultAdminListenAddressDesc
      name: "rpc-address" .}: ValidIpAddress

    bridgeUri* {.
      defaultValue: none(string)
      defaultValueDesc: ""
      desc: "if provided, enables getting data from bridge node"
      name: "bridge-client-uri" .}: Option[string]

    # it makes little sense to have default value here in final release, but until then
    # it would be troublesome to add some fake uri param every time
    proxyUri* {.
      defaultValue: defaultClientConfig
      defaultValueDesc: $defaultClientConfigDesc
      desc: "URI of eth client where to proxy unimplemented rpc methods to"
      name: "proxy-uri" .}: ClientConfig

    tableIpLimit* {.
      hidden
      desc: "Maximum amount of nodes with the same IP in the routing tables"
      defaultValue: DefaultTableIpLimit
      name: "table-ip-limit" .}: uint

    bucketIpLimit* {.
      hidden
      desc: "Maximum amount of nodes with the same IP in the routing tables buckets"
      defaultValue: DefaultBucketIpLimit
      name: "bucket-ip-limit" .}: uint

    bitsPerHop* {.
      hidden
      desc: "Kademlia's b variable, increase for less hops per lookup"
      defaultValue: DefaultBitsPerHop
      name: "bits-per-hop" .}: int

    radiusConfig* {.
      desc: "Radius configuration for a fluffy node. Radius can be either `dynamic` " &
            "where the node adjusts the radius based on `storage-size` option, " &
            "or `static:<logRadius>` where the node has a hardcoded logarithmic radius value. " &
            "Warning: `static:<logRadius>` disables `storage-size` limits and " &
            "makes the node store a fraction of the network based on set radius."
      defaultValue: defaultRadiusConfig
      defaultValueDesc: $defaultRadiusConfigDesc
      name: "radius" .}: RadiusConfig

    # TODO maybe it is worth defining minimal storage size and throw error if
    # value provided is smaller than minimum
    storageSize* {.
      desc: "Maximum amount (in bytes) of content which will be stored " &
            "in the local database."
      defaultValue: defaultStorageSize
      defaultValueDesc: $defaultStorageSizeDesc
      name: "storage-size" .}: uint32

    trustedBlockRoot* {.
      desc: "Recent trusted finalized block root to initialize the consensus light client from. " &
            "If not provided by the user, portal light client will be disabled."
      defaultValue: none(TrustedDigest)
      name: "trusted-block-root" .}: Option[TrustedDigest]

    case cmd* {.
      command
      defaultValue: noCommand .}: PortalCmd
    of noCommand:
      discard

func parseCmdArg*(T: type TrustedDigest, input: string): T
                 {.raises: [ValueError, Defect].} =
  TrustedDigest.fromHex(input)

func completeCmdArg*(T: type TrustedDigest, input: string): seq[string] =
  return @[]

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
