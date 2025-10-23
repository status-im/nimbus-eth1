# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[os, strutils, sequtils],
  uri,
  confutils,
  confutils/std/net,
  chronicles,
  eth/common/keys,
  eth/net/nat,
  eth/p2p/discoveryv5/[node, routing_table],
  nimcrypto/hash,
  stew/byteutils,
  stew/io2,
  beacon_chain/nimbus_binary_common,
  ../bridge/common/rpc_helpers,
  ../logging,
  ../network/wire/portal_protocol_config

const
  defaultListenAddress* = (static parseIpAddress("0.0.0.0"))
  defaultAdminListenAddress* = (static parseIpAddress("127.0.0.1"))
  defaultListenAddressDesc = $defaultListenAddress
  defaultAdminListenAddressDesc = $defaultAdminListenAddress

  defaultStorageCapacity* = 2000'u32 # 2 GB default
  defaultStorageCapacityDesc* = $defaultStorageCapacity

  defaultTableIpLimitDesc* = $defaultPortalProtocolConfig.tableIpLimits.tableIpLimit
  defaultBucketIpLimitDesc* = $defaultPortalProtocolConfig.tableIpLimits.bucketIpLimit
  defaultBitsPerHopDesc* = $defaultPortalProtocolConfig.bitsPerHop
  defaultAlphaDesc* = $defaultPortalProtocolConfig.alpha
  defaultMaxGossipNodesDesc* = $defaultPortalProtocolConfig.maxGossipNodes

  defaultRpcApis* = @["portal"]
  defaultRpcApisDesc* = "portal"

  defaultNetwork* = PortalNetwork.mainnet
  defaultNetworkDesc* = $defaultNetwork
  defaultSubnetworks* = {PortalSubnetwork.history}
  defaultSubnetworksDesc* = defaultSubnetworks.toSeq().join(",")

  netKeyFileName = "portal_node_netkey"

