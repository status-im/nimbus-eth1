# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  parseopt, strutils, macros, os, times,
  chronos, eth/[keys, common, p2p, net/nat], chronicles, nimcrypto/hash,
  eth/p2p/bootnodes, eth/p2p/rlpx_protocols/whisper_protocol,
  ./db/select_backend,
  ./vm/interpreter/vm_forks

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

  gitRevision = staticExec("git rev-parse --short HEAD")

let
  NimbusCopyright* = "Copyright (c) 2018-" & $(now().utc.year) & " Status Research & Development GmbH"
  NimbusHeader* = "$# Version $# [$#: $#, $#, $#]\p$#" %
    [NimbusName, NimbusVersion, hostOS, hostCPU, nimbus_db_backend, gitRevision, NimbusCopyright]

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
    Shh                           ## enable shh_ set of RPC API
    Debug                         ## enable debug_ set of RPC API

  ProtocolFlags* {.pure.} = enum
    ## Protocol flags
    Eth                           ## enable eth subprotocol
    Shh                           ## enable whisper subprotocol
    Les                           ## enable les subprotocol

  RpcConfiguration* = object
    ## JSON-RPC configuration object
    flags*: set[RpcFlags]         ## RPC flags
    binds*: seq[TransportAddress] ## RPC bind address

  PublicNetwork* = enum
    CustomNet = 0
    MainNet = 1
    MordenNet = 2
    RopstenNet = 3
    RinkebyNet = 4
    KovanNet = 42

  NetworkFlags* = enum
    ## Ethereum network flags
    NoDiscover,                   ## Peer discovery disabled
    V5Discover,                   ## Dicovery V5 enabled

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
    bindPort*: uint16             ## Main TCP bind port
    discPort*: uint16             ## Discovery UDP bind port
    metricsServer*: bool           ## Enable metrics server
    metricsServerPort*: uint16    ## metrics HTTP server port
    maxPeers*: int                ## Maximum allowed number of peers
    maxPendingPeers*: int         ## Maximum allowed pending peers
    networkId*: uint              ## Network ID as integer
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

  ChainConfig* = object
    chainId*: uint
    homesteadBlock*: BlockNumber
    daoForkBlock*: BlockNumber
    daoForkSupport*: bool

    # EIP150 implements the Gas price changes (https://github.com/ethereum/EIPs/issues/150)
    eip150Block*: BlockNumber
    eip150Hash*: Hash256

    eip155Block*: BlockNumber
    eip158Block*: BlockNumber

    byzantiumBlock*: BlockNumber
    constantinopleBlock*: BlockNumber

  NimbusConfiguration* = ref object
    ## Main Nimbus configuration object
    dataDir*: string
    keyFile*: string
    prune*: PruneMode
    rpc*: RpcConfiguration        ## JSON-RPC configuration
    net*: NetConfiguration        ## Network configuration
    debug*: DebugConfiguration    ## Debug configuration
    shh*: WhisperConfig           ## Whisper configuration

const
  defaultRpcApi = {RpcFlags.Eth, RpcFlags.Shh}
  defaultProtocols = {ProtocolFlags.Eth, ProtocolFlags.Shh}
  defaultLogLevel = LogLevel.WARN
  defaultNetwork = MainNet

var nimbusConfig {.threadvar.}: NimbusConfiguration

proc getConfiguration*(): NimbusConfiguration {.gcsafe.}

