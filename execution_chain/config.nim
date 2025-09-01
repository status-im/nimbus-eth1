# Copyright (c) 2018-2025 Status Research & Development GmbH
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
    confutils/std/net as confnet,
    json_serialization/std/net as jsnet,
    results,
    beacon_chain/buildinfo,
    beacon_chain/nimbus_binary_common,
  ],
  toml_serialization,
  eth/[common, net/nat],
  ./networking/[bootnodes, eth1_enr as enr],
  ./[constants, compile_info, version],
  ./common/chain_config,
  ./db/opts

export net, defs, jsnet, nimbus_binary_common
const

  # e.g.:
  # nimbus_execution_client/v0.1.0-abcdef/os-cpu/nim-a.b.c/emvc
  # Copyright (c) 2018-2025 Status Research & Development GmbH
  NimbusBuild* = "$#\p$#" % [
    ClientId,
    copyrights,
  ]

  NimbusHeader* = "$#\p\pNim version $#" % [
    NimbusBuild,
    nimBanner()
  ]

func getLogLevels(): string =
  var logLevels: seq[string]
  for level in LogLevel:
    if level < enabledLogLevel:
      continue
    logLevels.add($level)
  join(logLevels, ", ")

const
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

type
  NimbusCmd* {.pure.} = enum
    noCommand
    `import`
    `import-rlp`

  RpcFlag* {.pure.} = enum
    ## RPC flags
    Eth                           ## enable eth_ set of RPC API
    Debug                         ## enable debug_ set of RPC API
    Admin                         ## enable admin_ set of RPC API

  DiscoveryType* {.pure.} = enum
    V4
    V5

  NimbusConf* = object of RootObj
    ## Main Nimbus configuration object
    configFile {.
      separator: "ETHEREUM OPTIONS:"
      desc: "Loads the configuration from a TOML file"
      name: "config-file" .}: Option[InputFile]

    dataDirFlag* {.
      desc: "The directory where nimbus will store all blockchain data"
      abbr: "d"
      name: "data-dir" }: Option[OutDir]

    era1DirFlag* {.
      desc: "Directory where era1 (pre-merge) archive can be found"
      defaultValueDesc: "<data-dir>/era1"
      name: "era1-dir" }: Option[OutDir]

    eraDirFlag* {.
      desc: "Directory where era (post-merge) archive can be found"
      defaultValueDesc: "<data-dir>/era"
      name: "era-dir" }: Option[OutDir]

    keyStoreDirFlag* {.
      desc: "Load one or more keystore files from this directory"
      defaultValueDesc: "inside datadir"
      abbr: "k"
      name: "key-store" }: Option[OutDir]

    importKey* {.
      desc: "Import unencrypted 32 bytes hex private key from a file"
      defaultValue: ""
      abbr: "e"
      name: "import-key" }: InputFile

    trustedSetupFile* {.
      desc: "Load EIP-4844 trusted setup file"
      defaultValue: none(string)
      defaultValueDesc: "Baked in trusted setup"
      name: "trusted-setup-file" .}: Option[string]

    extraData* {.
      separator: "\pPAYLOAD BUILDING OPTIONS:"
      desc: "Value of extraData field when building an execution payload(max 32 bytes)"
      defaultValue: ShortClientId
      defaultValueDesc: $ShortClientId
      name: "extra-data" .}: string

    gasLimit* {.
      desc: "Desired gas limit when building an execution payload"
      defaultValue: DEFAULT_GAS_LIMIT
      defaultValueDesc: $DEFAULT_GAS_LIMIT
      name: "gas-limit" .}: uint64

    network {.
      separator: "\pETHEREUM NETWORK OPTIONS:"
      desc: "Name or id number of Ethereum network"
      longDesc:
        "- mainnet/1       : Ethereum main network\n" &
        "- sepolia/11155111: Test network (proof-of-work)\n" &
        "- holesky/17000   : The holesovice post-merge testnet\n" &
        "- hoodi/560048    : The second long-standing, merged-from-genesis, public Ethereum testnet\n" &
        "- path            : /path/to/genesis-or-network-configuration.json\n" &
        "Both --network: name/path --network:id can be set at the same time to override network id number"
      defaultValue: @[] # the default value is set in makeConfig
      defaultValueDesc: "mainnet(1)"
      abbr: "i"
      name: "network" }: seq[string]

    # TODO: disable --custom-network if both hive and kurtosis not using this anymore.
    customNetwork {.
      hidden
      desc: "Use custom genesis block for private Ethereum Network (as /path/to/genesis.json)"
      defaultValueDesc: ""
      abbr: "c"
      name: "custom-network" }: Option[NetworkParams]

    networkId* {.
      ignore # this field is not processed by confutils
      defaultValue: MainNet # the defaultValue value is set by `makeConfig`
      defaultValueDesc: "MainNet"
      name: "network-id"}: NetworkId

    networkParams* {.
      ignore # this field is not processed by confutils
      defaultValue: NetworkParams() # the defaultValue value is set by `makeConfig`
      name: "network-params"}: NetworkParams

    logLevel* {.
      separator: "\pLOGGING AND DEBUGGING OPTIONS:"
      desc: "Sets the log level for process and topics (" & logLevelDesc & ")"
      defaultValue: "INFO"
      defaultValueDesc: "Info topic level logging"
      name: "log-level" }: string

    logStdout* {.
      hidden
      desc: "Specifies what kind of logs should be written to stdout (auto, colors, nocolors, json)"
      defaultValueDesc: "auto"
      defaultValue: StdoutLogKind.Auto
      name: "log-format" .}: StdoutLogKind

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
        "- V4  : Node Discovery Protocol v4\n" &
        "- V5  : Node Discovery Protocol v5\n" &
        "- All : V4, V5"
      defaultValue: @["V4", "V5"]
      defaultValueDesc: "V4, V5"
      name: "discovery" .}: seq[string]

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

    numThreads* {.
      separator: "\pPERFORMANCE OPTIONS",
      defaultValue: 0,
      desc: "Number of worker threads (\"0\" = use as many threads as there are CPU cores available)"
      name: "num-threads" .}: int

    persistBatchSize* {.
      hidden
      defaultValue: 4'u64
      name: "debug-persist-batch-size" .}: uint64

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

    rdbVtxCacheSize {.
      hidden
      defaultValue: defaultRdbVtxCacheSize
      defaultValueDesc: $defaultRdbVtxCacheSize
      name: "debug-rdb-vtx-cache-size".}: int

    rdbKeyCacheSize {.
      hidden
      defaultValue: defaultRdbKeyCacheSize
      defaultValueDesc: $defaultRdbKeyCacheSize
      name: "debug-rdb-key-cache-size".}: int

    rdbBranchCacheSize {.
      hidden
      defaultValue: defaultRdbBranchCacheSize
      defaultValueDesc: $defaultRdbBranchCacheSize
      name: "debug-rdb-branch-cache-size".}: int

    rdbPrintStats {.
      hidden
      desc: "Print RDB statistics at exit"
      name: "debug-rdb-print-stats".}: bool

    rewriteDatadirId* {.
      hidden
      desc: "Rewrite selected network config hash to database"
      name: "debug-rewrite-datadir-id".}: bool

    eagerStateRootCheck* {.
      hidden
      desc: "Eagerly check state roots when syncing finalized blocks"
      name: "debug-eager-state-root".}: bool

    statelessProviderEnabled* {.
      separator: "\pSTATELESS PROVIDER OPTIONS:"
      hidden
      desc: "Enable the stateless provider. This turns on the features required" &
        " by stateless clients such as generation and storage of block witnesses" &
        " and serving these witnesses to peers over the p2p network."
      defaultValue: false
      name: "stateless-provider" }: bool

    statelessWitnessValidation* {.
      hidden
      desc: "Enable full validation of execution witnesses."
      defaultValue: false
      name: "stateless-witness-validation" }: bool

    case cmd* {.
      command
      defaultValue: NimbusCmd.noCommand }: NimbusCmd

    of noCommand:
      httpPort* {.
        separator: "\pLOCAL SERVICES OPTIONS:"
        desc: "Listening port of the HTTP server(rpc, ws)"
        defaultValue: defaultHttpPort
        defaultValueDesc: $defaultHttpPort
        name: "http-port" }: Port

      httpAddress* {.
        desc: "Listening IP address of the HTTP server(rpc, ws)"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "http-address" }: IpAddress

      rpcEnabled* {.
        desc: "Enable the JSON-RPC server"
        defaultValue: false
        name: "rpc" }: bool

      rpcApi {.
        desc: "Enable specific set of RPC API (available: eth, debug, admin)"
        defaultValue: @[]
        defaultValueDesc: $RpcFlag.Eth
        name: "rpc-api" }: seq[string]

      wsEnabled* {.
        desc: "Enable the Websocket JSON-RPC server"
        defaultValue: false
        name: "ws" }: bool

      wsApi {.
        desc: "Enable specific set of Websocket RPC API (available: eth, debug, admin)"
        defaultValue: @[]
        defaultValueDesc: $RpcFlag.Eth
        name: "ws-api" }: seq[string]

      historyExpiry* {.
        desc: "Enable the data from Portal Network"
        defaultValue: false
        name: "history-expiry" }: bool

      historyExpiryLimit* {.
        hidden
        desc: "Limit the number of blocks to be kept in history"
        name: "debug-history-expiry-limit" }: Option[BlockNumber]

      portalUrl* {.
        desc: "URL of the Portal Network"
        defaultValue: ""
        name: "portal-url" }: string

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
        desc: "Comma-separated list of domains from which to accept cross origin requests"
        defaultValue: @[]
        defaultValueDesc: "*"
        name: "allowed-origins" .}: seq[string]

      # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/authentication.md#key-distribution
      jwtSecret* {.
        desc: "Path to a file containing a 32 byte hex-encoded shared secret" &
          " needed for websocket authentication. By default, the secret key" &
          " is auto-generated."
        defaultValueDesc: "\"jwt.hex\" in the data directory (see --data-dir)"
        name: "jwt-secret" .}: Option[InputFile]

      beaconSyncInitPeersMin* {.
        hidden
        defaultValue: 0
        desc: "Minimal number of peers needed for activating the first" &
              " syncer session"
        name: "debug-beacon-sync-init-peers-min" .}: int

      beaconSyncTarget* {.
        hidden
        desc: "Manually set the initial sync target specified by its 32 byte" &
              " block hash (e.g. as found on etherscan.io) represented by a" &
              " hex string"
        name: "debug-beacon-sync-target" .}: Option[string]

      beaconSyncTargetIsFinal* {.
        hidden
        defaultValue: false
        desc: "If the sync taget is finalised (e.g. as stated on" &
              " etherscan.io) this can be set here. For a non-finalised" &
              " manual sync target it is advisable to run this EL against a" &
              " CL which will result in a smaller memory footprint"
        name: "debug-beacon-sync-target-is-final".}: bool

    of NimbusCmd.`import`:
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

    of NimbusCmd.`import-rlp`:
      blocksFile* {.
        argument
        desc: "One or more RLP encoded block(s) files"
        name: "blocks-file" }: seq[InputFile]

