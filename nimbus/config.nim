# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[options, strutils, times, os],
  pkg/[
    confutils,
    confutils/defs,
    stew/byteutils,
    confutils/std/net
  ],
  stew/shims/net as stewNet,
  eth/[p2p, common, net/nat, p2p/bootnodes],
  "."/[db/select_backend, chain_config,
    constants, vm_compile_info
  ]

const
  NimbusName* = "nimbus-eth1"
  ## project name string

  NimbusMajor*: int = 0
  ## is the major number of Nimbus' version.

  NimbusMinor*: int = 1
  ## is the minor number of Nimbus' version.

  NimbusPatch*: int = 0
  ## is the patch number of Nimbus' version.

  NimbusVersion* = $NimbusMajor & "." & $NimbusMinor & "." & $NimbusPatch
  ## is the version of Nimbus as a string.

  GitRevision = staticExec("git rev-parse --short HEAD").replace("\n") # remove CR

  NimVersion = staticExec("nim --version").strip()

  NimbusIdent* = "$# v$# [$#: $#, $#, $#, $#]" % [
    NimbusName,
    NimbusVersion,
    hostOS,
    hostCPU,
    nimbus_db_backend,
    VmName,
    GitRevision
  ]
  ## project ident name for networking services

let
  # e.g.: Copyright (c) 2018-2021 Status Research & Development GmbH
  NimbusCopyright* = "Copyright (c) 2018-" &
    $(now().utc.year) &
    " Status Research & Development GmbH"

  # e.g.:
  # Nimbus v0.1.0 [windows: amd64, rocksdb, evmc, dda8914f]
  # Copyright (c) 2018-2021 Status Research & Development GmbH
  NimbusBuild* = "$#\p$#" % [
    NimbusIdent,
    NimbusCopyright,
  ]

  NimbusHeader* = "$#\p\p$#" % [
    NimbusBuild,
    NimVersion
  ]

proc defaultDataDir*(): string =
  when defined(windows):
    getHomeDir() / "AppData" / "Roaming" / "Nimbus"
  elif defined(macosx):
    getHomeDir() / "Library" / "Application Support" / "Nimbus"
  else:
    getHomeDir() / ".cache" / "nimbus"

proc defaultKeystoreDir*(): string =
  defaultDataDir() / "keystore"

proc getLogLevels(): string =
  var logLevels: seq[string]
  for level in LogLevel:
    if level < enabledLogLevel:
      continue
    logLevels.add($level)
  join(logLevels, ", ")

const
  defaultDataDirDesc = defaultDataDir()
  defaultPort              = 30303
  defaultMetricsServerPort = 9093
  defaultEthRpcPort        = 8545
  defaultEthWsPort         = 8546
  defaultEthGraphqlPort    = 8547
  defaultListenAddress      = (static ValidIpAddress.init("0.0.0.0"))
  defaultAdminListenAddress = (static ValidIpAddress.init("127.0.0.1"))
  defaultListenAddressDesc      = $defaultListenAddress
  defaultAdminListenAddressDesc = $defaultAdminListenAddress
  logLevelDesc = getLogLevels()

