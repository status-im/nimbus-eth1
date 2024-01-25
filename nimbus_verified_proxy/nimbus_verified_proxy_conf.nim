# nimbus_verified_proxy
# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/os,
  json_rpc/rpcproxy, # must be early (compilation annoyance)
  json_serialization/std/net,
  beacon_chain/conf_light_client,
  beacon_chain/conf

export net, conf

proc defaultVerifiedProxyDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "NimbusVerifiedProxy"
  elif defined(macosx):
    "Library" / "Application Support" / "NimbusVerifiedProxy"
  else:
    ".cache" / "nimbus-verified-proxy"

  getHomeDir() / dataDir

const
  defaultDataVerifiedProxyDirDesc* = defaultVerifiedProxyDataDir()

type
  Web3UrlKind* = enum
    HttpUrl, WsUrl

  Web3Url* = object
    kind*: Web3UrlKind
    web3Url*: string

type VerifiedProxyConf* = object
  # Config
  configFile* {.
    desc: "Loads the configuration from a TOML file"
    name: "config-file" .}: Option[InputFile]

  # Logging
  logLevel* {.
    desc: "Sets the log level"
    defaultValue: "INFO"
    name: "log-level" .}: string

  logStdout* {.
    hidden
    desc: "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)"
    defaultValueDesc: "auto"
    defaultValue: StdoutLogKind.Auto
    name: "log-format" .}: StdoutLogKind

  # Storage
  dataDir* {.
    desc: "The directory where nimbus_verified_proxy will store all data"
    defaultValue: defaultVerifiedProxyDataDir()
    defaultValueDesc: $defaultDataVerifiedProxyDirDesc
    abbr: "d"
    name: "data-dir" .}: OutDir

  # Network
  eth2Network* {.
    desc: "The Eth2 network to join"
    defaultValueDesc: "mainnet"
    name: "network" .}: Option[string]

  # Consensus light sync
  # No default - Needs to be provided by the user
  trustedBlockRoot* {.
    desc: "Recent trusted finalized block root to initialize the consensus light client from"
    name: "trusted-block-root" .}: Eth2Digest

  # (Untrusted) web3 provider
  # No default - Needs to be provided by the user
  web3url* {.
    desc: "URL of the web3 data provider"
    name: "web3-url" .}: Web3Url

  # Local JSON-RPC server
  rpcAddress* {.
    desc: "Listening address of the JSON-RPC server"
    defaultValue: defaultAdminListenAddress
    defaultValueDesc: $defaultAdminListenAddressDesc
    name: "rpc-address" .}: IpAddress

  rpcPort* {.
    desc: "Listening port of the JSON-RPC server"
    defaultValue: 8545
    name: "rpc-port" .}: Port

  # Libp2p
  bootstrapNodes* {.
    desc: "Specifies one or more bootstrap nodes to use when connecting to the network"
    abbr: "b"
    name: "bootstrap-node" .}: seq[string]

  bootstrapNodesFile* {.
    desc: "Specifies a line-delimited file of bootstrap Ethereum network addresses"
    defaultValue: ""
    name: "bootstrap-file" .}: InputFile

  listenAddress* {.
    desc: "Listening address for the Ethereum LibP2P and Discovery v5 traffic"
    defaultValue: defaultListenAddress
    defaultValueDesc: $defaultListenAddressDesc
    name: "listen-address" .}: IpAddress

  tcpPort* {.
    desc: "Listening TCP port for Ethereum LibP2P traffic"
    defaultValue: defaultEth2TcpPort
    defaultValueDesc: $defaultEth2TcpPortDesc
    name: "tcp-port" .}: Port

  udpPort* {.
    desc: "Listening UDP port for node discovery"
    defaultValue: defaultEth2TcpPort
    defaultValueDesc: $defaultEth2TcpPortDesc
    name: "udp-port" .}: Port

  # TODO: Select a lower amount of peers.
  maxPeers* {.
    desc: "The target number of peers to connect to"
    defaultValue: 160 # 5 (fanout) * 64 (subnets) / 2 (subs) for a healthy mesh
    name: "max-peers" .}: int

  hardMaxPeers* {.
    desc: "The maximum number of peers to connect to. Defaults to maxPeers * 1.5"
    name: "hard-max-peers" .}: Option[int]

  nat* {.
    desc: "Specify method to use for determining public address. " &
          "Must be one of: any, none, upnp, pmp, extip:<IP>"
    defaultValue: NatConfig(hasExtIp: false, nat: NatAny)
    defaultValueDesc: "any"
    name: "nat" .}: NatConfig

  enrAutoUpdate* {.
    desc: "Discovery can automatically update its ENR with the IP address " &
          "and UDP port as seen by other nodes it communicates with. " &
          "This option allows to enable/disable this functionality"
    defaultValue: false
    name: "enr-auto-update" .}: bool

  agentString* {.
    defaultValue: "nimbus",
    desc: "Node agent string which is used as identifier in the LibP2P network"
    name: "agent-string" .}: string

  discv5Enabled* {.
    desc: "Enable Discovery v5"
    defaultValue: true
    name: "discv5" .}: bool

  directPeers* {.
    desc: "The list of priviledged, secure and known peers to connect and" &
          "maintain the connection to, this requires a not random netkey-file." &
          "In the complete multiaddress format like:" &
          "/ip4/<address>/tcp/<port>/p2p/<peerId-public-key>." &
          "Peering agreements are established out of band and must be reciprocal"
    name: "direct-peer" .}: seq[string]


proc parseCmdArg*(
    T: type Web3Url, p: string): T {.raises: [ValueError].} =
  let
    url = parseUri(p)
    normalizedScheme = url.scheme.toLowerAscii()

  if (normalizedScheme == "http" or normalizedScheme == "https"):
    Web3Url(kind: HttpUrl, web3Url: p)
  elif (normalizedScheme == "ws" or normalizedScheme == "wss"):
    Web3Url(kind: WsUrl, web3Url: p)
  else:
    raise newException(
      ValueError, "Web3 url should have defined scheme (http/https/ws/wss)"
    )

proc completeCmdArg*(T: type Web3Url, val: string): seq[string] =
  return @[]

func asLightClientConf*(pc: VerifiedProxyConf): LightClientConf =
  return LightClientConf(
    configFile: pc.configFile,
    logLevel: pc.logLevel,
    logStdout: pc.logStdout,
    logFile: none(OutFile),
    dataDir: pc.dataDir,
    eth2Network: pc.eth2Network,
    bootstrapNodes: pc.bootstrapNodes,
    bootstrapNodesFile: pc.bootstrapNodesFile,
    listenAddress: pc.listenAddress,
    tcpPort: pc.tcpPort,
    udpPort: pc.udpPort,
    maxPeers: pc.maxPeers,
    hardMaxPeers: pc.hardMaxPeers,
    nat: pc.nat,
    enrAutoUpdate: pc.enrAutoUpdate,
    agentString: pc.agentString,
    discv5Enabled: pc.discv5Enabled,
    directPeers: pc.directPeers,
    trustedBlockRoot: pc.trustedBlockRoot,
    web3Urls: @[EngineApiUrlConfigValue(url: pc.web3url.web3Url)],
    jwtSecret: none(InputFile),
    stopAtEpoch: 0
  )

# TODO: Cannot use ClientConfig in VerifiedProxyConf due to the fact that
# it contain `set[TLSFlags]` which does not have proper toml serialization
func asClientConfig*(url: Web3Url): ClientConfig =
  case url.kind
  of HttpUrl:
    getHttpClientConfig(url.web3Url)
  of WsUrl:
    getWebSocketClientConfig(url.web3Url, flags = {})
