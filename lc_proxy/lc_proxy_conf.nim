# beacon_chain
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  std/os,
  json_serialization/std/net,
  beacon_chain/light_client,
  beacon_chain/conf

export net, conf

proc defaultLCPDataDir*(): string =
  let dataDir = when defined(windows):
    "AppData" / "Roaming" / "LightClientProxy"
  elif defined(macosx):
    "Library" / "Application Support" / "LightClientProxy"
  else:
    ".cache" / "lightclientproxy"

  getHomeDir() / dataDir


type Web3ClientType* = enum
  WsClient, HttpClient

type Web3ClientConfig* = object
  kind*: Web3ClientType
  url*: string

const
  defaultWeb3Address* = (static "http://127.0.0.1:8546")
  defaultWeb3ClientConfig* = Web3ClientConfig(url: defaultWeb3Address, kind: HttpClient)
  defaultDataLCPDirDesc* = defaultLCPDataDir()

type LcProxyConf* = object
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

  logFile* {.
    desc: "Specifies a path for the written Json log file (deprecated)"
    name: "log-file" .}: Option[OutFile]

  # Storage
  dataDir* {.
    desc: "The directory where nimbus will store all blockchain data"
    defaultValue: defaultLCPDataDir()
    defaultValueDesc: $defaultDataLCPDirDesc
    abbr: "d"
    name: "data-dir" .}: OutDir

  # Network
  eth2Network* {.
    desc: "The Eth2 network to join"
    defaultValueDesc: "mainnet"
    name: "network" .}: Option[string]

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
    name: "listen-address" .}: ValidIpAddress

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

  maxPeers* {.
    desc: "The target number of peers to connect to"
    defaultValue: 160 # 5 (fanout) * 64 (subnets) / 2 (subs) for a heathy mesh
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
    desc: "Node agent string which is used as identifier in network"
    name: "agent-string" .}: string

  discv5Enabled* {.
    desc: "Enable Discovery v5"
    defaultValue: true
    name: "discv5" .}: bool

  directPeers* {.
    desc: "The list of priviledged, secure and known peers to connect and maintain the connection to, this requires a not random netkey-file. In the complete multiaddress format like: /ip4/<address>/tcp/<port>/p2p/<peerId-public-key>. Peering agreements are established out of band and must be reciprocal."
    name: "direct-peer" .}: seq[string]

  # Light client
  trustedBlockRoot* {.
    desc: "Recent trusted finalized block root to initialize light client from"
    name: "trusted-block-root" .}: Eth2Digest

  rpcPort* {.
    desc: "HTTP port for the JSON-RPC server"
    defaultValue: 8545
    name: "rpc-port" .}: Port

  rpcAddress* {.
    desc: "Listening address of the RPC server"
    defaultValue: defaultAdminListenAddress
    defaultValueDesc: $defaultAdminListenAddressDesc
    name: "rpc-address" .}: ValidIpAddress

  web3ClientConfig* {.
    desc: "url of web3 data provider"
    defaultValue: defaultWeb3ClientConfig
    name: "web3-url" .}: Web3ClientConfig

proc parseCmdArg*(T: type Web3ClientConfig, p: TaintedString): T
      {.raises: [Defect, ConfigurationError].} =
  let url = parseUri(p)
  let normalizedScheme = url.scheme.toLowerAscii()
  if (normalizedScheme == "http" or normalizedScheme == "https"):
    Web3ClientConfig(kind: HttpClient, url: p)
  elif (normalizedScheme == "ws" or normalizedScheme == "wss"):
    Web3ClientConfig(kind: WsClient, url: p)
  else:
    raise newException(
      ConfigurationError, "Web3 client uri should have defined scheme (http/https/ws/wss)"
    )

proc completeCmdArg*(T: type Web3ClientConfig, val: TaintedString): seq[string] =
  return @[]

func asLightClientConf*(pc: LcProxyConf): LightClientConf =
  return LightClientConf(
    configFile: pc.configFile,
    logLevel: pc.logLevel,
    logStdout: pc.logStdout,
    logFile: pc.logFile,
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
    web3Urls: @[],
    jwtSecret: none(string),
    stopAtEpoch: 0
  )
