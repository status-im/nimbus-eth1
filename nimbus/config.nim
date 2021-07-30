# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  parseopt, strutils, macros, os, times, json, tables, stew/[byteutils],
  chronos, eth/[keys, common, p2p, net/nat], chronicles, nimcrypto/hash,
  eth/p2p/bootnodes, ./db/select_backend, eth/keys, ./chain_config, ./forks

const
  NimbusName* = "Nimbus"
  ## project name string

  NimbusMajor*: int = 0
  ## is the major number of Nimbus' version.

  NimbusMinor*: int = 0
  ## is the minor number of Nimbus' version.

  NimbusPatch*: int = 1
  ## is the patch number of Nimbus' version.

  NimbusVersion* = $NimbusMajor & "." & $NimbusMinor & "." & $NimbusPatch
  ## is the version of Nimbus as a string.

  NimbusIdent* = "$1/$2 ($3/$4)" % [NimbusName, NimbusVersion, hostCPU, hostOS]
  ## project ident name for networking services

  GitRevision = staticExec("git rev-parse --short HEAD").replace("\n") # remove CR

  NimVersion = staticExec("nim --version")

let
  NimbusCopyright* = "Copyright (c) 2018-" & $(now().utc.year) & " Status Research & Development GmbH"
  NimbusHeader* = "$# Version $# [$#: $#, $#, $#]\p$#\p\p$#\p" %
    [NimbusName, NimbusVersion, hostOS, hostCPU, nimbus_db_backend, GitRevision, NimbusCopyright, NimVersion]

type
  ConfigStatus* = enum
    ## Configuration status flags
    Success,                      ## Success
    EmptyOption,                  ## No options in category
    ErrorUnknownOption,           ## Unknown option in command line found
    ErrorParseOption,             ## Error in parsing command line option
    ErrorIncorrectOption,         ## Option has incorrect value
    Error                         ## Unspecified error

  RpcFlags* {.pure.} = enum
    ## RPC flags
    Enabled                       ## RPC enabled
    Eth                           ## enable eth_ set of RPC API
    Debug                         ## enable debug_ set of RPC API

  ProtocolFlags* {.pure.} = enum
    ## Protocol flags
    Eth                           ## enable eth subprotocol
    Les                           ## enable les subprotocol

  RpcConfiguration* = object
    ## JSON-RPC configuration object
    flags*: set[RpcFlags]         ## RPC flags
    binds*: seq[TransportAddress] ## RPC bind address

  GraphqlConfiguration* = object
    enabled*: bool
    address*: TransportAddress

  NetworkFlags* = enum
    ## Ethereum network flags
    NoDiscover                   ## Peer discovery disabled
    V5Discover                   ## Dicovery V5 enabled
    NetworkIdSet                 ## prevent CustomNetwork replacement

  DebugFlags* {.pure.} = enum
    ## Debug selection flags
    Enabled,                      ## Debugging enabled
    Test1,                        ## Test1 enabled
    Test2,                        ## Test2 enabled
    Test3                         ## Test3 enabled

  NetConfiguration* = object
    ## Network configuration object
    flags*: set[NetworkFlags]     ## Network flags
    bootNodes*: seq[ENode]        ## List of bootnodes
    staticNodes*: seq[ENode]      ## List of static nodes to connect to
    customBootNodes*: seq[ENode]
    bindPort*: uint16             ## Main TCP bind port
    discPort*: uint16             ## Discovery UDP bind port
    metricsServer*: bool          ## Enable metrics server
    metricsServerPort*: uint16    ## metrics HTTP server port
    maxPeers*: int                ## Maximum allowed number of peers
    maxPendingPeers*: int         ## Maximum allowed pending peers
    networkId*: NetworkId         ## Network ID as integer
    ident*: string                ## Server ident name string
    nodeKey*: PrivateKey          ## Server private key
    nat*: NatStrategy             ## NAT strategy
    externalIP*: string           ## user-provided external IP
    protocols*: set[ProtocolFlags]## Enabled subprotocols

  DebugConfiguration* = object
    ## Debug configuration object
    flags*: set[DebugFlags]       ## Debug flags
    logLevel*: LogLevel           ## Log level
    logFile*: string              ## Log file
    logMetrics*: bool             ## Enable metrics logging
    logMetricsInterval*: int      ## Metrics logging interval

  PruneMode* {.pure.} = enum
    Full
    Archive

  NimbusAccount* = object
    privateKey*: PrivateKey
    keystore*: JsonNode
    unlocked*: bool

  NimbusConfiguration* = ref object
    ## Main Nimbus configuration object
    dataDir*: string
    keyStore*: string
    prune*: PruneMode
    graphql*: GraphqlConfiguration
    rpc*: RpcConfiguration        ## JSON-RPC configuration
    net*: NetConfiguration        ## Network configuration
    debug*: DebugConfiguration    ## Debug configuration
    customGenesis*: CustomGenesis ## Custom Genesis Configuration
    # You should only create one instance of the RNG per application / library
    # Ref is used so that it can be shared between components
    rng*: ref BrHmacDrbgContext
    accounts*: Table[EthAddress, NimbusAccount]
    importFile*: string
    verifyFromOk*: bool           ## activate `verifyFrom` setting
    verifyFrom*: uint64           ## verification start block, 0 for disable

