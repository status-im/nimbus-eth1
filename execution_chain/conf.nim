# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [], gcsafe.}

import
  std/[options, strutils, os, uri, net],
  chronos/transports/common,
  chronicles,
  confutils,
  confutils/defs,
  confutils/std/net as confnet,
  confutils/toml/defs as tomldefs,
  confutils/json/defs as jsdefs,
  json_serialization/std/net as jsnet,
  toml_serialization/std/net as tomlnet,
  results,
  beacon_chain/buildinfo,
  beacon_chain/nimbus_binary_common,
  toml_serialization,
  eth/[common, net/nat, net/nat_toml],
  ./networking/bootnodes,
  ./[constants, compile_info, version_info],
  ./common/chain_config,
  ./db/opts

export net, defs, jsdefs, jsnet, nat_toml, nimbus_binary_common, options

const NimbusCopyright* =
  "Copyright (c) 2018-" & compileYear & " Status Research & Development GmbH"

func getLogLevels(): string =
  var logLevels: seq[string]
  for level in LogLevel:
    if level < enabledLogLevel:
      continue
    logLevels.add($level)
  join(logLevels, ", ")

const
  defaultExecutionPort*    = 30303
  defaultHttpPort          = 8545
  # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/authentication.md#jwt-specifications
  defaultEngineApiPort*    = 8551
  logLevelDesc = getLogLevels()

let
  defaultListenAddress      = getAutoAddress(Port(0)).toIpAddress()
  defaultListenAddressDesc  = $defaultListenAddress & ", meaning all network interfaces"