func parseHexOrDec256(p: string): UInt256 {.raises: [ValueError].} =
  if startsWith(p, "0x"):
    parse(p, UInt256, 16)
  else:
    parse(p, UInt256, 10)

proc dataDir*(config: NimbusConf): string =
  # TODO load network name from directory, when using custom network?
  string config.dataDirFlag.get(OutDir defaultDataDir("", config.networkId.name()))

proc keyStoreDir*(config: NimbusConf): string =
  string config.keyStoreDirFlag.get(OutDir config.dataDir() / "keystore")

func parseCmdArg(T: type NetworkId, p: string): T
    {.gcsafe, raises: [ValueError].} =
  parseHexOrDec256(p)

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

func decOrHex(s: string): bool =
  const allowedDigits = Digits + HexDigits + {'x', 'X'}
  for c in s:
    if c notin allowedDigits:
      return false
  true

proc parseNetworkId(network: string): NetworkId =
  try:
    return parseHexOrDec256(network)
  except CatchableError:
    error "Failed to parse network id", id=network
    quit QuitFailure

proc parseNetworkParams(network: string): (NetworkParams, bool) =
  case toLowerAscii(network)
  of "mainnet": (networkParams(MainNet), false)
  of "sepolia": (networkParams(SepoliaNet), false)
  of "holesky": (networkParams(HoleskyNet), false)
  of "hoodi"  : (networkParams(HoodiNet), false)
  else:
    var params: NetworkParams
    if not loadNetworkParams(network, params):
      # `loadNetworkParams` have it's own error log
      quit QuitFailure
    (params, true)