const
  # these are public network id
  CustomNet*  = 0.NetworkId
  MainNet*    = 1.NetworkId
  # No longer used: MordenNet = 2
  RopstenNet* = 3.NetworkId
  RinkebyNet* = 4.NetworkId
  GoerliNet*  = 5.NetworkId
  KovanNet*   = 42.NetworkId

const
  defaultRpcApi = {RpcFlags.Eth}
  defaultProtocols = {ProtocolFlags.Eth}
  defaultLogLevel = LogLevel.WARN
  defaultNetwork = MainNet

var nimbusConfig {.threadvar.}: NimbusConfiguration

proc getConfiguration*(): NimbusConfiguration {.gcsafe.}

proc `$`*(c: ChainId): string =
  $(c.int)

proc toFork*(c: ChainConfig, number: BlockNumber): Fork =
  if number >= c.londonBlock: FkLondon
  elif number >= c.berlinBlock: FkBerlin
  elif number >= c.istanbulBlock: FkIstanbul
  elif number >= c.petersburgBlock: FkPetersburg
  elif number >= c.constantinopleBlock: FkConstantinople
  elif number >= c.byzantiumBlock: FkByzantium
  elif number >= c.eip158Block: FkSpurious
  elif number >= c.eip150Block: FkTangerine
  elif number >= c.homesteadBlock: FkHomestead
  else: FkFrontier

