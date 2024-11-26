# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[
    options,
    strutils,
    os,
    uri,
    net
  ],
  pkg/[
    chronos/transports/common,
    chronicles,
    confutils,
    confutils/defs,
    confutils/std/net
  ],
  eth/[common, net/utils, net/nat, p2p/bootnodes, p2p/enode, p2p/discoveryv5/enr],
  "."/[constants, compile_info, version],
  common/chain_config,
  db/opts

export net, defs


const
  # e.g.: Copyright (c) 2018-2021 Status Research & Development GmbH
  NimbusCopyright* = "Copyright (c) 2018-" &
    CompileDate.split('-')[0] &
    " Status Research & Development GmbH"

  # e.g.:
  # nimbus/v0.1.0-abcdef/os-cpu/nim-a.b.c/emvc
  # Copyright (c) 2018-2021 Status Research & Development GmbH
  NimbusBuild* = "$#\p$#" % [
    ClientId,
    NimbusCopyright,
  ]

  NimbusHeader* = "$#\p\pNim version $#" % [
    NimbusBuild,
    NimVersion
  ]

func defaultDataDir*(): string =
  when defined(windows):
    getHomeDir() / "AppData" / "Roaming" / "Nimbus"
  elif defined(macosx):
    getHomeDir() / "Library" / "Application Support" / "Nimbus"
  else:
    getHomeDir() / ".cache" / "nimbus"

func defaultKeystoreDir*(): string =
  defaultDataDir() / "keystore"

func getLogLevels(): string =
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
  defaultHttpPort          = 8545
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/authentication.md#jwt-specifications
  defaultEngineApiPort     = 8551
  defaultAdminListenAddress = (static parseIpAddress("127.0.0.1"))
  defaultAdminListenAddressDesc = $defaultAdminListenAddress & ", meaning local host only"
  logLevelDesc = getLogLevels()