proc processNetworkParamsAndNetworkId(conf: var NimbusConf) =
  if conf.network.len == 0 and conf.customNetwork.isNone:
    # Default value if none is set
    conf.networkId = MainNet
    conf.networkParams = networkParams(MainNet)
    return

  var
    params: Opt[NetworkParams]
    id: Opt[NetworkId]
    simulatedCustomNetwork = false

  for network in conf.network:
    if decOrHex(network):
      if id.isSome:
        warn "Network ID already set, ignore new value", id=network
        continue
      id = Opt.some parseNetworkId(network)
    else:
      if params.isSome:
        warn "Network configuration already set, ignore new value", network
        continue
      let (parsedParams, custom) = parseNetworkParams(network)
      params = Opt.some parsedParams
      # Simulate --custom-network while it is still not disabled.
      if custom:
        conf.customNetwork = some parsedParams
        simulatedCustomNetwork = true

  if conf.customNetwork.isSome:
    if params.isNone:
      warn "`--custom-network` is deprecated, please use `--network`"
    elif not simulatedCustomNetwork:
      warn "Network configuration already set by `--network`, `--custom-network` override it"
    params = if conf.customNetwork.isSome: Opt.some conf.customNetwork.get
             else: Opt.none(NetworkParams)
    if id.isNone:
      # WARNING: networkId and chainId are two distinct things
      # their usage should not be mixed in other places.
      # We only set networkId to chainId if networkId not set in cli and
      # --custom-network is set.
      # If chainId is not defined in config file, it's ok because
      # zero means CustomNet
      id = Opt.some NetworkId(params.value.config.chainId)

  if id.isNone and params.isSome:
    id = Opt.some NetworkId(params.value.config.chainId)

  if conf.customNetwork.isNone and params.isNone:
    params = Opt.some networkParams(id.value)

  conf.networkParams = params.expect("Network params exists")
  conf.networkId = id.expect("Network ID exists")