proc publicChainConfig*(id: PublicNetwork): ChainConfig =
  result = case id
  of MainNet:
    ChainConfig(
      chainId:        MainNet.uint,
      homesteadBlock: forkBlocks[FkHomestead],
      daoForkBlock:   forkBlocks[FkDao],
      daoForkSupport: true,
      eip150Block:    forkBlocks[FkTangerine],
      eip150Hash:     toDigest("2086799aeebeae135c246c65021c82b4e15a2c451340993aacfd2751886514f0"),
      eip155Block:    forkBlocks[FkSpurious],
      eip158Block:    forkBlocks[FkSpurious],
      byzantiumBlock: forkBlocks[FkByzantium]
    )
  of RopstenNet:
    ChainConfig(
      chainId:        RopstenNet.uint,
      homesteadBlock: 0.toBlockNumber,
      daoForkSupport: true,
      eip150Block:    0.toBlockNumber,
      eip150Hash:     toDigest("41941023680923e0fe4d74a34bdac8141f2540e3ae90623718e47d66d1ca4a2d"),
      eip155Block:    10.toBlockNumber,
      eip158Block:    10.toBlockNumber,
      byzantiumBlock: 1700000.toBlockNumber
    )
  of RinkebyNet:
    ChainConfig(
      chainId:        RinkebyNet.uint,
      homesteadBlock: 1.toBlockNumber,
      daoForkSupport: true,
      eip150Block:    2.toBlockNumber,
      eip150Hash:     toDigest("9b095b36c15eaf13044373aef8ee0bd3a382a5abb92e402afa44b8249c3a90e9"),
      eip155Block:    3.toBlockNumber,
      eip158Block:    3.toBlockNumber,
      byzantiumBlock: 1035301.toBlockNumber
    )
  else:
    error "No chain config for public network", networkId = id
    doAssert(false, "No chain config for " & $id)
    ChainConfig()

  result.chainId = uint(id)

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

proc processFloat*(v: string, o: var float): ConfigStatus =
  ## Convert string to float.
  try:
    o  = parseFloat(v)
    result = Success
  except ValueError:
    result = ErrorParseOption

proc processAddressPortsList(v: string,
                             o: var seq[TransportAddress]): ConfigStatus =
  ## Convert <hostname:port>;...;<hostname:port> to list of `TransportAddress`.
  var list = newSeq[string]()
  processList(v, list)
  for item in list:
    var tas4: seq[TransportAddress]
    var tas6: seq[TransportAddress]
    try:
      tas4 = resolveTAddress(item, IpAddressFamily.IPv4)
    except CatchableError:
      discard
    try:
      tas6 = resolveTAddress(item, IpAddressFamily.IPv6)
    except CatchableError:
      discard
    if len(tas4) == 0 and len(tas6) == 0:
      result = ErrorParseOption
      break
    else:
      for a in tas4: o.add(a)
      for a in tas6: o.add(a)
  result = Success

proc processRpcApiList(v: string, flags: var set[RpcFlags]): ConfigStatus =
  var list = newSeq[string]()
  processList(v, list)
  result = Success
  for item in list:
    case item.toLowerAscii()
    of "eth": flags.incl RpcFlags.Eth
    of "shh": flags.incl RpcFlags.Shh
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
    of "shh": flags.incl ProtocolFlags.Shh
    of "les": flags.incl ProtocolFlags.Les
    else:
      warn "unknown protocol", name = item
      result = ErrorIncorrectOption

proc processENode(v: string, o: var ENode): ConfigStatus =
  ## Convert string to ENode.
  let res = initENode(v, o)
  if res == ENodeStatus.Success:
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
  try:
    o = initPrivateKey(v)
    result = Success
  except CatchableError:
    result = ErrorParseOption

# proc processHexBytes(v: string, o: var seq[byte]): ConfigStatus =
#   ## Convert hexadecimal string to seq[byte].
#   try:
#     o = fromHex(v)
#     result = Success
#   except CatchableError:
#     result = ErrorParseOption

# proc processHexString(v: string, o: var string): ConfigStatus =
#   ## Convert hexadecimal string to string.
#   try:
#     o = parseHexStr(v)
#     result = Success
#   except CatchableError:
#     result = ErrorParseOption

# proc processJson(v: string, o: var JsonNode): ConfigStatus =
#   ## Convert string to JSON.
#   try:
#     o = parseJson(v)
#     result = Success
#   except CatchableError:
#     result = ErrorParseOption

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
  of "keyfile":
    if fileExists(value):
      config.keyFile = value
    else:
      result = ErrorIncorrectOption
  of "datadir":
    config.dataDir = value
  of "prune":
    result = processPruneList(value, config.prune)
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

proc setBootnodes(onodes: var seq[ENode], nodeUris: openarray[string]) =
  var node: ENode
  onodes = newSeqOfCap[ENode](nodeUris.len)
  for item in nodeUris:
    doAssert(processENode(item, node) == Success)
    onodes.add(node)