type
  RpcFlag* {.pure.} = enum
    portal
    discovery

  TrustedDigest* = MDigest[32 * 8]

  PortalConf* = object
    logLevel* {.
      desc:
        "Sets the log level for process and topics (e.g. \"DEBUG; TRACE:discv5,portal_wire; REQUIRED:none; DISABLED:none\")",
      defaultValue: "INFO",
      name: "log-level"
    .}: string

    logStdout* {.
      hidden,
      desc:
        "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)",
      defaultValueDesc: "auto",
      defaultValue: StdoutLogKind.Auto,
      name: "log-format"
    .}: StdoutLogKind

    udpPort* {.defaultValue: 9009, desc: "UDP listening port", name: "udp-port".}:
      uint16

    listenAddress* {.
      defaultValue: defaultListenAddress,
      defaultValueDesc: $defaultListenAddressDesc,
      desc: "Listening address for the Discovery v5 traffic",
      name: "listen-address"
    .}: IpAddress

    network* {.
      desc:
        "Select which network to join. This will set the " &
        "network specific Portal bootstrap nodes automatically",
      defaultValue: defaultNetwork,
      defaultValueDesc: $defaultNetworkDesc,
      name: "network"
    .}: PortalNetwork

    portalSubnetworks* {.
      desc: "Select which Portal subnetworks (sub-protocols) to enable",
      defaultValue: defaultSubnetworks,
      defaultValueDesc: $defaultSubnetworksDesc,
      name: "portal-subnetworks"
    .}: set[PortalSubnetwork]

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

    dataDirFlag* {.
      desc: "The directory where nimbus will store all blockchain data",
      abbr: "d",
      name: "data-dir"
    .}: Option[OutDir]

    networkKeyFileFlag* {.
      desc: "Source of network (secp256k1) private key file",
      defaultValueDesc: "<data-dir>/" & netKeyFileName,
      name: "netkey-file"
    .}: Option[OutDir]

    networkKey* {.
      hidden,
      desc: "Private key (secp256k1) for the p2p network, hex encoded.",
      defaultValue: none(PrivateKey),
      defaultValueDesc: "none",
      name: "netkey-unsafe"
    .}: Option[PrivateKey]

    networkKeyNodeIdPrefix* {.
      hidden,
      desc:
        "If an existing network key is not found, then generate a new private key " &
        "(secp256k1) which has a node id where the most significant bits match the " &
        "specified prefix (in hex). Between 2 and 8 hex characters are supported " &
        "(excluding the 0x) but generally no more than 4 characters are recommended " &
        "because otherwise the generation process is very slow.",
      defaultValue: none(string),
      defaultValueDesc: "none",
      name: "debug-netkey-nodeid-prefix-unsafe"
    .}: Option[string]

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

    rpcEnabled* {.
      desc: "Enable the HTTP JSON-RPC server", defaultValue: false, name: "rpc"
    .}: bool

    rpcAddress* {.
      desc: "Listening address of the HTTP JSON-RPC server",
      defaultValue: defaultAdminListenAddress,
      defaultValueDesc: $defaultAdminListenAddressDesc,
      name: "rpc-address"
    .}: IpAddress

    rpcPort* {.
      desc: "Port for the HTTP JSON-RPC server", defaultValue: 8565, name: "rpc-port"
    .}: Port

    rpcApi* {.
      desc:
        "Enable specific set of JSON-RPC APIs over HTTP (available: portal, discovery)",
      defaultValue: defaultRpcApis,
      defaultValueDesc: $defaultRpcApisDesc,
      name: "rpc-api"
    .}: seq[string]

    wsEnabled* {.
      desc: "Enable the WebSocket JSON-RPC server", defaultValue: false, name: "ws"
    .}: bool

    wsAddress* {.
      desc: "Listening address of the WebSocket JSON-RPC server",
      defaultValue: defaultAdminListenAddress,
      defaultValueDesc: $defaultAdminListenAddressDesc,
      name: "ws-address"
    .}: IpAddress

    wsPort* {.
      desc: "Port for the WebSocket JSON-RPC server",
      defaultValue: 8566,
      name: "ws-port"
    .}: Port

    wsApi* {.
      desc:
        "Enable specific set of JSON-RPC APIs over WebSocket (available: portal, discovery)",
      defaultValue: defaultRpcApis,
      defaultValueDesc: $defaultRpcApisDesc,
      name: "ws-api"
    .}: seq[string]

    wsCompression* {.
      desc: "Enable compression for the WebSocket JSON-RPC server",
      defaultValue: false,
      name: "ws-compression"
    .}: bool

    web3Url* {.
      desc:
        "Execution layer JSON-RPC API URL. Required for requesting block headers for content validation",
      name: "web3-url"
    .}: Option[JsonRpcUrl]

    tableIpLimit* {.
      hidden,
      desc:
        "Maximum amount of nodes with the same IP in the routing table. " &
        "This option is currently required as many nodes are running from " &
        "the same machines. The option might be removed/adjusted in the future",
      defaultValue: defaultPortalProtocolConfig.tableIpLimits.tableIpLimit,
      defaultValueDesc: $defaultTableIpLimitDesc,
      name: "table-ip-limit"
    .}: uint

    bucketIpLimit* {.
      hidden,
      desc:
        "Maximum amount of nodes with the same IP in the routing table's buckets. " &
        "This option is currently required as many nodes are running from " &
        "the same machines. The option might be removed/adjusted in the future",
      defaultValue: defaultPortalProtocolConfig.tableIpLimits.bucketIpLimit,
      defaultValueDesc: $defaultBucketIpLimitDesc,
      name: "bucket-ip-limit"
    .}: uint

    bitsPerHop* {.
      hidden,
      desc: "Kademlia's b variable, increase for less hops per lookup",
      defaultValue: defaultPortalProtocolConfig.bitsPerHop,
      defaultValueDesc: $defaultBitsPerHopDesc,
      name: "bits-per-hop"
    .}: int

    alpha* {.
      hidden,
      desc: "The Kademlia concurrency factor",
      defaultValue: defaultPortalProtocolConfig.alpha,
      defaultValueDesc: $defaultAlphaDesc,
      name: "debug-alpha"
    .}: int

    maxGossipNodes* {.
      hidden,
      desc: "The maximum number of nodes to send content to during gossip",
      defaultValue: defaultPortalProtocolConfig.maxGossipNodes,
      defaultValueDesc: $defaultMaxGossipNodesDesc,
      name: "debug-max-gossip-nodes"
    .}: int

    maxConcurrentOffers* {.
      hidden,
      desc: "The maximum number of offers to send concurrently",
      defaultValue: defaultPortalProtocolConfig.maxConcurrentOffers,
      name: "debug-max-concurrent-offers"
    .}: int

    radiusConfig* {.
      desc:
        "Radius configuration for the portal node. Radius can be either `dynamic` " &
        "where the node adjusts the radius based on `storage-size` option, " &
        "or `static:<logRadius>` where the node has a hardcoded logarithmic radius value. " &
        "Warning: `static:<logRadius>` disables `storage-size` limits and " &
        "makes the node store a fraction of the network based on set radius.",
      defaultValue: defaultRadiusConfig,
      defaultValueDesc: $defaultRadiusConfigDesc,
      name: "radius"
    .}: RadiusConfig

    # TODO maybe it is worth defining minimal storage size and throw error if
    # value provided is smaller than minimum
    storageCapacityMB* {.
      desc:
        "Maximum amount (in megabytes) of content which will be stored " &
        "in the local database.",
      defaultValue: defaultStorageCapacity,
      defaultValueDesc: $defaultStorageCapacityDesc,
      name: "storage-capacity"
    .}: uint64

    trustedBlockRoot* {.
      desc:
        "Recent trusted finalized block root to initialize the consensus light client from. " &
        "If not provided by the user, portal light client will be disabled.",
      defaultValue: none(TrustedDigest),
      name: "trusted-block-root"
    .}: Option[TrustedDigest]

    forcePrune* {.
      hidden,
      desc:
        "Force the pruning of the database. This should be used when the " &
        "database is decreased in size, e.g. when a lower static radius " &
        "or a lower storage capacity is set.",
      defaultValue: false,
      name: "force-prune"
    .}: bool

    contentRequestRetries* {.
      hidden,
      desc: "Max number of retries when requesting content over the network.",
      defaultValue: 1,
      name: "debug-content-request-retries"
    .}: uint

    contentCacheSize* {.
      hidden,
      desc:
        "Size of the in memory local content cache. This is the max number " &
        "of content values that can be stored in the cache.",
      defaultValue: defaultPortalProtocolConfig.contentCacheSize,
      name: "debug-content-cache-size"
    .}: int

    disableContentCache* {.
      hidden,
      desc: "Disable the in memory local content cache",
      defaultValue: defaultPortalProtocolConfig.disableContentCache,
      name: "debug-disable-content-cache"
    .}: bool

    offerCacheSize* {.
      hidden,
      desc:
        "Size of the in memory local offer cache. This is the max number " &
        "of content id values that can be stored in the cache.",
      defaultValue: defaultPortalProtocolConfig.offerCacheSize,
      name: "debug-offer-cache-size"
    .}: int

    disableOfferCache* {.
      hidden,
      desc: "Disable the in memory local offer cache",
      defaultValue: defaultPortalProtocolConfig.disableOfferCache,
      name: "debug-disable-offer-cache"
    .}: bool

    disablePoke* {.
      hidden,
      desc: "Disable POKE functionality for gossip mechanisms testing",
      defaultValue: defaultDisablePoke,
      defaultValueDesc: $defaultDisablePoke,
      name: "disable-poke"
    .}: bool

    disableBanNodes* {.
      hidden,
      desc:
        "Disable node banning functionality for both discv5 and portal sub-protocols",
      defaultValue: defaultDisableBanNodes,
      defaultValueDesc: $defaultDisableBanNodes,
      name: "debug-disable-ban-nodes"
    .}: bool

    radiusCacheSize* {.
      hidden,
      desc: "Size of the in memory radius cache.",
      defaultValue: defaultPortalProtocolConfig.radiusCacheSize,
      name: "debug-radius-cache-size"
    .}: int

    contentQueueWorkers* {.
      hidden,
      desc:
        "The number of content queue workers to create for concurrent processing of received offers",
      defaultValue: 50,
      name: "debug-content-queue-workers"
    .}: int

    contentQueueSize* {.
      hidden,
      desc: "Size of the in memory content queue.",
      defaultValue: 50,
      name: "debug-content-queue-size"
    .}: int

