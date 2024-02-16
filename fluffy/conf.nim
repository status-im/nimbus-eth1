# Fluffy
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  uri, confutils, confutils/std/net, chronicles,
  eth/keys, eth/p2p/discoveryv5/[enr, node, routing_table],
  json_rpc/rpcproxy,
  nimcrypto/hash,
  stew/byteutils,
  eth/net/nat, # must be late (compilation annoyance)
  ./logging,
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
  defaultListenAddress* = (static parseIpAddress("0.0.0.0"))
  defaultAdminListenAddress* = (static parseIpAddress("127.0.0.1"))
  defaultProxyAddress* = (static "http://127.0.0.1:8546")
  defaultClientConfig* = getHttpClientConfig(defaultProxyAddress)

  defaultListenAddressDesc = $defaultListenAddress
  defaultAdminListenAddressDesc = $defaultAdminListenAddress
  defaultDataDirDesc = defaultDataDir()
  defaultClientConfigDesc = $(defaultClientConfig.httpUri)
  defaultStorageCapacity* = 2000'u32 # 2 GB default
  defaultStorageCapacityDesc* = $defaultStorageCapacity

  defaultTableIpLimitDesc* =
    $defaultPortalProtocolConfig.tableIpLimits.tableIpLimit
  defaultBucketIpLimitDesc* =
    $defaultPortalProtocolConfig.tableIpLimits.bucketIpLimit
  defaultBitsPerHopDesc* =
    $defaultPortalProtocolConfig.bitsPerHop

type
  TrustedDigest* = MDigest[32 * 8]

  PortalCmd* = enum
    noCommand

  PortalNetwork* = enum
    none
    testnet0

  PortalConf* = object
    logLevel* {.
      desc: "Sets the log level for process and topics (e.g. \"DEBUG; TRACE:discv5,portal_wire; REQUIRED:none; DISABLED:none\")"
      defaultValue: "INFO"
      name: "log-level" .}: string

    logStdout* {.
      hidden
      desc: "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)"
      defaultValueDesc: "auto"
      defaultValue: StdoutLogKind.Auto
      name: "log-format" .}: StdoutLogKind

    udpPort* {.
      defaultValue: 9009
      desc: "UDP listening port"
      name: "udp-port" .}: uint16

    listenAddress* {.
      defaultValue: defaultListenAddress
      defaultValueDesc: $defaultListenAddressDesc
      desc: "Listening address for the Discovery v5 traffic"
      name: "listen-address" .}: IpAddress

    portalNetwork* {.
      desc:
        "Select which Portal network to join. This will set the " &
        "network specific bootstrap nodes automatically"
      defaultValue: PortalNetwork.testnet0
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
      name: "metrics-address" .}: IpAddress

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
      name: "rpc-address" .}: IpAddress

    # it makes little sense to have default value here in final release, but until then
    # it would be troublesome to add some fake uri param every time
    proxyUri* {.
      defaultValue: defaultClientConfig
      defaultValueDesc: $defaultClientConfigDesc
      desc: "URI of eth client where to proxy unimplemented JSON-RPC methods to"
      name: "proxy-uri" .}: ClientConfig

    tableIpLimit* {.
      hidden
      desc: "Maximum amount of nodes with the same IP in the routing table. " &
          "This option is currently required as many nodes are running from " &
          "the same machines. The option will be removed/adjusted in the future"
      defaultValue: defaultPortalProtocolConfig.tableIpLimits.tableIpLimit
      defaultValueDesc: $defaultTableIpLimitDesc
      name: "table-ip-limit" .}: uint

    bucketIpLimit* {.
      hidden
      desc: "Maximum amount of nodes with the same IP in the routing table's buckets. " &
            "This option is currently required as many nodes are running from " &
            "the same machines. The option will be removed/adjusted in the future"
      defaultValue: defaultPortalProtocolConfig.tableIpLimits.bucketIpLimit
      defaultValueDesc: $defaultBucketIpLimitDesc
      name: "bucket-ip-limit" .}: uint

    bitsPerHop* {.
      hidden
      desc: "Kademlia's b variable, increase for less hops per lookup"
      defaultValue: defaultPortalProtocolConfig.bitsPerHop
      defaultValueDesc: $defaultBitsPerHopDesc
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
    storageCapacityMB* {.
      desc: "Maximum amount (in megabytes) of content which will be stored " &
            "in the local database."
      defaultValue: defaultStorageCapacity
      defaultValueDesc: $defaultStorageCapacityDesc
      name: "storage-capacity" .}: uint64

    trustedBlockRoot* {.
      desc: "Recent trusted finalized block root to initialize the consensus light client from. " &
            "If not provided by the user, portal light client will be disabled."
      defaultValue: none(TrustedDigest)
      name: "trusted-block-root" .}: Option[TrustedDigest]

    forcePrune* {.
      hidden
      desc: "Force the pruning of the database. This should be used when the " &
            "database is decreased in size, e.g. when a lower static radius " &
            "or a lower storage capacity is set."
      defaultValue: false
      name: "force-prune" .}: bool

    disablePoke* {.
      hidden
      desc: "Disable POKE functionality for gossip mechanisms testing"
      defaultValue: defaultDisablePoke
      defaultValueDesc: $defaultDisablePoke
      name: "disable-poke" .}: bool

    stateNetworkEnabled* {.
      hidden
      desc: "Enable State Network"
      defaultValue: false
      name: "state" .}: bool

    case cmd* {.
      command
      defaultValue: noCommand .}: PortalCmd
    of noCommand:
      discard

func parseCmdArg*(T: type TrustedDigest, input: string): T
                 {.raises: [ValueError].} =
  TrustedDigest.fromHex(input)

func completeCmdArg*(T: type TrustedDigest, input: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type enr.Record, p: string): T
    {.raises: [ValueError].} =
  if not fromURI(result, p):
    raise newException(ValueError, "Invalid ENR")

proc completeCmdArg*(T: type enr.Record, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type Node, p: string): T
    {.raises: [ValueError].} =
  var record: enr.Record
  if not fromURI(record, p):
    raise newException(ValueError, "Invalid ENR")

  let n = newNode(record)
  if n.isErr:
    raise newException(ValueError, $n.error)

  if n[].address.isNone():
    raise newException(ValueError, "ENR without address")

  n[]

proc completeCmdArg*(T: type Node, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type PrivateKey, p: string): T
    {.raises: [ValueError].} =
  try:
    result = PrivateKey.fromHex(p).tryGet()
  except CatchableError:
    raise newException(ValueError, "Invalid private key")

proc completeCmdArg*(T: type PrivateKey, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type ClientConfig, p: string): T
      {.raises: [ValueError].} =
  let uri = parseUri(p)
  if (uri.scheme == "http" or uri.scheme == "https"):
    getHttpClientConfig(p)
  elif (uri.scheme == "ws" or uri.scheme == "wss"):
    getWebSocketClientConfig(p)
  else:
    raise newException(
      ValueError, "Proxy uri should have defined scheme (http/https/ws/wss)"
    )

proc completeCmdArg*(T: type ClientConfig, val: string): seq[string] =
  return @[]

chronicles.formatIt(InputDir): $it
chronicles.formatIt(OutDir): $it
chronicles.formatIt(InputFile): $it