type
  NimbusCmd* {.pure.} = enum
    executionClient
    `import`

  RpcFlag* {.pure.} = enum
    ## RPC flags
    Eth                           ## enable eth_ set of RPC API
    Debug                         ## enable debug_ set of RPC API
    Admin                         ## enable admin_ set of RPC API

  DiscoveryType* {.pure.} = enum
    V4
    V5

  ExecutionClientConf* = object
    ## Main configuration for the execution client - when updating, coordinate
    ## options shared with other executables (logging, metrics etc)
    configFile* {.
      separator: "ETHEREUM OPTIONS:"
      desc: "Loads the configuration from a TOML file"
      name: "config-file" .}: Option[InputFile]

    dataDirFlag* {.
      desc: "The directory where nimbus will store all blockchain data"
      abbr: "d"
      name: "data-dir" .}: Option[OutDir]

    era1DirFlag* {.
      desc: "Directory for era1 archive (pre-merge history)"
      defaultValueDesc: "<data-dir>/era1"
      name: "era1-dir" .}: Option[OutDir]

    eraDirFlag* {.
      desc: "Directory for era archive (post-merge history)"
      defaultValueDesc: "<data-dir>/era"
      name: "era-dir" .}: Option[OutDir]

    keyStoreDirFlag* {.
      desc: "Load one or more keystore files from this directory"
      defaultValueDesc: "inside datadir"
      abbr: "k"
      name: "key-store" .}: Option[OutDir]

    importKey* {.
      desc: "Import unencrypted 32 bytes hex private key from a file"
      defaultValue: ""
      abbr: "e"
      name: "import-key" .}: InputFile

    trustedSetupFile* {.
      hidden
      desc: "Alternative EIP-4844 trusted setup file"
      defaultValue: none(string)
      defaultValueDesc: "Baked in trusted setup"
      name: "debug-trusted-setup-file" .}: Option[string]

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

    # https://ethereum.org/developers/docs/networks/#ethereum-testnets
    network {.
      desc: "Name or id number of Ethereum network"
      longDesc:
        "- mainnet/1       : Ethereum main network\n" &
        "- sepolia/11155111: Testnet for smart contract testing\n" &
        "- hoodi/560048    : Testnet for staking and hard forks\n" &
        "- custom/path     : /path/to/genesis-or-network-configuration.json\n" &
        "Both --network: name/path --network:id can be set at the same time to override network id number"
      defaultValue: @[] # the default value is set in makeConfig
      defaultValueDesc: "mainnet(1)"
      abbr: "i"
      name: "network" .}: seq[string]

    customNetwork {.
      ignore
      desc: "Use custom genesis block for private Ethereum Network (as /path/to/genesis.json)"
      defaultValueDesc: ""
      abbr: "c"
      name: "custom-network" .}: Option[NetworkParams]

    networkId* {.
      ignore # this field is not processed by confutils
      defaultValue: MainNet # the defaultValue value is set by `makeConfig`
      defaultValueDesc: "MainNet"
      name: "network-id" .}: NetworkId

    networkParams* {.
      ignore # this field is not processed by confutils
      defaultValue: NetworkParams() # the defaultValue value is set by `makeConfig`
      name: "network-params" .}: NetworkParams

    logLevel* {.
      separator: "\pLOGGING AND DEBUGGING OPTIONS:"
      desc: "Sets the log level for process and topics (" & logLevelDesc & ")"
      defaultValue: "INFO"
      name: "log-level" .}: string

    logFormat* {.
      desc: "Choice of log format (auto, colors, nocolors, json)"
      defaultValueDesc: "auto"
      defaultValue: StdoutLogKind.Auto
      name: "log-format" .}: StdoutLogKind

    metrics* {.flatten.}: MetricsConf

    bootstrapNodes {.
      separator: "\pNETWORKING OPTIONS:"
      desc: "Specifies one or more bootstrap nodes(ENR or enode URL) to use when connecting to the network"
      defaultValue: @[]
      defaultValueDesc: ""
      abbr: "b"
      name: "bootstrap-node" .}: seq[string]

    bootstrapFile {.
      desc: "Specifies a file of bootstrap Ethereum network addresses(ENR or enode URL). " &
            "Both line delimited or YAML format are supported"
      defaultValue: ""
      name: "bootstrap-file" .}: InputFile

    staticPeers {.
      desc: "Connect to one or more trusted peers(ENR or enode URL)"
      defaultValue: @[]
      defaultValueDesc: ""
      name: "static-peers" .}: seq[string]

    staticPeersFile {.
      desc: "Specifies a file of trusted peers addresses(ENR or enode URL). " &
            "Both line delimited or YAML format are supported"
      defaultValue: ""
      name: "static-peers-file" .}: InputFile

    reconnectMaxRetry* {.
      desc: "Specifies max number of retries if static peers disconnected/not connected. " &
            "0 = infinite."
      defaultValue: 0
      name: "reconnect-max-retry" .}: int

    reconnectInterval* {.
      desc: "Interval in seconds before next attempt to reconnect to static peers. Min 5 seconds."
      defaultValue: 15
      name: "reconnect-interval" .}: int

    listenAddress* {.
      desc: "Listening IP address for Ethereum P2P and Discovery traffic"
      defaultValue: defaultListenAddress
      defaultValueDesc: $defaultListenAddressDesc
      name: "listen-address" .}: IpAddress

    tcpPort* {.
      desc: "Ethereum P2P network listening TCP port"
      defaultValue: defaultExecutionPort
      defaultValueDesc: $defaultExecutionPort
      name: "tcp-port" .}: Port

    udpPortFlag* {.
      desc: "Ethereum P2P network listening UDP port"
      defaultValueDesc: "default to --tcp-port"
      name: "udp-port" .}: Option[Port]

    maxPeers* {.
      desc: "Maximum number of peers to connect to"
      defaultValue: 25
      name: "max-peers" .}: int

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

    dynamicBatchSize* {.
      hidden
      defaultValue: false
      name: "debug-dynamic-batch-size" .}: bool

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

    aristoDbMaxSnapshots* {.
      hidden
      defaultValue: defaultMaxSnapshots
      defaultValueDesc: $defaultMaxSnapshots
      name: "debug-aristo-db-max-snapshots" .}: int

    eagerStateRootCheck* {.
      hidden
      desc: "Eagerly check state roots when syncing finalized blocks"
      name: "debug-eager-state-root".}: bool

    deserializeFcState* {.
      hidden
      defaultValue: true
      name: "debug-deserialize-fc-state" .}: bool

    statelessProviderEnabled* {.
      separator: "\pSTATELESS PROVIDER OPTIONS:"
      desc: "Enable the stateless provider. This turns on the features required" &
        " by stateless clients such as generation and storage of block witnesses" &
        " and serving these witnesses to peers over the p2p network."
      defaultValue: false
      name: "stateless-provider" .}: bool

    statelessWitnessValidation* {.
      hidden
      desc: "Enable full validation of execution witnesses."
      defaultValue: false
      name: "stateless-witness-validation" .}: bool

    case cmd* {.
      command
      defaultValue: NimbusCmd.executionClient .}: NimbusCmd

    of NimbusCmd.executionClient:
      httpPort* {.
        separator: "\pLOCAL SERVICES OPTIONS:"
        desc: "Listening port of the HTTP server(rpc, ws)"
        defaultValue: defaultHttpPort
        defaultValueDesc: $defaultHttpPort
        name: "http-port" .}: Port

      httpAddress* {.
        desc: "Listening IP address of the HTTP server(rpc, ws)"
        defaultValue: defaultAdminListenAddress
        defaultValueDesc: $defaultAdminListenAddressDesc
        name: "http-address" .}: IpAddress

      rpcEnabled* {.
        desc: "Enable the JSON-RPC server"
        defaultValue: false
        name: "rpc" .}: bool

      rpcApi {.
        desc: "Enable specific set of RPC API (available: eth, debug, admin)"
        defaultValue: @[]
        defaultValueDesc: $RpcFlag.Eth
        name: "rpc-api" .}: seq[string]

      wsEnabled* {.
        desc: "Enable the Websocket JSON-RPC server"
        defaultValue: false
        name: "ws" .}: bool

      wsApi {.
        desc: "Enable specific set of Websocket RPC API (available: eth, debug, admin)"
        defaultValue: @[]
        defaultValueDesc: $RpcFlag.Eth
        name: "ws-api" .}: seq[string]

      historyExpiry* {.
        desc: "Enable the data from Portal Network"
        defaultValue: false
        name: "history-expiry" .}: bool

      historyExpiryLimit* {.
        hidden
        desc: "Limit the number of blocks to be kept in history"
        name: "debug-history-expiry-limit" .}: Option[BlockNumber]

      portalUrl* {.
        desc: "URL of the Portal JSON-RPC API"
        defaultValue: ""
        name: "portal-url" .}: string

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

      # https://eips.ethereum.org/EIPS/eip-7872
      maxBlobs* {.
        desc: "EIP-7872 maximum blobs used when building a local payload"
        name: "max-blobs" .}: Option[uint8]

      # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/authentication.md#key-distribution
      jwtSecret* {.
        desc: "Path to a file containing a 32 byte hex-encoded shared secret" &
          " needed for websocket authentication. By default, the secret key" &
          " is auto-generated."
        defaultValueDesc: "\"jwt.hex\" in the data directory (see --data-dir)"
        name: "jwt-secret" .}: Option[InputFile]

      jwtSecretValue* {.
        hidden
        desc: "Hex string with jwt secret"
        defaultValueDesc: "\"jwt.hex\" in the data directory (see --data-dir)"
        name: "debug-jwt-secret-value" .}: Option[string]

      snapSyncEnabled* {.
        hidden
        desc: "Start syncer using snap to be followed by beacon sync." &
              " Otherwise, a full sync will be performed by starting beacon" &
              " sync immediately"
        defaultValue: false
        name: "debug-snap-sync" .}: bool

      snapServerEnabled* {.
        hidden
        desc: "Always start the snap peer service, even when snap sync is" &
              " disabled. With snap sync enabled, the snap peer service is" &
              " also available"
        defaultValue: false
        name: "debug-snap-server" .}: bool

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

      bootstrapBlocksFile* {.
        hidden
        desc: "Import RLP encoded block files before starting the client"
        defaultValue: @[]
        name: "debug-bootstrap-blocks-file" .}: seq[InputFile]

      bootstrapBlocksFinalized* {.
        hidden
        desc: "Treat bootstrap RLP imports as finalized chain segments"
        defaultValue: false
        name: "debug-bootstrap-finalized" .}: bool

    # We now load all the import specific configurations directly into  ExecutionClientConf
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
      validation* {.
        hidden
        desc: "Enable per-chunk validation"
        defaultValue: false
        name: "debug-validation".}: bool

      fullValidation* {.
        hidden
        desc: "Enable full per-block validation (slow)"
        defaultValue: false
        name: "debug-full-validation".}: bool

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