let
  defaultListenAddress      = getAutoAddress(Port(0)).toIpAddress()
  defaultListenAddressDesc  = $defaultListenAddress & ", meaning all network interfaces"

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
  ChainDbMode* {.pure.} = enum
    Aristo
    AriPrune

  NimbusCmd* {.pure.} = enum
    noCommand
    `import`

  RpcFlag* {.pure.} = enum
    ## RPC flags
    Eth                           ## enable eth_ set of RPC API
    Debug                         ## enable debug_ set of RPC API

  DiscoveryType* {.pure.} = enum
    None
    V4
    V5

  NimbusConf* = object of RootObj
    ## Main Nimbus configuration object

    dataDir* {.
      separator: "ETHEREUM OPTIONS:"
      desc: "The directory where nimbus will store all blockchain data"
      defaultValue: defaultDataDir()
      defaultValueDesc: $defaultDataDirDesc
      abbr: "d"
      name: "data-dir" }: OutDir

    era1DirOpt* {.
      desc: "Directory where era1 (pre-merge) archive can be found"
      defaultValueDesc: "<data-dir>/era1"
      name: "era1-dir" }: Option[OutDir]

    eraDirOpt* {.
      desc: "Directory where era (post-merge) archive can be found"
      defaultValueDesc: "<data-dir>/era"
      name: "era-dir" }: Option[OutDir]

    keyStore* {.
      desc: "Load one or more keystore files from this directory"
      defaultValue: defaultKeystoreDir()
      defaultValueDesc: "inside datadir"
      abbr: "k"
      name: "key-store" }: OutDir

    chainDbMode* {.
      desc: "Blockchain database"
      longDesc:
        "- Aristo   -- Single state DB, full node\n" &
        "- AriPrune -- Aristo with curbed block history (for testing)\n" &
        ""
      defaultValue: ChainDbMode.Aristo
      defaultValueDesc: $ChainDbMode.Aristo
      abbr : "p"
      name: "chaindb" }: ChainDbMode

    importKey* {.
      desc: "Import unencrypted 32 bytes hex private key from a file"
      defaultValue: ""
      abbr: "e"
      name: "import-key" }: InputFile

    verifyFrom* {.
      desc: "Enable extra verification when current block number greater than verify-from"
      defaultValueDesc: ""
      name: "verify-from" }: Option[uint64]

    evm* {.
      desc: "Load alternative EVM from EVMC-compatible shared library" & sharedLibText
      defaultValue: ""
      name: "evm"
      includeIfEvmc }: string

    trustedSetupFile* {.
      desc: "Load EIP-4844 trusted setup file"
      defaultValue: none(string)
      defaultValueDesc: "Baked in trusted setup"
      name: "trusted-setup-file" .}: Option[string]

    extraData* {.
      desc: "Value of extraData field when assemble a block(max 32 bytes)"
      defaultValue: ShortClientId
      defaultValueDesc: $ShortClientId
      name: "extra-data" .}: string

    network {.
      separator: "\pETHEREUM NETWORK OPTIONS:"
      desc: "Name or id number of Ethereum network(mainnet(1), sepolia(11155111), holesky(17000), other=custom)"
      longDesc:
        "- mainnet: Ethereum main network\n" &
        "- sepolia: Test network (proof-of-work)\n" &
        "- holesky: The holesovice post-merge testnet"
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
      name: "metrics-address" }: IpAddress

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

    bootstrapEnrs {.
      desc: "ENR URI of node to bootstrap discovery from. Argument may be repeated"
      defaultValue: @[]
      defaultValueDesc: ""
      name: "bootstrap-enr" }: seq[enr.Record]

    staticPeers {.
      desc: "Connect to one or more trusted peers(as enode URL)"
      defaultValue: @[]
      defaultValueDesc: ""
      name: "static-peers" }: seq[string]

    staticPeersFile {.
      desc: "Specifies a line-delimited file of trusted peers addresses(enode URL)" &
            "to be added to the --static-peers list. If the first line equals to the word `override`, "&
            "the file contents will replace the --static-peers list"
      defaultValue: ""
      name: "static-peers-file" }: InputFile

    staticPeersEnrs {.
      desc: "ENR URI of node to connect to as trusted peer. Argument may be repeated"
      defaultValue: @[]
      defaultValueDesc: ""
      name: "static-peer-enr" }: seq[enr.Record]

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
      name: "listen-address" }: IpAddress

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
      defaultValue: ClientId
      defaultValueDesc: $ClientId
      name: "agent-string" .}: string

    beaconChunkSize* {.
      hidden
      desc: "Number of blocks per database transaction for beacon sync"
      defaultValue: 0
      name: "debug-beacon-chunk-size" .}: int

    rocksdbMaxOpenFiles {.
      hidden
      defaultValue: defaultMaxOpenFiles
      defaultValueDesc: $defaultMaxOpenFiles
      name: "debug-rocksdb-max-open-files".}: int

    rocksdbWriteBufferSize {.
      hidden
      defaultValue: defaultWriteBufferSize
      defaultValueDesc: $defaultWriteBufferSize
      name: "debug-rocksdb-write-buffer-size".}: int

    rocksdbRowCacheSize {.
      hidden
      defaultValue: defaultRowCacheSize
      defaultValueDesc: $defaultRowCacheSize
      name: "debug-rocksdb-row-cache-size".}: int

    rocksdbBlockCacheSize {.
      hidden
      defaultValue: defaultBlockCacheSize
      defaultValueDesc: $defaultBlockCacheSize
      name: "debug-rocksdb-block-cache-size".}: int

    rdbKeyCacheSize {.
      hidden
      defaultValue: defaultRdbKeyCacheSize
      defaultValueDesc: $defaultRdbKeyCacheSize
      name: "debug-rdb-key-cache-size".}: int

    rdbVtxCacheSize {.
      hidden
      defaultValue: defaultRdbVtxCacheSize
      defaultValueDesc: $defaultRdbVtxCacheSize
      name: "debug-rdb-vtx-cache-size".}: int

    rdbPrintStats {.
      hidden
      desc: "Print RDB statistics at exit"
      name: "debug-rdb-print-stats".}: bool

    case cmd* {.
      command
      defaultValue: NimbusCmd.noCommand }: NimbusCmd

    of noCommand:
      httpPort* {.
        separator: "\pLOCAL SERVICES OPTIONS:"
        desc: "Listening port of the HTTP server(rpc, ws, graphql)"
        defaultValue: defaultHttpPort
        defaultValueDesc: $defaultHttpPort
        name: "http-port" }: Port

      httpAddress* {.
        desc: "Listening IP address of the HTTP server(rpc, ws, graphql)"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "http-address" }: IpAddress

      rpcEnabled* {.
        desc: "Enable the JSON-RPC server"
        defaultValue: false
        name: "rpc" }: bool

      rpcApi {.
        desc: "Enable specific set of RPC API (available: eth, debug)"
        defaultValue: @[]
        defaultValueDesc: $RpcFlag.Eth
        name: "rpc-api" }: seq[string]

      wsEnabled* {.
        desc: "Enable the Websocket JSON-RPC server"
        defaultValue: false
        name: "ws" }: bool

      wsApi {.
        desc: "Enable specific set of Websocket RPC API (available: eth, debug)"
        defaultValue: @[]
        defaultValueDesc: $RpcFlag.Eth
        name: "ws-api" }: seq[string]

      graphqlEnabled* {.
        desc: "Enable the GraphQL HTTP server"
        defaultValue: false
        name: "graphql" }: bool

      engineApiEnabled* {.
        desc: "Enable the Engine API"
        defaultValue: false
        name: "engine-api" .}: bool

      engineApiPort* {.
        desc: "Listening port for the Engine API(http and ws)"
        defaultValue: defaultEngineApiPort
        defaultValueDesc: $defaultEngineApiPort
        name: "engine-api-port" .}: Port

      engineApiAddress* {.
        desc: "Listening address for the Engine API(http and ws)"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "engine-api-address" .}: IpAddress

      engineApiWsEnabled* {.
        desc: "Enable the WebSocket Engine API"
        defaultValue: false
        name: "engine-api-ws" .}: bool

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

    of `import`:
      blocksFile* {.
        argument
        desc: "One or more RLP encoded block(s) files"
        name: "blocks-file" }: seq[InputFile]

      maxBlocks* {.
        desc: "Maximum number of blocks to import"
        defaultValue: uint64.high()
        name: "max-blocks" .}: uint64

      chunkSize* {.
        desc: "Number of blocks per database transaction"
        defaultValue: 8192
        name: "chunk-size" .}: uint64

      csvStats* {.
        hidden
        desc: "Save performance statistics to CSV"
        name: "debug-csv-stats".}: Option[string]

      # TODO validation and storage options should be made non-hidden when the
      #      UX has stabilised and era1 storage is in the app
      fullValidation* {.
        hidden
        desc: "Enable full per-block validation (slow)"
        defaultValue: false
        name: "debug-full-validation".}: bool

      noValidation* {.
        hidden
        desc: "Disble per-chunk validation"
        defaultValue: true
        name: "debug-no-validation".}: bool

      storeBodies* {.
        hidden
        desc: "Store block blodies in database"
        defaultValue: false
        name: "debug-store-bodies".}: bool

      # TODO this option should probably only cover the redundant parts, ie
      #      those that are in era1 files - era files presently do not store
      #      receipts
      storeReceipts* {.
        hidden
        desc: "Store receipts in database"
        defaultValue: false
        name: "debug-store-receipts".}: bool

      storeSlotHashes* {.
        hidden
        desc: "Store reverse slot hashes in database"
        defaultValue: false
        name: "debug-store-slot-hashes".}: bool