type
  PruneMode* {.pure.} = enum
    Full
    Archive

  NimbusCmd* = enum
    noCommand

  ProtocolFlag* {.pure.} = enum
    ## Protocol flags
    Eth                           ## enable eth subprotocol
    Les                           ## enable les subprotocol

  RpcFlag* {.pure.} = enum
    ## RPC flags
    Eth                           ## enable eth_ set of RPC API
    Debug                         ## enable debug_ set of RPC API

  EnodeList* = object
    value*: seq[Enode]

  Protocols* = object
    value*: set[ProtocolFlag]

  RpcApi* = object
    value*: set[RpcFlag]

  NimbusConf* = object of RootObj
    ## Main Nimbus configuration object

    dataDir* {.
      separator: "ETHEREUM OPTIONS:"
      desc: "The directory where nimbus will store all blockchain data"
      defaultValue: defaultDataDir()
      defaultValueDesc: $defaultDataDirDesc
      abbr: "d"
      name: "data-dir" }: OutDir

    keyStore* {.
      desc: "Directory for the keystore files"
      defaultValue: defaultKeystoreDir()
      defaultValueDesc: "inside datadir"
      abbr: "k"
      name: "key-store" }: OutDir

    pruneMode* {.
      desc: "Blockchain prune mode (Full or Archive)"
      defaultValue: PruneMode.Full
      defaultValueDesc: $PruneMode.Full
      abbr : "p"
      name: "prune-mode" }: PruneMode

    importBlocks* {.
      desc: "Import RLP encoded block(s) in a file, validate, write to database and quit"
      defaultValue: ""
      abbr: "b"
      name: "import-blocks" }: InputFile

    importKey* {.
      desc: "Import unencrypted 32 bytes hex private key file"
      defaultValue: ""
      abbr: "e"
      name: "import-key" }: InputFile

    engineSigner* {.
      desc: "Enable sealing engine to run and producing blocks at specified interval (only PoA/Clique supported)"
      defaultValue: ZERO_ADDRESS
      defaultValueDesc: ""
      abbr: "s"
      name: "engine-signer" }: EthAddress

    verifyFrom* {.
      desc: "Enable extra verification when current block number greater than verify-from"
      defaultValueDesc: ""
      name: "verify-from" }: Option[uint64]

    case cmd* {.
      command
      defaultValue: noCommand }: NimbusCmd

    of noCommand:
      mainnet* {.
        separator: "\pETHEREUM NETWORK OPTIONS:"
        defaultValue: false
        defaultValueDesc: ""
        desc: "Use Ethereum main network (default)"
        }: bool

      ropsten* {.
        desc: "Use Ropsten test network (proof-of-work, the one most like Ethereum mainnet)"
        defaultValue: false
        defaultValueDesc: ""
        }: bool

      rinkeby* {.
        desc: "Use Rinkeby test network (proof-of-authority, for those running Geth clients)"
        defaultValue: false
        defaultValueDesc: ""
        }: bool

      goerli* {.
        desc: "Use Görli test network (proof-of-authority, works across all clients)"
        defaultValue: false
        defaultValueDesc: ""
        }: bool

      kovan* {.
        desc: "Use Kovan test network (proof-of-authority, for those running OpenEthereum clients)"
        defaultValue: false
        defaultValueDesc: ""
        }: bool

      networkId* {.
        desc: "Network id (1=mainnet, 3=ropsten, 4=rinkeby, 5=goerli, 42=kovan, other=custom)"
        defaultValueDesc: "mainnet"
        abbr: "i"
        name: "network-id" }: Option[NetworkId]

      customNetwork* {.
        desc: "Use custom genesis block for private Ethereum Network (as /path/to/genesis.json)"
        defaultValueDesc: ""
        abbr: "c"
        name: "custom-network" }: Option[CustomNetwork]

      bootNodes* {.
        separator: "\pNETWORKING OPTIONS:"
        desc: "Comma separated enode URLs for P2P discovery bootstrap (set v4+v5 instead for light servers)"
        defaultValue: EnodeList()
        defaultValueDesc: ""
        name: "boot-nodes" }: EnodeList

      bootNodesv4* {.
        desc: "Comma separated enode URLs for P2P v4 discovery bootstrap (light server, full nodes)"
        defaultValue: EnodeList()
        defaultValueDesc: ""
        name: "boot-nodes-v4" }: EnodeList

      bootNodesv5* {.
        desc: "Comma separated enode URLs for P2P v5 discovery bootstrap (light server, light nodes)"
        defaultValue: EnodeList()
        defaultValueDesc: ""
        name: "boot-nodes-v5" }: EnodeList

      staticNodes* {.
        desc: "Comma separated enode URLs to connect with"
        defaultValue: EnodeList()
        defaultValueDesc: ""
        name: "static-nodes" }: EnodeList

      listenAddress* {.
        desc: "Listening address for the Ethereum P2P and Discovery traffic"
        defaultValue: defaultListenAddress
        defaultValueDesc: $defaultListenAddressDesc
        name: "listen-address" }: ValidIpAddress

      tcpPort* {.
        desc: "Network listening TCP port"
        defaultValue: defaultPort
        defaultValueDesc: $defaultPort
        name: "tcp-port" }: Port

      udpPort* {.
        desc: "Network listening UDP port"
        defaultValue: 0 # set udpPort defaultValue in `makeConfig`
        defaultValueDesc: "default to --tcp-port"
        name: "udp-port" }: Port

      maxPeers* {.
        desc: "The maximum number of peers to connect to"
        defaultValue: 25
        name: "max-peers" }: int

      maxEndPeers* {.
        desc: "Maximum number of pending connection attempts"
        defaultValue: 0
        name: "max-end-peers" }: int

      nat* {.
        desc: "Specify method to use for determining public address. " &
              "Must be one of: any, none, upnp, pmp, extip:<IP>"
        defaultValue: NatConfig(hasExtIp: false, nat: NatAny)
        defaultValueDesc: "any"
        name: "nat" .}: NatConfig

      noDiscover* {.
        desc: "Disables the peer discovery mechanism (manual peer addition)"
        defaultValue: false
        name: "no-discover" .}: bool

      discv5Enabled* {.
        desc: "Enable Discovery v5"
        defaultValue: false
        name: "discv5" .}: bool

      nodeKeyHex* {.
        desc: "P2P node private key (as hexadecimal string)"
        defaultValue: ""
        defaultValueDesc: "random"
        name: "node-key" .}: string

      agentString* {.
        desc: "Node agent string which is used as identifier in network"
        defaultValue: NimbusIdent
        defaultValueDesc: $NimbusIdent
        name: "agent-string" .}: string

      protocols* {.
        desc: "Enable specific set of protocols (Eth, Les)"
        defaultValue: Protocols(value: {ProtocolFlag.Eth})
        defaultValueDesc: $ProtocolFlag.Eth
        name: "protocols" .}: Protocols

      metricsEnabled* {.
        separator: "\pLOCAL SERVICE OPTIONS:"
        desc: "Enable the metrics server"
        defaultValue: false
        name: "metrics" }: bool

      metricsPort* {.
        desc: "Listening HTTP port of the metrics server"
        defaultValue: defaultMetricsServerPort
        defaultValueDesc: $defaultMetricsServerPort
        name: "metrics-port" }: Port

      metricsAddress* {.
        desc: "Listening address of the metrics server"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "metrics-address" }: ValidIpAddress

      rpcEnabled* {.
        desc: "Enable the JSON-RPC server"
        defaultValue: false
        name: "rpc" }: bool

      rpcPort* {.
        desc: "Listening HTTP port for the JSON-RPC server"
        defaultValue: defaultEthRpcPort
        defaultValueDesc: $defaultEthRpcPort
        name: "rpc-port" }: Port

      rpcAddress* {.
        desc: "Listening address of the RPC server"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "rpc-address" }: ValidIpAddress

      rpcApi* {.
        desc: "Enable specific set of RPC API from list (comma-separated) (available: eth, debug)"
        defaultValue: RpcApi(value: {RpcFlag.Eth})
        defaultValueDesc: $RpcFlag.Eth
        name: "rpc-api" }: RpcApi

      wsEnabled* {.
        desc: "Enable the Websocket JSON-RPC server"
        defaultValue: false
        name: "ws" }: bool

      wsPort* {.
        desc: "Listening Websocket port for the JSON-RPC server"
        defaultValue: defaultEthWsPort
        defaultValueDesc: $defaultEthWsPort
        name: "ws-port" }: Port

      wsAddress* {.
        desc: "Listening address of the Websocket JSON-RPC server"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "ws-address" }: ValidIpAddress

      wsApi* {.
        desc: "Enable specific set of Websocket RPC API from list (comma-separated) (available: eth, debug)"
        defaultValue: RpcApi(value: {RpcFlag.Eth})
        defaultValueDesc: $RpcFlag.Eth
        name: "ws-api" }: RpcApi

      graphqlEnabled* {.
        desc: "Enable the HTTP-GraphQL server"
        defaultValue: false
        name: "graphql" }: bool

      graphqlPort* {.
        desc: "Listening HTTP port for the GraphQL server"
        defaultValue: defaultEthGraphqlPort
        defaultValueDesc: $defaultEthGraphqlPort
        name: "graphql-port" }: Port

      graphqlAddress* {.
        desc: "Listening address of the GraphQL server"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "graphql-address" }: ValidIpAddress

      logLevel* {.
        separator: "\pLOGGING AND DEBUGGING OPTIONS:"
        desc: "Sets the log level for process and topics (" & logLevelDesc & ")"
        defaultValue: LogLevel.INFO
        defaultValueDesc: $LogLevel.INFO
        name: "log-level" }: LogLevel

      logFile* {.
        desc: "Specifies a path for the written Json log file"
        name: "log-file" }: Option[OutFile]

      logMetricsEnabled* {.
        desc: "Enable metrics logging"
        defaultValue: false
        name: "log-metrics" .}: bool

      logMetricsInterval* {.
        desc: "Interval at which to log metrics, in seconds"
        defaultValue: 10
        name: "log-metrics-interval" .}: int