func parseHexOrDec256(p: string): UInt256 {.raises: [ValueError].} =
  if startsWith(p, "0x"):
    parse(p, UInt256, 16)
  else:
    parse(p, UInt256, 10)

proc dataDir*(config: ExecutionClientConf): string =
  # TODO load network name from directory, when using custom network?
  string config.dataDirFlag.get(OutDir defaultDataDir("", config.networkId.name()))

proc keyStoreDir*(config: ExecutionClientConf): string =
  string config.keyStoreDirFlag.get(OutDir config.dataDir() / "keystore")

func parseCmdArg(T: type NetworkId, p: string): T
    {.gcsafe, raises: [ValueError].} =
  parseHexOrDec256(p)

func completeCmdArg(T: type NetworkId, val: string): seq[string] =
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

iterator repeatingList(listOfList: openArray[string]): string =
  for strList in listOfList:
    var list = newSeq[string]()
    processList(strList, list)
    for item in list:
      yield item

func breakRepeatingList(listOfList: openArray[string]): seq[string] =
  for strList in listOfList:
    processList(strList, result)

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
  of "hoodi"  : (networkParams(HoodiNet), false)
  else:
    var params: NetworkParams
    if not loadNetworkParams(network, params):
      # `loadNetworkParams` have it's own error log
      quit QuitFailure
    (params, true)