func parseCmdArg(T: type NetworkId, p: string): T
    {.gcsafe, raises: [ValueError].} =
  parseBiggestUInt(p).T

func completeCmdArg(T: type NetworkId, val: string): seq[string] =
  return @[]

func parseCmdArg*(T: type enr.Record, p: string): T {.raises: [ValueError].} =
  result = fromURI(enr.Record, p).valueOr:
    raise newException(ValueError, "Invalid ENR")

func completeCmdArg*(T: type enr.Record, val: string): seq[string] =
  return @[]

func processList(v: string, o: var seq[string])
    =
  ## Process comma-separated list of strings.
  if len(v) > 0:
    for n in v.split({' ', ','}):
      if len(n) > 0:
        o.add(n)

proc parseCmdArg(T: type NetworkParams, p: string): T
    {.gcsafe, raises: [ValueError].} =
  try:
    if not loadNetworkParams(p, result):
      raise newException(ValueError, "failed to load customNetwork")
  except CatchableError:
    raise newException(ValueError, "failed to load customNetwork")

func completeCmdArg(T: type NetworkParams, val: string): seq[string] =
  return @[]

func setBootnodes(output: var seq[ENode], nodeUris: openArray[string]) =
  output = newSeqOfCap[ENode](nodeUris.len)
  for item in nodeUris:
    output.add(ENode.fromString(item).expect("valid hardcoded ENode"))

iterator repeatingList(listOfList: openArray[string]): string
    =
  for strList in listOfList:
    var list = newSeq[string]()
    processList(strList, list)
    for item in list:
      yield item

proc append(output: var seq[ENode], nodeUris: openArray[string])
    =
  for item in repeatingList(nodeUris):
    let res = ENode.fromString(item)
    if res.isErr:
      warn "Ignoring invalid bootstrap address", address=item
      continue
    output.add res.get()

iterator strippedLines(filename: string): (int, string)
    {.gcsafe, raises: [IOError].} =
  var i = 0
  for line in lines(filename):
    let stripped = strip(line)
    if stripped.startsWith('#'): # Comments
      continue

    if stripped.len > 0:
      yield (i, stripped)
      inc i

proc loadEnodeFile(fileName: string; output: var seq[ENode]; info: string)
    =
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
  of "sepolia": return some SepoliaNet
  of "holesky": return some HoleskyNet
  else:
    try:
      some parseBiggestUInt(network).NetworkId
    except CatchableError:
      error "Failed to parse network name or id", network
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