proc chainConfig*(id: NetworkId): ChainConfig =
  # For some public networks, NetworkId and ChainId value are identical
  # but that is not always the case

  result = case id
  of MainNet:
    ChainConfig(
      poaEngine: false, # TODO: use real engine conf: PoW
      chainId:        MainNet.ChainId,
      homesteadBlock: 1_150_000.toBlockNumber, # 14/03/2016 20:49:53
      daoForkBlock:   1_920_000.toBlockNumber,
      daoForkSupport: true,
      eip150Block:    2_463_000.toBlockNumber, # 18/10/2016 17:19:31
      eip150Hash:     toDigest("2086799aeebeae135c246c65021c82b4e15a2c451340993aacfd2751886514f0"),
      eip155Block:    2_675_000.toBlockNumber, # 22/11/2016 18:15:44
      eip158Block:    2_675_000.toBlockNumber,
      byzantiumBlock: 4_370_000.toBlockNumber, # 16/10/2017 09:22:11
      constantinopleBlock: 7_280_000.toBlockNumber, # Never Occured in MainNet
      petersburgBlock:7_280_000.toBlockNumber, # 28/02/2019 07:52:04
      istanbulBlock:  9_069_000.toBlockNumber, # 08/12/2019 12:25:09
      muirGlacierBlock: 9_200_000.toBlockNumber, # 02/01/2020 08:30:49
      berlinBlock:    12_244_000.toBlockNumber, # 15/04/2021 10:07:03
      londonBlock:    high(BlockNumber)
    )
  of RopstenNet:
    ChainConfig(
      poaEngine: false, # TODO: use real engine conf: PoW
      chainId:        RopstenNet.ChainId,
      homesteadBlock: 0.toBlockNumber,
      daoForkSupport: false,
      eip150Block:    0.toBlockNumber,
      eip150Hash:     toDigest("41941023680923e0fe4d74a34bdac8141f2540e3ae90623718e47d66d1ca4a2d"),
      eip155Block:    10.toBlockNumber,
      eip158Block:    10.toBlockNumber,
      byzantiumBlock: 1_700_000.toBlockNumber,
      constantinopleBlock: 4_230_000.toBlockNumber,
      petersburgBlock:4_939_394.toBlockNumber,
      istanbulBlock:  6_485_846.toBlockNumber,
      muirGlacierBlock: 7_117_117.toBlockNumber,
      berlinBlock:      9_812_189.toBlockNumber,
      londonBlock:    high(BlockNumber)
    )
  of RinkebyNet:
    ChainConfig(
      poaEngine: true, # TODO: use real engine conf: PoA
      chainId:        RinkebyNet.ChainId,
      homesteadBlock: 1.toBlockNumber,
      daoForkSupport: false,
      eip150Block:    2.toBlockNumber,
      eip150Hash:     toDigest("9b095b36c15eaf13044373aef8ee0bd3a382a5abb92e402afa44b8249c3a90e9"),
      eip155Block:    3.toBlockNumber,
      eip158Block:    3.toBlockNumber,
      byzantiumBlock: 1_035_301.toBlockNumber,
      constantinopleBlock: 3_660_663.toBlockNumber,
      petersburgBlock:4_321_234.toBlockNumber,
      istanbulBlock:  5_435_345.toBlockNumber,
      muirGlacierBlock: 8_290_928.toBlockNumber, # never occured in rinkeby network
      berlinBlock:      8_290_928.toBlockNumber,
      londonBlock:    high(BlockNumber)
    )
  of GoerliNet:
    ChainConfig(
      poaEngine: true, # TODO: use real engine conf: PoA
      chainId:        GoerliNet.ChainId,
      homesteadBlock: 0.toBlockNumber,
      daoForkSupport: false,
      eip150Block:    0.toBlockNumber,
      eip150Hash:     toDigest("0000000000000000000000000000000000000000000000000000000000000000"),
      eip155Block:    0.toBlockNumber,
      eip158Block:    0.toBlockNumber,
      byzantiumBlock: 0.toBlockNumber,
      constantinopleBlock: 0.toBlockNumber,
      petersburgBlock: 0.toBlockNumber,
      istanbulBlock:  1_561_651.toBlockNumber,
      muirGlacierBlock: 4_460_644.toBlockNumber, # never occured in goerli network
      berlinBlock:    4_460_644.toBlockNumber,
      londonBlock:    high(BlockNumber)
    )
  else:
    # everything else will use CustomNet config
    let conf = getConfiguration()
    trace "Custom genesis block configuration loaded", conf=conf.customGenesis.config
    conf.customGenesis.config

proc processList(v: string, o: var seq[string]) =
  ## Process comma-separated list of strings.
  if len(v) > 0:
    for n in v.split({' ', ','}):
      if len(n) > 0:
        o.add(n)

proc processInteger*(v: string, o: var int): ConfigStatus =
  ## Convert string to integer.
  try:
    o  = parseInt(v)
    result = Success
  except ValueError:
    result = ErrorParseOption

proc processUInt64*(v: string, o: var uint64): ConfigStatus =
  ## Convert string to integer.
  try:
    o = parseBiggestUInt(v).uint64
    result = Success
  except ValueError:
    result = ErrorParseOption

proc processFloat*(v: string, o: var float): ConfigStatus =
  ## Convert string to float.
  try:
    o  = parseFloat(v)
    result = Success
  except ValueError:
    result = ErrorParseOption

proc processAddressPort(addrStr: string, ta: var TransportAddress): ConfigStatus =
  try:
    ta = initTAddress(addrStr)
    return Success
  except CatchableError:
    return ErrorParseOption

proc processAddressPortsList(v: string,
                             o: var seq[TransportAddress]): ConfigStatus =
  ## Convert <hostname:port>;...;<hostname:port> to list of `TransportAddress`.
  var list = newSeq[string]()
  processList(v, list)
  for item in list:
    var ta: TransportAddress
    if processAddressPort(item, ta) == Success:
      o.add ta
    else:
      return ErrorParseOption
  result = Success