macro availableEnumValues(T: type enum): untyped =
  let impl = getTypeImpl(T)[1].getTypeImpl()
  result = newNimNode(nnkBracket)
  for i in 1 ..< impl.len: result.add(newCall("uint", copyNimTree(impl[i])))

proc toPublicNetwork*(id: uint): PublicNetwork {.inline.} =
  if id in availableEnumValues(PublicNetwork):
    result = PublicNetwork(id)

proc setNetwork(conf: var NetConfiguration, id: PublicNetwork) =
  ## Set network id and default network bootnodes
  conf.networkId = uint(id)
  case id
  of MainNet:
    conf.bootNodes.setBootnodes(MainnetBootnodes)
  of MordenNet:
    discard
  of RopstenNet:
    conf.bootNodes.setBootnodes(RopstenBootnodes)
  of RinkebyNet:
    conf.bootNodes.setBootnodes(RinkebyBootnodes)
  of KovanNet:
    conf.bootNodes.setBootnodes(KovanBootnodes)
  of CustomNet:
    discard

proc setNetwork(conf: var NetConfiguration, id: uint) =
  ## Set network id and default network bootnodes
  let pubNet = toPublicNetwork(id)
  if pubNet == CustomNet:
    conf.networkId = id
  else:
    conf.setNetwork(pubNet)

proc processNetArguments(key, value: string): ConfigStatus =
  ## Processes only `Networking` related command line options
  result = Success
  let config = getConfiguration()
  let skey = key.toLowerAscii()
  if skey == "bootnodes":
    result = processENodesList(value, config.net.bootNodes)
  elif skey == "bootnodesv4":
    result = processENodesList(value, config.net.bootNodes)
  elif skey == "bootnodesv5":
    result = processENodesList(value, config.net.bootNodes)
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
  elif skey == "kovan":
    config.net.setNetwork(KovanNet)
  elif skey == "networkid":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.net.setNetwork(uint(result))
  elif skey == "nodiscover":
    config.net.flags.incl(NoDiscover)
  elif skey == "v5discover":
    config.net.flags.incl(V5Discover)
    config.net.bootNodes.setBootnodes(DiscoveryV5Bootnodes)
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
  elif skey == "metricsserver" and defined(insecure):
    config.net.metricsServer = true
  elif skey == "metricsserverport" and defined(insecure):
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

proc processShhArguments(key, value: string): ConfigStatus =
  ## Processes only `Shh` related command line options
  result = Success
  let config = getConfiguration()
  let skey = key.toLowerAscii()
  if skey == "shh-maxsize":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.shh.maxMsgSize = res.uint32
  elif skey == "shh-pow":
    var res = 0.0
    result = processFloat(value, res)
    if result == Success:
      config.shh.powRequirement = res
  elif skey == "shh-light":
    config.shh.isLightNode = true
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
    "AppData" / "Roaming" / "Nimbus" / "DB"
  elif defined(macosx):
    "Library" / "Application Support" / "Nimbus" / "DB"
  else:
    ".cache" / "nimbus" / "db"