func fromEnr*(T: type ENode, r: enr.Record): ENodeResult[ENode] =
  let
    # TODO: there must always be a public key, else no signature verification
    # could have been done and no Record would exist here.
    # TypedRecord should be reworked not to have public key as an option.
    pk = r.get(PublicKey).get()
    tr = TypedRecord.fromRecord(r)#.expect("id in valid record")

  if tr.ip.isNone():
    return err(IncorrectIP)
  if tr.udp.isNone():
    return err(IncorrectDiscPort)
  if tr.tcp.isNone():
    return err(IncorrectPort)

  ok(ENode(
    pubkey: pk,
    address: enode.Address(
      ip: utils.ipv4(tr.ip.get()),
      udpPort: Port(tr.udp.get()),
      tcpPort: Port(tr.tcp.get())
    )
  ))

proc getBootNodes*(conf: NimbusConf): seq[ENode] =
  var bootstrapNodes: seq[ENode]
  # Ignore standard bootnodes if customNetwork is loaded
  if conf.customNetwork.isNone:
    case conf.networkId
    of MainNet:
      bootstrapNodes.setBootnodes(MainnetBootnodes)
    of SepoliaNet:
      bootstrapNodes.setBootnodes(SepoliaBootnodes)
    of HoleskyNet:
      bootstrapNodes.setBootnodes(HoleskyBootnodes)
    else:
      # custom network id
      discard

  # always allow bootstrap nodes provided by the user
  if conf.bootstrapNodes.len > 0:
    bootstrapNodes.append(conf.bootstrapNodes)

  # bootstrap nodes loaded from file might append or
  # override built-in bootnodes
  loadBootstrapFile(string conf.bootstrapFile, bootstrapNodes)

  # Bootstrap nodes provided as ENRs
  for enr in conf.bootstrapEnrs:
    let enode = ENode.fromEnr(enr).valueOr:
      fatal "Invalid bootstrap ENR provided", error
      quit 1

    bootstrapNodes.add(enode)

  bootstrapNodes

proc getStaticPeers*(conf: NimbusConf): seq[ENode] =
  var staticPeers: seq[ENode]
  staticPeers.append(conf.staticPeers)
  loadStaticPeersFile(string conf.staticPeersFile, staticPeers)

  # Static peers provided as ENRs
  for enr in conf.staticPeersEnrs:
    let enode = ENode.fromEnr(enr).valueOr:
      fatal "Invalid static peer ENR provided", error
      quit 1

    staticPeers.add(enode)

  staticPeers

func getAllowedOrigins*(conf: NimbusConf): seq[Uri] =
  for item in repeatingList(conf.allowedOrigins):
    result.add parseUri(item)

func engineApiServerEnabled*(conf: NimbusConf): bool =
  conf.engineApiEnabled or conf.engineApiWsEnabled

func shareServerWithEngineApi*(conf: NimbusConf): bool =
  conf.engineApiServerEnabled and
    conf.engineApiPort == conf.httpPort

func httpServerEnabled*(conf: NimbusConf): bool =
  conf.graphqlEnabled or
    conf.wsEnabled or
    conf.rpcEnabled

func era1Dir*(conf: NimbusConf): OutDir =
  conf.era1DirOpt.get(OutDir(conf.dataDir.string & "/era1"))

func eraDir*(conf: NimbusConf): OutDir =
  conf.eraDirOpt.get(OutDir(conf.dataDir.string & "/era"))

func dbOptions*(conf: NimbusConf, noKeyCache = false): DbOptions =
  DbOptions.init(
    maxOpenFiles = conf.rocksdbMaxOpenFiles,
    writeBufferSize = conf.rocksdbWriteBufferSize,
    rowCacheSize = conf.rocksdbRowCacheSize,
    blockCacheSize = conf.rocksdbBlockCacheSize,
    rdbKeyCacheSize =
      if noKeyCache: 0 else: conf.rdbKeyCacheSize ,
    rdbVtxCacheSize =
      # The import command does not use the key cache - better give it to vtx
      if noKeyCache: conf.rdbKeyCacheSize + conf.rdbVtxCacheSize
      else: conf.rdbVtxCacheSize,
    rdbPrintStats = conf.rdbPrintStats,
  )

# KLUDGE: The `load()` template does currently not work within any exception
#         annotated environment.
{.pop.}

proc makeConfig*(cmdLine = commandLineParams()): NimbusConf
    {.raises: [CatchableError].} =
  ## Note: this function is not gc-safe

  # The try/catch clause can go away when `load()` is clean
  try:
    {.push warning[ProveInit]: off.}
    result = NimbusConf.load(
      cmdLine,
      version = NimbusBuild,
      copyrightBanner = NimbusHeader
    )
    {.pop.}
  except CatchableError as e:
    raise e

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
    if result.udpPort == Port(0):
      # if udpPort not set in cli, then
      result.udpPort = result.tcpPort

  # see issue #1346
  if result.keyStore.string == defaultKeystoreDir() and
     result.dataDir.string != defaultDataDir():
    result.keyStore = OutDir(result.dataDir.string / "keystore")

when isMainModule:
  # for testing purpose
  discard makeConfig()
