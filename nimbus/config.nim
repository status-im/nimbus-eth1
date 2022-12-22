# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[
    options,
    strutils,
    times,
    os,
    uri
  ],
  pkg/[
    chronicles,
    confutils,
    confutils/defs,
    stew/byteutils,
    confutils/std/net
  ],
  stew/shims/net as stewNet,
  eth/[common, net/nat, p2p/bootnodes, p2p/enode],
  "."/[db/select_backend,
    constants, vm_compile_info, version
  ],
  common/chain_config

export stewNet

const
  # TODO: fix this agent-string format to match other
  # eth clients format
  NimbusIdent* = "$# v$# [$#: $#, $#, $#, $#]" % [
    NimbusName,
    NimbusVersion,
    hostOS,
    hostCPU,
    nimbus_db_backend,
    VmName,
    GitRevision
  ]

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
    version.NimVersion
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
  defaultEngineApiPort     = 8550
  defaultEngineApiWsPort   = 8551
  defaultListenAddress      = (static ValidIpAddress.init("0.0.0.0"))
  defaultAdminListenAddress = (static ValidIpAddress.init("127.0.0.1"))
  defaultListenAddressDesc      = $defaultListenAddress & ", meaning all network interfaces"
  defaultAdminListenAddressDesc = $defaultAdminListenAddress & ", meaning local host only"
  logLevelDesc = getLogLevels()

# `when` around an option doesn't work with confutils; it fails to compile.
# Workaround that by setting the `ignore` pragma on EVMC-specific options.
when defined(evmc_enabled):
  {.pragma: includeIfEvmc.}
else:
  {.pragma: includeIfEvmc, ignore.}

const sharedLibText = if defined(linux): " (*.so, *.so.N)"
                      elif defined(windows): " (*.dll)"
                      elif defined(macosx): " (*.dylib)"
                      else: ""