proc parseCmdArg(T: type NetworkId, p: TaintedString): T =
  parseInt(p.string).T

proc completeCmdArg(T: type NetworkId, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg(T: type EthAddress, p: TaintedString): T =
  try:
    result = hexToByteArray(p.string, 20)
  except CatchableError:
    raise newException(ValueError, "failed to parse EthAddress")

proc completeCmdArg(T: type EthAddress, val: TaintedString): seq[string] =
  return @[]

proc processList(v: string, o: var seq[string]) =
  ## Process comma-separated list of strings.
  if len(v) > 0:
    for n in v.split({' ', ','}):
      if len(n) > 0:
        o.add(n)

proc parseCmdArg(T: type EnodeList, p: TaintedString): T =
  var list = newSeq[string]()
  processList(p.string, list)
  for item in list:
    let res = ENode.fromString(item)
    if res.isErr:
      raise newException(ValueError, "failed to parse EnodeList")
    result.value.add res.get()

proc completeCmdArg(T: type EnodeList, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg(T: type Protocols, p: TaintedString): T =
  var list = newSeq[string]()
  processList(p.string, list)
  for item in list:
    case item.toLowerAscii()
    of "eth": result.value.incl ProtocolFlag.Eth
    of "les": result.value.incl ProtocolFlag.Les
    else:
      raise newException(ValueError, "unknown protocol: " & item)

proc completeCmdArg(T: type Protocols, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg(T: type RpcApi, p: TaintedString): T =
  var list = newSeq[string]()
  processList(p.string, list)
  for item in list:
    case item.toLowerAscii()
    of "eth": result.value.incl RpcFlag.Eth
    of "debug": result.value.incl RpcFlag.Debug
    else:
      raise newException(ValueError, "unknown rpc api: " & item)

proc completeCmdArg(T: type RpcApi, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg(T: type CustomNetwork, p: TaintedString): T =
  try:
    if not loadCustomNetwork(p.string, result):
      raise newException(ValueError, "failed to load customNetwork")
  except Exception as exc:
    # on linux/mac, nim compiler refuse to compile
    # with unlisted exception error
    raise newException(ValueError, "failed to load customNetwork")

proc completeCmdArg(T: type CustomNetwork, val: TaintedString): seq[string] =
  return @[]

proc setBootnodes(output: var seq[ENode], nodeUris: openarray[string]) =
  output = newSeqOfCap[ENode](nodeUris.len)
  for item in nodeUris:
    output.add(ENode.fromString(item).tryGet())

proc getBootNodes*(conf: NimbusConf): seq[Enode] =
  if conf.mainnet:
    result.setBootnodes(MainnetBootnodes)
  elif conf.ropsten:
    result.setBootnodes(RopstenBootnodes)
  elif conf.rinkeby:
    result.setBootnodes(RinkebyBootnodes)
  elif conf.goerli:
    result.setBootnodes(GoerliBootnodes)
  elif conf.kovan:
    result.setBootnodes(KovanBootnodes)
  elif conf.bootnodes.value.len > 0:
    result = conf.bootnodes.value
  elif conf.bootnodesv4.value.len > 0:
    result = conf.bootnodesv4.value
  elif conf.bootnodesv5.value.len > 0:
    result = conf.bootnodesv5.value

proc getNetworkId(conf: NimbusConf): Option[NetworkId] =
  if conf.mainnet:
    some MainNet
  elif conf.ropsten:
    some RopstenNet
  elif conf.rinkeby:
    some RinkebyNet
  elif conf.goerli:
    some GoerliNet
  elif conf.kovan:
    some KovanNet
  else:
    conf.networkId

proc makeConfig*(cmdLine = commandLineParams()): NimbusConf =
  {.push warning[ProveInit]: off.}
  result = NimbusConf.load(
    cmdLine,
    version = NimbusBuild,
    copyrightBanner = NimbusHeader
  )
  {.pop.}

  result.networkId = result.getNetworkId()

  if result.networkId.isNone and result.customNetwork.isSome:
    # WARNING: networkId and chainId are two distinct things
    # they usage should not be mixed in other places.
    # We only set networkId to chainId if networkId not set in cli and
    # --custom-network is set.
    # If chainId is not defined in config file, it's ok because
    # the default networkId `CustomNetwork` has 0 value too.
    result.networkId = some(NetworkId(result.customNetwork.get().config.chainId))

  if result.networkId.isNone:
    # bootnodes is set via getBootNodes
    result.networkId = some MainNet
    result.mainnet = true

  if result.udpPort == Port(0):
    # if udpPort not set in cli, then
    result.udpPort = result.tcpPort

  if result.customNetwork.isNone:
    result.customNetwork = some CustomNetwork()

when isMainModule:
  # for testing purpose
  discard makeConfig()