proc processNetworkParamsAndNetworkId(config: var ExecutionClientConf) =
  if config.network.len == 0 and config.customNetwork.isNone:
    # Default value if none is set
    config.networkId = MainNet
    config.networkParams = networkParams(MainNet)
    return

  var
    params: Opt[NetworkParams]
    id: Opt[NetworkId]
    simulatedCustomNetwork = false

  for network in config.network:
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
        config.customNetwork = some parsedParams
        simulatedCustomNetwork = true

  if config.customNetwork.isSome:
    if params.isNone:
      warn "`--custom-network` is deprecated, please use `--network`"
    elif not simulatedCustomNetwork:
      warn "Network configuration already set by `--network`, `--custom-network` override it"
    params = if config.customNetwork.isSome: Opt.some config.customNetwork.get
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

  if config.customNetwork.isNone and params.isNone:
    params = Opt.some networkParams(id.value)

  config.networkParams = params.expect("Network params exists")
  config.networkId = id.expect("Network ID exists")

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

proc getRpcFlags*(config: ExecutionClientConf): set[RpcFlag] =
  getRpcFlags(config.rpcApi)

proc getWsFlags*(config: ExecutionClientConf): set[RpcFlag] =
  getRpcFlags(config.wsApi)

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

proc getDiscoveryFlags*(config: ExecutionClientConf): set[DiscoveryType] =
  getDiscoveryFlags(config.discovery)