proc getRpcFlags(api: openArray[string]): set[RpcFlag] =
  if api.len == 0:
    return {RpcFlag.Eth}

  for item in repeatingList(api):
    case item.toLowerAscii()
    of "eth": result.incl RpcFlag.Eth
    of "debug": result.incl RpcFlag.Debug
    of "admin": result.incl RpcFlag.Admin
    else:
      error "Unknown RPC API: ", name=item
      quit QuitFailure

proc getRpcFlags*(conf: NimbusConf): set[RpcFlag] =
  getRpcFlags(conf.rpcApi)

proc getWsFlags*(conf: NimbusConf): set[RpcFlag] =
  getRpcFlags(conf.wsApi)

proc getDiscoveryFlags(api: openArray[string]): set[DiscoveryType] =
  if api.len == 0:
    return {DiscoveryType.V4, DiscoveryType.V5}

  for item in repeatingList(api):
    case item.toLowerAscii()
    of "none": result = {}
    of "v4": result.incl DiscoveryType.V4
    of "v5": result.incl DiscoveryType.V5
    of "all": result = {DiscoveryType.V4, DiscoveryType.V5}
    else:
      error "Unknown discovery type: ", name=item
      quit QuitFailure

proc getDiscoveryFlags*(conf: NimbusConf): set[DiscoveryType] =
  getDiscoveryFlags(conf.discovery)

proc getBootNodes*(conf: NimbusConf): seq[ENode] =
  var bootstrapNodes: seq[ENode]
  # Ignore standard bootnodes if customNetwork is loaded
  if conf.customNetwork.isNone:
    if conf.networkId == MainNet:
      bootstrapNodes.setBootnodes(MainnetBootnodes)
    elif conf.networkId == SepoliaNet:
      bootstrapNodes.setBootnodes(SepoliaBootnodes)
    elif conf.networkId == HoleskyNet:
      bootstrapNodes.setBootnodes(HoleskyBootnodes)
    elif conf.networkId == HoodiNet:
      bootstrapNodes.setBootnodes(HoodiBootnodes)
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
  conf.wsEnabled or conf.rpcEnabled