proc dataDir*(config: PortalConf): string =
  string config.dataDirFlag.get(OutDir defaultDataDir("", $config.network))

proc networkKeyFile*(config: PortalConf): string =
  string config.networkKeyFileFlag.get(OutDir config.dataDir() / netKeyFileName)

func parseCmdArg*(T: type TrustedDigest, input: string): T {.raises: [ValueError].} =
  TrustedDigest.fromHex(input)

func completeCmdArg*(T: type TrustedDigest, input: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type enr.Record, p: string): T {.raises: [ValueError].} =
  let res = enr.Record.fromURI(p)
  if res.isErr():
    raise newException(ValueError, "Invalid ENR: " & $res.error)
  res.value

proc completeCmdArg*(T: type enr.Record, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type Node, p: string): T {.raises: [ValueError].} =
  let res = enr.Record.fromURI(p)
  if res.isErr():
    raise newException(ValueError, "Invalid ENR: " & $res.error)

  let n = Node.fromRecord(res.value)
  if n.address.isNone():
    raise newException(ValueError, "ENR without address")

  n

proc completeCmdArg*(T: type Node, val: string): seq[string] =
  return @[]

proc parseCmdArg*(T: type PrivateKey, p: string): T {.raises: [ValueError].} =
  try:
    result = PrivateKey.fromHex(p).tryGet()
  except CatchableError:
    raise newException(ValueError, "Invalid private key")

