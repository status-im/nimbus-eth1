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
  eth/p2p/rlpx_protocols/whisper_protocol,
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

let
  NimbusCopyright* = "Copyright (C) 2018-" & $(now().utc.year) & " Status Research & Development GmbH"
  ## copyright string

  NimbusHeader* = NimbusName & " Version " & NimbusVersion &
                  " [" & hostOS & ": " & hostCPU & ", " & nimbus_db_backend & "]\r\n" &
                  NimbusCopyright
  ## is the header which printed, when nimbus binary got executed

const
  MainnetBootnodes = [
    # Ethereum Foundation Go Bootnodes
    "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303",   # bootnode-aws-ap-southeast-1-001
    "enode://22a8232c3abc76a16ae9d6c3b164f98775fe226f0917b0ca871128a74a8e9630b458460865bab457221f1d448dd9791d24c4e5d88786180ac185df813a68d4de@3.209.45.79:30303",     # bootnode-aws-us-east-1-001
    "enode://ca6de62fce278f96aea6ec5a2daadb877e51651247cb96ee310a318def462913b653963c155a0ef6c7d50048bba6e6cea881130857413d9f50a621546b590758@34.255.23.113:30303",   # bootnode-aws-eu-west-1-001
    "enode://279944d8dcd428dffaa7436f25ca0ca43ae19e7bcf94a8fb7d1641651f92d121e972ac2e8f381414b80cc8e5555811c2ec6e1a99bb009b3f53c4c69923e11bd8@35.158.244.151:30303",  # bootnode-aws-eu-central-1-001
    "enode://8499da03c47d637b20eee24eec3c356c9a2e6148d6fe25ca195c7949ab8ec2c03e3556126b0d7ed644675e78c4318b08691b7b57de10e5f0d40d05b09238fa0a@52.187.207.27:30303",   # bootnode-azure-australiaeast-001
    "enode://103858bdb88756c71f15e9b5e09b56dc1be52f0a5021d46301dbbfb7e130029cc9d0d6f73f693bc29b665770fff7da4d34f3c6379fe12721b5d7a0bcb5ca1fc1@191.234.162.198:30303", # bootnode-azure-brazilsouth-001
    "enode://715171f50508aba88aecd1250af392a45a330af91d7b90701c436b618c86aaa1589c9184561907bebbb56439b8f8787bc01f49a7c77276c58c1b09822d75e8e8@52.231.165.108:30303",  # bootnode-azure-koreasouth-001
    "enode://5d6d7cd20d6da4bb83a1d28cadb5d409b64edf314c0335df658c1a54e32c7c4a7ab7823d57c39b6a757556e68ff1df17c748b698544a55cb488b52479a92b60f@104.42.217.25:30303",   # bootnode-azure-westus-001
    # Ethereum Foundation C++ Bootnodes
    "enode://979b7fa28feeb35a4741660a16076f1943202cb72b6af70d327f053e248bab9ba81760f39d0701ef1d8f89cc1fbd2cacba0710a12cd5314d5e0c9021aa3637f9@5.1.83.226:30303"      # DE
  ]

  RopstenBootnodes = [
    "enode://30b7ab30a01c124a6cceca36863ece12c4f5fa68e3ba9b0b51407ccc002eeed3b3102d20a88f1c1d3c3154e2449317b8ef95090e77b312d5cc39354f86d5d606@52.176.7.10:30303",    # US-Azure geth
    "enode://865a63255b3bb68023b6bffd5095118fcc13e79dcf014fe4e47e065c350c7cc72af2e53eff895f11ba1bbb6a2b33271c1116ee870f266618eadfc2e78aa7349c@52.176.100.77:30303",  # US-Azure parity
    "enode://6332792c4a00e3e4ee0926ed89e0d27ef985424d97b6a45bf0f23e51f0dcb5e66b875777506458aea7af6f9e4ffb69f43f3778ee73c81ed9d34c51c4b16b0b0f@52.232.243.152:30303", # Parity
    "enode://94c15d1b9e2fe7ce56e458b9a3b672ef11894ddedd0c6f247e0f1d3487f52b66208fb4aeb8179fce6e3a749ea93ed147c37976d67af557508d199d9594c35f09@192.81.208.223:30303"  # @gpip
  ]

  RinkebyBootnodes = [
    "enode://a24ac7c5484ef4ed0c5eb2d36620ba4e4aa13b8c84684e1b4aab0cebea2ae45cb4d375b77eab56516d34bfbd3c1a833fc51296ff084b770b94fb9028c4d25ccf@52.169.42.101:30303", # IE
    "enode://343149e4feefa15d882d9fe4ac7d88f885bd05ebb735e547f12e12080a9fa07c8014ca6fd7f373123488102fe5e34111f8509cf0b7de3f5b44339c9f25e87cb8@52.3.158.184:30303",  # INFURA
    "enode://b6b28890b006743680c52e64e0d16db57f28124885595fa03a562be1d2bf0f3a1da297d56b13da25fb992888fd556d4c1a27b1f39d531bde7de1921c90061cc6@159.89.28.211:30303", # AKASHA
  ]

  DiscoveryV5Bootnodes = [
    "enode://06051a5573c81934c9554ef2898eb13b33a34b94cf36b202b69fde139ca17a85051979867720d4bdae4323d4943ddf9aeeb6643633aa656e0be843659795007a@35.177.226.168:30303",
    "enode://0cc5f5ffb5d9098c8b8c62325f3797f56509bff942704687b6530992ac706e2cb946b90a34f1f19548cd3c7baccbcaea354531e5983c7d1bc0dee16ce4b6440b@40.118.3.223:30304",
    "enode://1c7a64d76c0334b0418c004af2f67c50e36a3be60b5e4790bdac0439d21603469a85fad36f2473c9a80eb043ae60936df905fa28f1ff614c3e5dc34f15dcd2dc@40.118.3.223:30306",
    "enode://85c85d7143ae8bb96924f2b54f1b3e70d8c4d367af305325d30a61385a432f247d2c75c45c6b4a60335060d072d7f5b35dd1d4c45f76941f62a4f83b6e75daaf@40.118.3.223:30307"
  ]

  KovanBootnodes = [
    "enode://56abaf065581a5985b8c5f4f88bd202526482761ba10be9bfdcd14846dd01f652ec33fde0f8c0fd1db19b59a4c04465681fcef50e11380ca88d25996191c52de@40.71.221.215:30303",
    "enode://d07827483dc47b368eaf88454fb04b41b7452cf454e194e2bd4c14f98a3278fed5d819dbecd0d010407fc7688d941ee1e58d4f9c6354d3da3be92f55c17d7ce3@52.166.117.77:30303",
    "enode://8fa162563a8e5a05eef3e1cd5abc5828c71344f7277bb788a395cce4a0e30baf2b34b92fe0b2dbbba2313ee40236bae2aab3c9811941b9f5a7e8e90aaa27ecba@52.165.239.18:30303",
    "enode://7e2e7f00784f516939f94e22bdc6cf96153603ca2b5df1c7cc0f90a38e7a2f218ffb1c05b156835e8b49086d11fdd1b3e2965be16baa55204167aa9bf536a4d9@52.243.47.56:30303",
    "enode://0518a3d35d4a7b3e8c433e7ffd2355d84a1304ceb5ef349787b556197f0c87fad09daed760635b97d52179d645d3e6d16a37d2cc0a9945c2ddf585684beb39ac@40.68.248.100:30303"
  ]

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
  except:
    result = ErrorParseOption

proc processFloat*(v: string, o: var float): ConfigStatus =
  ## Convert string to float.
  try:
    o  = parseFloat(v)
    result = Success
  except:
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
    except:
      discard
    try:
      tas6 = resolveTAddress(item, IpAddressFamily.IPv6)
    except:
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
  except:
    result = ErrorParseOption

# proc processHexBytes(v: string, o: var seq[byte]): ConfigStatus =
#   ## Convert hexadecimal string to seq[byte].
#   try:
#     o = fromHex(v)
#     result = Success
#   except:
#     result = ErrorParseOption

# proc processHexString(v: string, o: var string): ConfigStatus =
#   ## Convert hexadecimal string to string.
#   try:
#     o = parseHexStr(v)
#     result = Success
#   except:
#     result = ErrorParseOption

# proc processJson(v: string, o: var JsonNode): ConfigStatus =
#   ## Convert string to JSON.
#   try:
#     o = parseJson(v)
#     result = Success
#   except:
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