proc era1Dir*(conf: NimbusConf): string =
  string conf.era1DirFlag.get(OutDir conf.dataDir / "era1")

proc eraDir*(conf: NimbusConf): string =
  string conf.eraDirFlag.get(OutDir conf.dataDir / "era")

func dbOptions*(conf: NimbusConf, noKeyCache = false): DbOptions =
  DbOptions.init(
    maxOpenFiles = conf.rocksdbMaxOpenFiles,
    writeBufferSize = conf.rocksdbWriteBufferSize,
    rowCacheSize = conf.rocksdbRowCacheSize,
    blockCacheSize = conf.rocksdbBlockCacheSize,
    rdbKeyCacheSize =
      if noKeyCache: 0 else: conf.rdbKeyCacheSize,
    rdbVtxCacheSize = conf.rdbVtxCacheSize,
    rdbBranchCacheSize =
      # The import command does not use the key cache - better give it to branch
      if noKeyCache: conf.rdbKeyCacheSize + conf.rdbBranchCacheSize
      else: conf.rdbBranchCacheSize,

    rdbPrintStats = conf.rdbPrintStats,
  )

#-------------------------------------------------------------------
# TOML serializer overloads of SecondarySources
#-------------------------------------------------------------------

proc readValue*(r: var TomlReader, val: var OutDir)
       {.gcsafe, raises: [IOError, SerializationError].} =
  discard r.parseString(string(val))

proc readValue*(r: var TomlReader, val: var InputFile)
       {.gcsafe, raises: [IOError, SerializationError].} =
  discard r.parseString(string(val))

proc readValue*(r: var TomlReader, val: var NetworkParams)
       {.gcsafe, raises: [IOError, SerializationError].} =
  # Not actually parse it, only to silence compiler
  discard r.parseAsString()

proc readValue*(r: var TomlReader, val: var Port)
       {.gcsafe, raises: [IOError, SerializationError].} =
  val = r.parseInt(int64).Port

proc readValue*(r: var TomlReader, val: var IpAddress)
       {.gcsafe, raises: [IOError, SerializationError].} =
  try: val = parseIpAddress(r.parseAsString())
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

proc readValue*(r: var TomlReader, val: var enr.Record)
       {.gcsafe, raises: [IOError, SerializationError].} =
  val = fromURI(enr.Record, r.parseAsString()).valueOr:
    raise newException(SerializationError, $error)

proc readValue*(r: var TomlReader, val: var NatConfig)
       {.gcsafe, raises: [IOError, SerializationError].} =
  try: val = NatConfig.parseCmdArg(r.parseAsString())
  except ValueError as exc:
    raise newException(SerializationError, exc.msg)

#-------------------------------------------------------------------
# Constructor
#-------------------------------------------------------------------

# KLUDGE: The `load()` template does currently not work within any exception
#         annotated environment.
{.pop.}

proc makeConfig*(cmdLine = commandLineParams()): NimbusConf =
  ## Note: this function is not gc-safe
  try:
    result = NimbusConf.load(
      cmdLine,
      version = NimbusBuild,
      copyrightBanner = NimbusHeader,
      secondarySources = proc (
        conf: NimbusConf, sources: ref SecondarySources
      ) {.raises: [ConfigurationError].} =
        if conf.configFile.isSome:
          sources.addConfigFile(Toml, conf.configFile.get)
    )
  except CatchableError as err:
    if err[] of ConfigurationError and err.parent != nil:
      if err.parent[] of TomlFieldReadingError:
        let fieldName = ((ref TomlFieldReadingError)(err.parent)).field
        echo "Error when parsing ", fieldName, ": ", err.msg
      elif err.parent[] of TomlReaderError:
        type TT = ref TomlReaderError
        echo TT(err).formatMsg("")
      else:
        echo "Error when parsing config file: ", err.msg
    else:
      echo "Error when parsing command line params: ", err.msg
    quit QuitFailure

  processNetworkParamsAndNetworkId(result)

  if result.cmd == noCommand:
    if result.udpPort == Port(0):
      # if udpPort not set in cli, then
      result.udpPort = result.tcpPort

when isMainModule:
  # for testing purpose
  discard makeConfig()