proc completeCmdArg*(T: type PrivateKey, val: string): seq[string] =
  return @[]

proc parseCmdArg*(
    T: type set[PortalSubnetwork], p: string
): T {.raises: [ValueError].} =
  var res: set[PortalSubnetwork] = {}
  let values = p.split({' ', ','})
  for value in values:
    let stripped = value.strip()
    let network =
      try:
        parseEnum[PortalSubnetwork](stripped)
      except ValueError:
        raise newException(ValueError, "Invalid network: " & stripped)

    res.incl(network)
  res

proc completeCmdArg*(T: type set[PortalSubnetwork], val: string): seq[string] =
  return @[]

chronicles.formatIt(InputDir):
  $it
chronicles.formatIt(OutDir):
  $it
chronicles.formatIt(InputFile):
  $it

func processList(v: string, o: var seq[string]) =
  ## Process comma-separated list of strings.
  if len(v) > 0:
    for n in v.split({' ', ','}):
      if len(n) > 0:
        o.add(n)

iterator repeatingList(listOfList: openArray[string]): string =
  for strList in listOfList:
    var list = newSeq[string]()
    processList(strList, list)
    for item in list:
      yield item

proc getRpcFlags*(rpcApis: openArray[string]): set[RpcFlag] =
  if rpcApis.len == 0:
    error "No RPC APIs specified"
    quit QuitFailure

  var rpcFlags: set[RpcFlag]
  for apiStr in rpcApis.repeatingList():
    case apiStr.toLowerAscii()
    of "portal":
      rpcFlags.incl RpcFlag.portal
    of "discovery":
      rpcFlags.incl RpcFlag.discovery
    else:
      error "Unknown RPC API: ", name = apiStr
      quit QuitFailure

  rpcFlags