proc processRpcApiList(v: string, flags: var set[RpcFlags]): ConfigStatus =
  var list = newSeq[string]()
  processList(v, list)
  result = Success
  for item in list:
    case item.toLowerAscii()
    of "eth": flags.incl RpcFlags.Eth
    of "debug": flags.incl RpcFlags.Debug
    else:
      warn "unknown rpc api", name = item
      result = ErrorIncorrectOption

proc processProtocolList(v: string, flags: var set[ProtocolFlags]): ConfigStatus =
  var list = newSeq[string]()
  processList(v, list)
  result = Success
  for item in list:
    case item.toLowerAscii()
    of "eth": flags.incl ProtocolFlags.Eth
    of "les": flags.incl ProtocolFlags.Les
    else:
      warn "unknown protocol", name = item
      result = ErrorIncorrectOption

proc processENode(v: string, o: var ENode): ConfigStatus =
  ## Convert string to ENode.
  let res = ENode.fromString(v)
  if res.isOk:
    o = res[]
    result = Success
  else:
    result = ErrorParseOption

proc processENodesList(v: string, o: var seq[ENode]): ConfigStatus =
  ## Convert comma-separated list of strings to list of ENode.
  var
    node: ENode
    list = newSeq[string]()
  processList(v, list)
  for item in list:
    result = processENode(item, node)
    if result == Success:
      o.add(node)
    else:
      break

proc processPrivateKey(v: string, o: var PrivateKey): ConfigStatus =
  ## Convert hexadecimal string to private key object.
  let seckey = PrivateKey.fromHex(v)
  if seckey.isOk():
    o = seckey[]
    return Success

  result = ErrorParseOption

proc processPruneList(v: string, flags: var PruneMode): ConfigStatus =
  var list = newSeq[string]()
  processList(v, list)
  result = Success
  for item in list:
    case item.toLowerAscii()
    of "full": flags = PruneMode.Full
    of "archive": flags = PruneMode.Archive
    else:
      warn "unknown prune flags", name = item
      result = ErrorIncorrectOption

proc processEthArguments(key, value: string): ConfigStatus =
  result = Success
  let config = getConfiguration()
  case key.toLowerAscii()
  of "keystore":
    config.keyStore = value
  of "datadir":
    config.dataDir = value
  of "prune":
    result = processPruneList(value, config.prune)
  of "import":
    config.importFile = value
  of "verifyfrom":
    var res = 0u64
    result = processUInt64(value, res)
    config.verifyFrom = uint64(result)
    config.verifyFromOk = true
  else:
    result = EmptyOption

proc processRpcArguments(key, value: string): ConfigStatus =
  ## Processes only `RPC` related command line options
  result = Success
  let config = getConfiguration()
  let skey = key.toLowerAscii()
  if skey == "rpc":
    if RpcFlags.Enabled notin config.rpc.flags:
      config.rpc.flags.incl(RpcFlags.Enabled)
      config.rpc.flags.incl(defaultRpcApi)
  elif skey == "rpcbind":
    config.rpc.binds.setLen(0)
    result = processAddressPortsList(value, config.rpc.binds)
  elif skey == "rpcapi":
    if RpcFlags.Enabled in config.rpc.flags:
      config.rpc.flags.excl(defaultRpcApi)
    else:
      config.rpc.flags.incl(RpcFlags.Enabled)
    result = processRpcApiList(value, config.rpc.flags)
  else:
    result = EmptyOption

proc processGraphqlArguments(key, value: string): ConfigStatus =
  ## Processes only `Graphql` related command line options
  result = Success
  let conf = getConfiguration()
  case key.toLowerAscii()
  of "graphql":
    conf.graphql.enabled = true
  of "graphqlbind":
    result = processAddressPort(value, conf.graphql.address)
  else:
    result = EmptyOption

proc setBootnodes(onodes: var seq[ENode], nodeUris: openarray[string]) =
  var node: ENode
  onodes = newSeqOfCap[ENode](nodeUris.len)
  for item in nodeUris:
    doAssert(processENode(item, node) == Success)
    onodes.add(node)