proc getBootstrapNodes*(config: ExecutionClientConf): BootstrapNodes =
  # Ignore standard bootnodes if customNetwork is loaded
  if config.customNetwork.isNone:
    if config.networkId == MainNet:
      getBootstrapNodes("mainnet", result).expect("no error")
    elif config.networkId == SepoliaNet:
      getBootstrapNodes("sepolia", result).expect("no error")
    elif config.networkId == HoodiNet:
      getBootstrapNodes("hoodi", result).expect("no error")

  let list = breakRepeatingList(config.bootstrapNodes)
  parseBootstrapNodes(list, result).isOkOr:
    warn "Error when parsing bootstrap nodes", msg=error

  if config.bootstrapFile.string.len > 0:
    loadBootstrapNodes(config.bootstrapFile.string, result).isOkOr:
      warn "Error when parsing bootstrap nodes from file", msg=error, file=config.bootstrapFile.string

proc getStaticPeers*(config: ExecutionClientConf): BootstrapNodes =
  let list = breakRepeatingList(config.staticPeers)
  parseBootstrapNodes(list, result).isOkOr:
    warn "Error when parsing static peers", msg=error

  if config.staticPeersFile.string.len > 0:
    loadBootstrapNodes(config.staticPeersFile.string, result).isOkOr:
      warn "Error when parsing static peers from file", msg=error, file=config.staticPeersFile.string

func getAllowedOrigins*(config: ExecutionClientConf): seq[Uri] =
  for item in repeatingList(config.allowedOrigins):
    result.add parseUri(item)

func engineApiServerEnabled*(config: ExecutionClientConf): bool =
  config.engineApiEnabled or config.engineApiWsEnabled

func shareServerWithEngineApi*(config: ExecutionClientConf): bool =
  config.engineApiServerEnabled and
    config.engineApiPort == config.httpPort

func httpServerEnabled*(config: ExecutionClientConf): bool =
  config.wsEnabled or config.rpcEnabled

proc era1Dir*(config: ExecutionClientConf): string =
  string config.era1DirFlag.get(OutDir config.dataDir / "era1")

proc eraDir*(config: ExecutionClientConf): string =
  string config.eraDirFlag.get(OutDir config.dataDir / "era")

func udpPort*(config: ExecutionClientConf): Port =
  config.udpPortFlag.get(config.tcpPort)

func dbOptions*(config: ExecutionClientConf, noKeyCache = false): DbOptions =
  DbOptions.init(
    maxOpenFiles = config.rocksdbMaxOpenFiles,
    writeBufferSize = config.rocksdbWriteBufferSize,
    rowCacheSize = config.rocksdbRowCacheSize,
    blockCacheSize = config.rocksdbBlockCacheSize,
    rdbKeyCacheSize =
      if noKeyCache: 0 else: config.rdbKeyCacheSize,
    rdbVtxCacheSize = config.rdbVtxCacheSize,
    rdbBranchCacheSize =
      # The import command does not use the key cache - better give it to branch
      if noKeyCache: config.rdbKeyCacheSize + config.rdbBranchCacheSize
      else: config.rdbBranchCacheSize,
    rdbPrintStats = config.rdbPrintStats,
    maxSnapshots = config.aristoDbMaxSnapshots,
  )

func jwtSecretOpt*(config: ExecutionClientConf): Opt[InputFile] =
  if config.jwtSecret.isSome:
    Opt.some config.jwtSecret.get
  else:
    Opt.none InputFile

{.pop.}

#-------------------------------------------------------------------
# Constructor
#-------------------------------------------------------------------

proc makeConfig*(cmdLine = commandLineParams(), ignoreUnknown = false): ExecutionClientConf =
  ## Note: this function is not gc-safe
  result = ExecutionClientConf.loadWithBanners(
    ClientId, NimbusCopyright, [], ignoreUnknown, cmdLine
  ).valueOr:
    writePanicLine error # Logging not yet set up
    quit QuitFailure

  processNetworkParamsAndNetworkId(result)

when isMainModule:
  # for testing purpose
  discard makeConfig()