type
  PruneMode* {.pure.} = enum
    Full
    Archive

  NimbusCmd* {.pure.} = enum
    noCommand
    `import`

  ProtocolFlag* {.pure.} = enum
    ## Protocol flags
    Eth                           ## enable eth subprotocol
    Les                           ## enable les subprotocol

  RpcFlag* {.pure.} = enum
    ## RPC flags
    Eth                           ## enable eth_ set of RPC API
    Debug                         ## enable debug_ set of RPC API

  DiscoveryType* {.pure.} = enum
    None
    V4
    V5

  SyncMode* {.pure.} = enum
    Default
    Full                          ## Beware, experimental
    Snap                          ## Beware, experimental
    SnapCtx                       ## Beware, experimental

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
      desc: "Load one or more keystore files from this directory"
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

    syncMode* {.
      desc: "Specify particular blockchain sync mode."
      longDesc:
        "- default -- legacy sync mode\n" &
        "- full    -- full blockchain archive\n" &
        "- snap    -- experimental snap mode (development only)\n" &
        "- snapCtx -- snap considering possible recovery context\n"
      defaultValue: SyncMode.Default
      defaultValueDesc: $SyncMode.Default
      abbr: "y"
      name: "sync-mode" .}: SyncMode

    importKey* {.
      desc: "Import unencrypted 32 bytes hex private key from a file"
      defaultValue: ""
      abbr: "e"
      name: "import-key" }: InputFile

    engineSigner* {.
      desc: "Set the signer address(as 20 bytes hex) and enable sealing engine to run and " &
            "producing blocks at specified interval (only PoA/Clique supported)"
      defaultValue: ZERO_ADDRESS
      defaultValueDesc: ""
      abbr: "s"
      name: "engine-signer" }: EthAddress

    verifyFrom* {.
      desc: "Enable extra verification when current block number greater than verify-from"
      defaultValueDesc: ""
      name: "verify-from" }: Option[uint64]

    evm* {.
      desc: "Load alternative EVM from EVMC-compatible shared library" & sharedLibText
      defaultValue: ""
      name: "evm"
      includeIfEvmc }: string

    network {.
      separator: "\pETHEREUM NETWORK OPTIONS:"
      desc: "Name or id number of Ethereum network(mainnet(1), ropsten(3), rinkeby(4), goerli(5), kovan(42), sepolia(11155111), other=custom)"
      longDesc:
        "- mainnet: Ethereum main network\n" &
        "- ropsten: Test network (proof-of-work, the one most like Ethereum mainnet)\n" &
        "- rinkeby: Test network (proof-of-authority, for those running Geth clients)\n" &
        "- goerli:  Test network (proof-of-authority, works across all clients)\n" &
        "- kovan:   Test network (proof-of-authority, for those running OpenEthereum clients)\n" &
        "- sepolia: Test network (proof-of-work)"
      defaultValue: "" # the default value is set in makeConfig
      defaultValueDesc: "mainnet(1)"
      abbr: "i"
      name: "network" }: string

    customNetwork {.
      desc: "Use custom genesis block for private Ethereum Network (as /path/to/genesis.json)"
      defaultValueDesc: ""
      abbr: "c"
      name: "custom-network" }: Option[NetworkParams]

    networkId* {.
      ignore # this field is not processed by confutils
      defaultValue: MainNet # the defaultValue value is set by `makeConfig`
      name: "network-id"}: NetworkId

    networkParams* {.
      ignore # this field is not processed by confutils
      defaultValue: NetworkParams() # the defaultValue value is set by `makeConfig`
      name: "network-params"}: NetworkParams

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

    bootstrapNodes {.
      separator: "\pNETWORKING OPTIONS:"
      desc: "Specifies one or more bootstrap nodes(as enode URL) to use when connecting to the network"
      defaultValue: @[]
      defaultValueDesc: ""
      abbr: "b"
      name: "bootstrap-node" }: seq[string]

    bootstrapFile {.
      desc: "Specifies a line-delimited file of bootstrap Ethereum network addresses(enode URL). " &
            "By default, addresses will be added to bootstrap node list. " &
            "But if the first line equals to `override` word, it will override built-in list"
      defaultValue: ""
      name: "bootstrap-file" }: InputFile

    staticPeers {.
      desc: "Connect to one or more trusted peers(as enode URL)"
      defaultValue: @[]
      defaultValueDesc: ""
      name: "static-peers" }: seq[string]

    staticPeersFile {.
      desc: "Specifies a line-delimited file of trusted peers addresses(enode URL)" &
            "to be added to the --staticPeers list. If the first line equals to the word `override`, "&
            "the file contents will replace the --staticPeers list"
      defaultValue: ""
      name: "static-peers-file" }: InputFile

    reconnectMaxRetry* {.
      desc: "Specifies max number of retries if static peers disconnected/not connected. " &
            "0 = infinite."
      defaultValue: 0
      name: "reconnect-max-retry" }: int

    reconnectInterval* {.
      desc: "Interval in seconds before next attempt to reconnect to static peers. Min 5 seconds."
      defaultValue: 15
      name: "reconnect-interval" }: int

    listenAddress* {.
      desc: "Listening IP address for Ethereum P2P and Discovery traffic"
      defaultValue: defaultListenAddress
      defaultValueDesc: $defaultListenAddressDesc
      name: "listen-address" }: ValidIpAddress

    tcpPort* {.
      desc: "Ethereum P2P network listening TCP port"
      defaultValue: defaultPort
      defaultValueDesc: $defaultPort
      name: "tcp-port" }: Port

    udpPort* {.
      desc: "Ethereum P2P network listening UDP port"
      defaultValue: 0 # set udpPort defaultValue in `makeConfig`
      defaultValueDesc: "default to --tcp-port"
      name: "udp-port" }: Port

    maxPeers* {.
      desc: "Maximum number of peers to connect to"
      defaultValue: 25
      name: "max-peers" }: int

    nat* {.
      desc: "Specify method to use for determining public address. " &
            "Must be one of: any, none, upnp, pmp, extip:<IP>"
      defaultValue: NatConfig(hasExtIp: false, nat: NatAny)
      defaultValueDesc: "any"
      name: "nat" .}: NatConfig

    discovery* {.
      desc: "Specify method to find suitable peer in an Ethereum network (None, V4, V5)"
      longDesc:
        "- None: Disables the peer discovery mechanism (manual peer addition)\n" &
        "- V4  : Node Discovery Protocol v4(default)\n" &
        "- V5  : Node Discovery Protocol v5"
      defaultValue: DiscoveryType.V4
      defaultValueDesc: $DiscoveryType.V4
      name: "discovery" .}: DiscoveryType

    netKey* {.
      desc: "P2P ethereum node (secp256k1) private key (random, path, hex)"
      longDesc:
        "- random: generate random network key for this node instance\n" &
        "- path  : path to where the private key will be loaded or auto generated\n" &
        "- hex   : 32 bytes hex of network private key"
      defaultValue: "random"
      name: "net-key" .}: string

    agentString* {.
      desc: "Node agent string which is used as identifier in network"
      defaultValue: NimbusIdent
      defaultValueDesc: $NimbusIdent
      name: "agent-string" .}: string

    protocols {.
      desc: "Enable specific set of protocols (available: Eth, Les)"
      defaultValue: @[]
      defaultValueDesc: $ProtocolFlag.Eth
      name: "protocols" .}: seq[string]

    case cmd* {.
      command
      defaultValue: NimbusCmd.noCommand }: NimbusCmd

    of noCommand:
      rpcEnabled* {.
        separator: "\pLOCAL SERVICE OPTIONS:"
        desc: "Enable the JSON-RPC server"
        defaultValue: false
        name: "rpc" }: bool

      rpcPort* {.
        desc: "Listening port of the JSON-RPC server"
        defaultValue: defaultEthRpcPort
        defaultValueDesc: $defaultEthRpcPort
        name: "rpc-port" }: Port

      rpcAddress* {.
        desc: "Listening IP address of the JSON-RPC server"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "rpc-address" }: ValidIpAddress

      rpcApi {.
        desc: "Enable specific set of RPC API (available: eth, debug)"
        defaultValue: @[]
        defaultValueDesc: $RpcFlag.Eth
        name: "rpc-api" }: seq[string]

      wsEnabled* {.
        desc: "Enable the Websocket JSON-RPC server"
        defaultValue: false
        name: "ws" }: bool

      wsPort* {.
        desc: "Listening port of the Websocket JSON-RPC server"
        defaultValue: defaultEthWsPort
        defaultValueDesc: $defaultEthWsPort
        name: "ws-port" }: Port

      wsAddress* {.
        desc: "Listening IP address of the Websocket JSON-RPC server"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "ws-address" }: ValidIpAddress

      wsApi {.
        desc: "Enable specific set of Websocket RPC API (available: eth, debug)"
        defaultValue: @[]
        defaultValueDesc: $RpcFlag.Eth
        name: "ws-api" }: seq[string]

      engineApiEnabled* {.
        desc: "Enable the Engine API"
        defaultValue: false
        name: "engine-api" .}: bool

      engineApiPort* {.
        desc: "Listening port for the Engine API"
        defaultValue: defaultEngineApiPort
        defaultValueDesc: $defaultEngineApiPort
        name: "engine-api-port" .}: Port

      engineApiAddress* {.
        desc: "Listening address for the Engine API"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "engine-api-address" .}: ValidIpAddress

      engineApiWsEnabled* {.
        desc: "Enable the WebSocket Engine API"
        defaultValue: false
        name: "engine-api-ws" .}: bool

      engineApiWsPort* {.
        desc: "Listening port for the WebSocket Engine API"
        defaultValue: defaultEngineApiWsPort
        defaultValueDesc: $defaultEngineApiWsPort
        name: "engine-api-ws-port" .}: Port

      engineApiWsAddress* {.
        desc: "Listening address for the WebSocket Engine API"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "engine-api-ws-address" .}: ValidIpAddress

      terminalTotalDifficulty* {.
        desc: "The terminal total difficulty of the eth2 merge transition block." &
              " It takes precedence over terminalTotalDifficulty in config file."
        name: "terminal-total-difficulty" .}: Option[UInt256]

      allowedOrigins* {.
        desc: "Comma separated list of domains from which to accept cross origin requests"
        defaultValue: @[]
        defaultValueDesc: "*"
        name: "allowed-origins" .}: seq[string]

      # github.com/ethereum/execution-apis/
      #   /blob/v1.0.0-alpha.8/src/engine/authentication.md#key-distribution
      jwtSecret* {.
        desc: "Path to a file containing a 32 byte hex-encoded shared secret" &
          " needed for websocket authentication. By default, the secret key" &
          " is auto-generated."
        defaultValueDesc: "\"jwt.hex\" in the data directory (see --data-dir)"
        name: "jwt-secret" .}: Option[InputFile]

      graphqlEnabled* {.
        desc: "Enable the GraphQL HTTP server"
        defaultValue: false
        name: "graphql" }: bool

      graphqlPort* {.
        desc: "Listening port of the GraphQL HTTP server"
        defaultValue: defaultEthGraphqlPort
        defaultValueDesc: $defaultEthGraphqlPort
        name: "graphql-port" }: Port

      graphqlAddress* {.
        desc: "Listening IP address of the GraphQL HTTP server"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "graphql-address" }: ValidIpAddress

      metricsEnabled* {.
        desc: "Enable the built-in metrics HTTP server"
        defaultValue: false
        name: "metrics" }: bool

      metricsPort* {.
        desc: "Listening port of the built-in metrics HTTP server"
        defaultValue: defaultMetricsServerPort
        defaultValueDesc: $defaultMetricsServerPort
        name: "metrics-port" }: Port

      metricsAddress* {.
        desc: "Listening IP address of the built-in metrics HTTP server"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "metrics-address" }: ValidIpAddress

    of `import`:

      blocksFile* {.
        argument
        desc: "Import RLP encoded block(s) from a file, validate, write to database and quit"
        defaultValue: ""
        name: "blocks-file" }: InputFile