proc setNetwork(conf: var NetConfiguration, id: NetworkId) =
  ## Set network id and default network bootnodes
  conf.networkId = id
  case id
  of MainNet:
    conf.bootNodes.setBootnodes(MainnetBootnodes)
  of RopstenNet:
    conf.bootNodes.setBootnodes(RopstenBootnodes)
  of RinkebyNet:
    conf.bootNodes.setBootnodes(RinkebyBootnodes)
  of GoerliNet:
    conf.bootNodes.setBootnodes(GoerliBootnodes)
  of KovanNet:
    conf.bootNodes.setBootnodes(KovanBootnodes)
  else:
    # everything else will use bootnodes
    # from --bootnodes switch
    discard

proc processNetArguments(key, value: string): ConfigStatus =
  ## Processes only `Networking` related command line options
  result = Success
  let config = getConfiguration()
  let skey = key.toLowerAscii()
  if skey == "bootnodes":
    result = processENodesList(value, config.net.customBootNodes)
  elif skey == "bootnodesv4":
    result = processENodesList(value, config.net.customBootNodes)
  elif skey == "bootnodesv5":
    result = processENodesList(value, config.net.customBootNodes)
  elif skey == "staticnodes":
    result = processENodesList(value, config.net.staticNodes)
  elif skey == "testnet":
    config.net.setNetwork(RopstenNet)
  elif skey == "mainnet":
    config.net.setNetwork(MainNet)
  elif skey == "ropsten":
    config.net.setNetwork(RopstenNet)
  elif skey == "rinkeby":
    config.net.setNetwork(RinkebyNet)
  elif skey == "goerli":
    config.net.setNetwork(GoerliNet)
  elif skey == "kovan":
    config.net.setNetwork(KovanNet)
  elif skey == "customnetwork":
    if not loadCustomGenesis(value, config.customGenesis):
      result = Error
    if NetworkIdSet notin config.net.flags:
      # prevent clash with --networkid if it already set
      # because any --networkid value that is not
      # in the public network will also translated as
      # CustomNetwork
      config.net.networkId = CustomNet
  elif skey == "networkid":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.net.setNetwork(NetworkId(result))
      config.net.flags.incl NetworkIdSet
  elif skey == "nodiscover":
    config.net.flags.incl(NoDiscover)
  elif skey == "v5discover":
    config.net.flags.incl(V5Discover)
    config.net.customBootNodes.setBootnodes(DiscoveryV5Bootnodes)
  elif skey == "port":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.net.bindPort = uint16(res and 0xFFFF)
  elif skey == "discport":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.net.discPort = uint16(res and 0xFFFF)
  elif skey == "metrics":
    config.net.metricsServer = true
  elif skey == "metricsport":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.net.metricsServerPort = uint16(res and 0xFFFF)
  elif skey == "maxpeers":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.net.maxPeers = res
  elif skey == "maxpendpeers":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.net.maxPendingPeers = res
  elif skey == "nodekey":
    var res: PrivateKey
    result = processPrivateKey(value, res)
    if result == Success:
      config.net.nodeKey = res
  elif skey == "ident":
    config.net.ident = value
  elif skey == "nat":
    case value.toLowerAscii:
      of "any":
        config.net.nat = NatAny
      of "upnp":
        config.net.nat = NatUpnp
      of "pmp":
        config.net.nat = NatPmp
      of "none":
        config.net.nat = NatNone
      else:
        if isIpAddress(value):
          config.net.externalIP = value
          config.net.nat = NatNone
        else:
          error "not a valid NAT mechanism, nor a valid IP address", value
          result = ErrorParseOption
  elif skey == "protocols":
    config.net.protocols = {}
    result = processProtocolList(value, config.net.protocols)
  else:
    result = EmptyOption