proc initConfiguration(): NimbusConfiguration =
  ## Allocates and initializes `NimbusConfiguration` with default values
  result = new NimbusConfiguration
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

  const dataDir = getDefaultDataDir()

  result.dataDir = getHomeDir() / dataDir
  result.prune = PruneMode.Full

  ## Whisper defaults
  result.shh.maxMsgSize = defaultMaxMsgSize
  result.shh.powRequirement = defaultMinPow
  result.shh.isLightNode = false
  result.shh.bloom = fullBloom()

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

  when defined(insecure):
    let metricsServerHelp = """

  --metricsServer         Enable the metrics HTTP server
  --metricsServerPort:<value> Metrics HTTP server port on localhost (default: 9093)"""
  else:
    let metricsServerHelp = ""

  result = """

USAGE:
  nimbus [options]

ETHEREUM OPTIONS:
  --keyfile:<value>       Use keyfile storage file
  --datadir:<value>       Base directory for all blockchain-related data
  --prune:<value>         Blockchain prune mode(full or archive)

NETWORKING OPTIONS:
  --bootnodes:<value>     Comma separated enode URLs for P2P discovery bootstrap (set v4+v5 instead for light servers)
  --bootnodesv4:<value>   Comma separated enode URLs for P2P v4 discovery bootstrap (light server, full nodes)
  --bootnodesv5:<value>   Comma separated enode URLs for P2P v5 discovery bootstrap (light server, light nodes)
  --staticnodes:<value>   Comma separated enode URLs to connect with
  --port:<value>          Network listening TCP port (default: 30303)
  --discport:<value>      Network listening UDP port (defaults to --port argument)$7
  --maxpeers:<value>      Maximum number of network peers (default: 25)
  --maxpendpeers:<value>  Maximum number of pending connection attempts (default: 0)
  --nat:<value>           NAT port mapping mechanism (any|none|upnp|pmp|<external IP>) (default: "any")
  --nodiscover            Disables the peer discovery mechanism (manual peer addition)
  --v5discover            Enables the experimental RLPx V5 (Topic Discovery) mechanism
  --nodekey:<value>       P2P node private key (as hexadecimal string)
  --networkid:<value>     Network identifier (integer, 1=Frontier, 2=Morden (disused), 3=Ropsten, 4=Rinkeby) (default: $8)
  --testnet               Use Ethereum Default Test Network (Ropsten)
  --ropsten               Use Ethereum Ropsten Test Network
  --rinkeby               Use Ethereum Rinkeby Test Network
  --ident:<value>         Client identifier (default is '$1')
  --protocols:<value>     Enable specific set of protocols (default: $4)

WHISPER OPTIONS:
  --shh-maxsize:<value>   Max message size accepted (default: $5)
  --shh-pow:<value>       Minimum POW accepted (default: $6)
  --shh-light             Run as Whisper light client (no outgoing messages)

API AND CONSOLE OPTIONS:
  --rpc                   Enable the HTTP-RPC server
  --rpcbind:<value>       HTTP-RPC server will bind to given comma separated address:port pairs (default: 127.0.0.1:8545)
  --rpcapi:<value>        Enable specific set of rpc api from comma separated list(eth, shh, debug)

LOGGING AND DEBUGGING OPTIONS:
  --log-level:<value>     One of: $2 (default: $3)
  --log-file:<value>      Optional log file, replacing stdout
  --logMetrics            Enable metrics logging
  --logMetricsInterval:<value> Interval at which to log metrics, in seconds (default: 10)
  --debug                 Enable debug mode
  --test:<value>          Perform specified test
""" % [
    NimbusIdent,
    join(logLevels, ", "),
    $defaultLogLevel,
    strip($defaultProtocols, chars = {'{','}'}),
    $defaultMaxMsgSize,
    $defaultMinPow,
    metricsServerHelp,
    $ord(defaultNetwork)
  ]

when declared(os.paramCount): # not available with `--app:lib`
  proc processArguments*(msg: var string): ConfigStatus =
    ## Process command line argument and update `NimbusConfiguration`.
    let config = getConfiguration()

    # At this point `config.net.bootnodes` is likely populated with network default
    # bootnodes. We want to override those if at least one custom bootnode is
    # specified on the command line. We temporarily set `config.net.bootNodes`
    # to empty seq, and in the end restore it if no bootnodes were spricified on
    # the command line.
    # TODO: This is pretty hacky and it's better to refactor it to make a clear
    # distinction between default and custom bootnodes.
    var tempBootNodes: seq[ENode]
    swap(tempBootNodes, config.net.bootNodes)

    # The same trick is done to discPort
    config.net.discPort = 0

    var opt = initOptParser()
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
            processArgument processShhArguments, key, value, msg
            processArgument processDebugArguments, key, value, msg
            if result != Success:
              msg = "Unknown option: '" & key & "'."
              break
      of cmdEnd:
        doAssert(false) # we're never getting this kind here

    if config.net.bootNodes.len == 0:
      # No custom bootnodes were specified on the command line, restore to
      # previous values
      swap(tempBootNodes, config.net.bootNodes)

    if config.net.discPort == 0:
      config.net.discPort = config.net.bindPort

proc processConfiguration*(pathname: string): ConfigStatus =
  ## Process configuration file `pathname` and update `NimbusConfiguration`.
  result = Success