proc parseCmdArg(T: type NetworkId, p: TaintedString): T =
  parseInt(p.string).T

proc completeCmdArg(T: type NetworkId, val: TaintedString): seq[string] =
  return @[]

proc parseCmdArg(T: type UInt256, p: TaintedString): T =
  parse(string p, T)

proc completeCmdArg(T: type UInt256, val: TaintedString): seq[string] =
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

proc parseCmdArg(T: type NetworkParams, p: TaintedString): T =
  try:
    if not loadNetworkParams(p.string, result):
      raise newException(ValueError, "failed to load customNetwork")
  except Exception as exc:
    # on linux/mac, nim compiler refuse to compile
    # with unlisted exception error
    raise newException(ValueError, "failed to load customNetwork")

proc completeCmdArg(T: type NetworkParams, val: TaintedString): seq[string] =
  return @[]

proc setBootnodes(output: var seq[ENode], nodeUris: openArray[string]) =
  output = newSeqOfCap[ENode](nodeUris.len)
  for item in nodeUris:
    output.add(ENode.fromString(item).tryGet())

iterator repeatingList(listOfList: openArray[string]): string =
  for strList in listOfList:
    var list = newSeq[string]()
    processList(strList, list)
    for item in list:
      yield item

proc append(output: var seq[ENode], nodeUris: openArray[string]) =
  for item in repeatingList(nodeUris):
    let res = ENode.fromString(item)
    if res.isErr:
      warn "Ignoring invalid bootstrap address", address=item
      continue
    output.add res.get()