proc processDebugArguments(key, value: string): ConfigStatus =
  ## Processes only `Debug` related command line options
  let config = getConfiguration()
  result = Success
  let skey = key.toLowerAscii()
  if skey == "debug":
    config.debug.flags.incl(DebugFlags.Enabled)
  elif skey == "test":
    var res = newSeq[string]()
    processList(value, res)
    for item in res:
      if item == "test1":
        config.debug.flags.incl(DebugFlags.Test1)
      elif item == "test2":
        config.debug.flags.incl(DebugFlags.Test2)
      elif item == "test3":
        config.debug.flags.incl(DebugFlags.Test3)
  elif skey == "log-level":
    try:
      let logLevel = parseEnum[LogLevel](value)
      if logLevel >= enabledLogLevel:
        config.debug.logLevel = logLevel
      else:
        result = ErrorIncorrectOption
    except ValueError:
      result = ErrorIncorrectOption
  elif skey == "log-file":
    if len(value) == 0:
      result = ErrorIncorrectOption
    else:
      config.debug.logFile = value
  elif skey == "logmetrics":
    config.debug.logMetrics = true
  elif skey == "logmetricsinterval":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.debug.logMetricsInterval = res
  else:
    result = EmptyOption

proc dumpConfiguration*(): string =
  ## Dumps current configuration as string
  let config = getConfiguration()
  result = repr config

template processArgument(processor, key, value, msg: untyped) =
  ## Checks if arguments got processed successfully
  var res = processor(string(key), string(value))
  if res == Success:
    result = res
    continue
  elif res == ErrorParseOption:
    msg = "Error processing option '" & key & "' with value '" & value & "'."
    result = res
    break
  elif res == ErrorIncorrectOption:
    msg = "Incorrect value for option '" & key & "': '" & value & "'."
    result = res
    break

proc getDefaultDataDir*(): string =
  when defined(windows):
    "AppData" / "Roaming" / "Nimbus"
  elif defined(macosx):
    "Library" / "Application Support" / "Nimbus"
  else:
    ".cache" / "nimbus"

proc getDefaultKeystoreDir*(): string =
  getDefaultDataDir() / "keystore"

proc initConfiguration(): NimbusConfiguration =
  ## Allocates and initializes `NimbusConfiguration` with default values
  result = new NimbusConfiguration
  result.rng = newRng()
  result.accounts = initTable[EthAddress, NimbusAccount]()

  ## Graphql defaults
  result.graphql.enabled = false
  result.graphql.address = initTAddress("127.0.0.1:8547")

  ## RPC defaults
  result.rpc.flags = {}
  result.rpc.binds = @[initTAddress("127.0.0.1:8545")]

  ## Network defaults
  result.net.setNetwork(defaultNetwork)
  result.net.maxPeers = 25
  result.net.maxPendingPeers = 0
  result.net.bindPort = 30303'u16
  result.net.discPort = 30303'u16
  result.net.metricsServer = false
  result.net.metricsServerPort = 9093'u16
  result.net.ident = NimbusIdent
  result.net.nat = NatAny
  result.net.protocols = defaultProtocols
  result.net.nodekey = random(PrivateKey, result.rng[])

  const
    dataDir = getDefaultDataDir()
    keystore = getDefaultKeystoreDir()

  result.dataDir = getHomeDir() / dataDir
  result.keystore = getHomeDir() / keystore
  result.prune = PruneMode.Full

  ## Debug defaults
  result.debug.flags = {}
  result.debug.logLevel = defaultLogLevel
  result.debug.logMetrics = false
  result.debug.logMetricsInterval = 10

proc getConfiguration*(): NimbusConfiguration =
  ## Retreive current configuration object `NimbusConfiguration`.
  if isNil(nimbusConfig):
    nimbusConfig = initConfiguration()
  result = nimbusConfig

proc getHelpString*(): string =
  var logLevels: seq[string]
  for level in LogLevel:
    if level < enabledLogLevel:
      continue
    logLevels.add($level)

  result = """

USAGE:
  nimbus [options]

ETHEREUM OPTIONS:
  --datadir:<value>       Base directory for all blockchain-related data
  --keystore:<value>      Directory for the keystore (default: inside datadir)
  --prune:<value>         Blockchain prune mode (full or archive, default: full)
  --import:<path>         Import RLP encoded block(s), validate, write to database and quit

NETWORKING OPTIONS:
  --bootnodes:<value>     Comma separated enode URLs for P2P discovery bootstrap (set v4+v5 instead for light servers)
  --bootnodesv4:<value>   Comma separated enode URLs for P2P v4 discovery bootstrap (light server, full nodes)
  --bootnodesv5:<value>   Comma separated enode URLs for P2P v5 discovery bootstrap (light server, light nodes)
  --staticnodes:<value>   Comma separated enode URLs to connect with
  --port:<value>          Network listening TCP port (default: 30303)
  --discport:<value>      Network listening UDP port (defaults to --port argument)
  --maxpeers:<value>      Maximum number of network peers (default: 25)
  --maxpendpeers:<value>  Maximum number of pending connection attempts (default: 0)
  --nat:<value>           NAT port mapping mechanism (any|none|upnp|pmp|<external IP>) (default: "any")
  --nodiscover            Disables the peer discovery mechanism (manual peer addition)
  --v5discover            Enables the experimental RLPx V5 (topic discovery) mechanism
  --nodekey:<value>       P2P node private key (as hexadecimal string)
  --ident:<value>         Client identifier (default is '$1')
  --protocols:<value>     Enable specific set of protocols (default: $4)

ETHEREUM NETWORK OPTIONS:
  --mainnet               Use Ethereum main network (default)
  --testnet               Use Ropsten test network
  --ropsten               Use Ropsten test network (proof-of-work, the one most like Ethereum mainnet)
  --goerli                Use Görli test network (proof-of-authority, works across all clients)
  --rinkeby               Use Rinkeby test network (proof-of-authority, for those running Geth clients)
  --kovan                 Use Kovan test network (proof-of-authority, for those running OpenEthereum clients)
  --networkid:<value>     Network id (0=custom, 1=mainnet, 3=ropsten, 4=rinkeby, 5=goerli, 42=kovan, other...)
  --customnetwork:<path>  Use custom genesis block for private Ethereum Network (as /path/to/genesis.json)

LOCAL SERVICE OPTIONS:
  --metrics               Enable the metrics HTTP server
  --metricsport:<value>   Set port (always on localhost) metrics HTTP server will bind to (default: 9093)
  --rpc                   Enable the HTTP-RPC server
  --rpcbind:<value>       Set address:port pair(s) (comma-separated) HTTP-RPC server will bind to (default: localhost:8545)
  --rpcapi:<value>        Enable specific set of RPC API from list (comma-separated) (available: eth, debug)
  --graphql               Enable the HTTP-GraphQL server
  --graphqlbind:<value>   Set address:port pair GraphQL server will bind (default: localhost:8547)

LOGGING AND DEBUGGING OPTIONS:
  --log-level:<value>     One of: $2 (default: $3)
  --log-file:<value>      Optional log file, replacing stdout
  --logmetrics            Enable metrics logging
  --logmetricsinterval:<value> Interval at which to log metrics, in seconds (default: 10)
  --debug                 Enable debug mode
  --test:<value>          Perform specified test
""" % [
    NimbusIdent,
    join(logLevels, ", "),
    $defaultLogLevel,
    strip($defaultProtocols, chars = {'{','}'}),
  ]

when declared(os.paramCount): # not available with `--app:lib`
  proc processArguments*(msg: var string, opt: var OptParser): ConfigStatus =
    ## Process command line argument and update `NimbusConfiguration`.
    let config = getConfiguration()

    # At this point `config.net.discPort` is likely populated with network default
    # discPort. We want to override those if it is specified on the command line.
    config.net.discPort = 0

    var length = 0
    for kind, key, value in opt.getopt():
      result = Error
      case kind
      of cmdArgument:
        discard
      of cmdLongOption, cmdShortOption:
        inc(length)
        case key.toLowerAscii()
          of "help", "h":
            msg = getHelpString()
            result = Success
            break
          of "version", "ver", "v":
            msg = NimbusVersion
            result = Success
            break
          else:
            processArgument processEthArguments, key, value, msg
            processArgument processRpcArguments, key, value, msg
            processArgument processNetArguments, key, value, msg
            processArgument processDebugArguments, key, value, msg
            processArgument processGraphqlArguments, key, value, msg
            if result != Success:
              msg = "Unknown option: '" & key & "'."
              break
      of cmdEnd:
        doAssert(false) # we're never getting this kind here

    if config.net.discPort == 0:
      config.net.discPort = config.net.bindPort

  proc processArguments*(msg: var string): ConfigStatus =
    var opt = initOptParser()
    processArguments(msg, opt)

proc processConfiguration*(pathname: string): ConfigStatus =
  ## Process configuration file `pathname` and update `NimbusConfiguration`.
  result = Success