iterator strippedLines(filename: string): (int, string) =
  var i = 0
  for line in lines(filename):
    let stripped = strip(line)
    if stripped.startsWith('#'): # Comments
      continue

    if stripped.len > 0:
      yield (i, stripped)
      inc i

proc loadEnodeFile(fileName: string; output: var seq[ENode]; info: string) =
  if fileName.len == 0:
    return

  try:
    for i, ln in strippedLines(fileName):
      if cmpIgnoreCase(ln, "override") == 0 and i == 0:
        # override built-in list if the first line is 'override'
        output = newSeq[ENode]()
        continue

      let res = ENode.fromString(ln)
      if res.isErr:
        warn "Ignoring invalid address", address=ln, line=i, file=fileName, purpose=info
        continue

      output.add res.get()

  except IOError as e:
    error "Could not read file", msg = e.msg, purpose = info
    quit 1

proc loadBootstrapFile(fileName: string, output: var seq[ENode]) =
  fileName.loadEnodeFile(output, "bootstrap")

proc loadStaticPeersFile(fileName: string, output: var seq[ENode]) =
  fileName.loadEnodeFile(output, "static peers")

proc getNetworkId(conf: NimbusConf): Option[NetworkId] =
  if conf.network.len == 0:
    return none NetworkId

  let network = toLowerAscii(conf.network)
  case network
  of "mainnet": return some MainNet
  of "ropsten": return some RopstenNet
  of "rinkeby": return some RinkebyNet
  of "goerli" : return some GoerliNet
  of "kovan"  : return some KovanNet
  of "sepolia": return some SepoliaNet
  else:
    try:
      some parseInt(network).NetworkId
    except CatchableError:
      error "Failed to parse network name or id", network
      quit QuitFailure

proc getProtocolFlags*(conf: NimbusConf): set[ProtocolFlag] =
  if conf.protocols.len == 0:
    return {ProtocolFlag.Eth}

  for item in repeatingList(conf.protocols):
    case item.toLowerAscii()
    of "eth": result.incl ProtocolFlag.Eth
    of "les": result.incl ProtocolFlag.Les
    else:
      error "Unknown protocol", name=item
      quit QuitFailure

proc getRpcFlags(api: openArray[string]): set[RpcFlag] =
  if api.len == 0:
    return {RpcFlag.Eth}

  for item in repeatingList(api):
    case item.toLowerAscii()
    of "eth": result.incl RpcFlag.Eth
    of "debug": result.incl RpcFlag.Debug
    else:
      error "Unknown RPC API: ", name=item
      quit QuitFailure

proc getRpcFlags*(conf: NimbusConf): set[RpcFlag] =
  getRpcFlags(conf.rpcApi)

proc getWsFlags*(conf: NimbusConf): set[RpcFlag] =
  getRpcFlags(conf.wsApi)

proc getBootNodes*(conf: NimbusConf): seq[ENode] =
  # Ignore standard bootnodes if customNetwork is loaded
  if conf.customNetwork.isNone:
    case conf.networkId
    of MainNet:
      result.setBootnodes(MainnetBootnodes)
    of RopstenNet:
      result.setBootnodes(RopstenBootnodes)
    of RinkebyNet:
      result.setBootnodes(RinkebyBootnodes)
    of GoerliNet:
      result.setBootnodes(GoerliBootnodes)
    of KovanNet:
      result.setBootnodes(KovanBootnodes)
    of SepoliaNet:
      result.setBootnodes(SepoliaBootnodes)
    else:
      # custom network id
      discard

  # always allow custom boostrap nodes
  # if it is set by user
  if conf.bootstrapNodes.len > 0:
    result.append(conf.bootstrapNodes)

  # bootstrap nodes loaded from file might append or
  # override built-in bootnodes
  loadBootstrapFile(string conf.bootstrapFile, result)

proc getStaticPeers*(conf: NimbusConf): seq[ENode] =
  result.append(conf.staticPeers)
  loadStaticPeersFile(string conf.staticPeersFile, result)

proc getAllowedOrigins*(conf: NimbusConf): seq[Uri] =
  for item in repeatingList(conf.allowedOrigins):
    result.add parseUri(item)

proc makeConfig*(cmdLine = commandLineParams()): NimbusConf =
  {.push warning[ProveInit]: off.}
  result = NimbusConf.load(
    cmdLine,
    version = NimbusBuild,
    copyrightBanner = NimbusHeader
  )
  {.pop.}

  var networkId = result.getNetworkId()

  if result.customNetwork.isSome:
    result.networkParams = result.customNetwork.get()
    if networkId.isNone:
      # WARNING: networkId and chainId are two distinct things
      # they usage should not be mixed in other places.
      # We only set networkId to chainId if networkId not set in cli and
      # --custom-network is set.
      # If chainId is not defined in config file, it's ok because
      # zero means CustomNet
      networkId = some(NetworkId(result.networkParams.config.chainId))

  if networkId.isNone:
    # bootnodes is set via getBootNodes
    networkId = some MainNet

  result.networkId = networkId.get()

  if result.customNetwork.isNone:
    result.networkParams = networkParams(result.networkId)

  if result.cmd == noCommand:
    # ttd from cli takes precedence over ttd from config-file
    if result.terminalTotalDifficulty.isSome:
      result.networkParams.config.terminalTotalDifficulty =
        result.terminalTotalDifficulty

    if result.udpPort == Port(0):
      # if udpPort not set in cli, then
      result.udpPort = result.tcpPort

    # enable rpc server or ws server if they share common port with engine api
    let rpcMustEnabled = result.engineApiEnabled and (result.engineApiPort == result.rpcPort)
    let wsMustEnabled = result.engineApiWsEnabled and (result.engineApiWsPort == result.wsPort)

    result.rpcEnabled = result.rpcEnabled or rpcMustEnabled
    result.wsEnabled = result.wsEnabled or wsMustEnabled

  # see issue #1346
  if result.keyStore.string == defaultKeystoreDir() and
     result.dataDir.string != defaultDataDir():
    result.keyStore = OutDir(result.dataDir.string / "keystore")

when isMainModule:
  # for testing purpose
  discard makeConfig()
