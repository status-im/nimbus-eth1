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
    net
  ],
  pkg/[
    chronicles,
    confutils,
    confutils/defs,
    confutils/std/net
  ],
  eth/[common, net/nat, p2p/enode, p2p/discoveryv5/enr],
  "../nimbus"/[constants, compile_info],
  ../nimbus/common/chain_config,
  ../nimbus/db/opts

export net, defs

func defaultDataDir*(): string =
  when defined(windows):
    getHomeDir() / "AppData" / "Roaming" / "Nimbus"
  elif defined(macosx):
    getHomeDir() / "Library" / "Application Support" / "Nimbus"
  else:
    getHomeDir() / ".cache" / "nimbus"

func getLogLevels(): string =
  var logLevels: seq[string]
  for level in LogLevel:
    if level < enabledLogLevel:
      continue
    logLevels.add($level)
  join(logLevels, ", ")

const
  logLevelDesc = getLogLevels()

type
  ChainDbMode* {.pure.} = enum
    Aristo
    AriPrune

  NRpcCmd* {.pure.} = enum
    `external_sync`

  NRpcConf* = object of RootObj
    ## Main NRpc configuration object
    
    beaconApi* {.
      desc: "Beacon API url"
      defaultValue: ""
      name: "beacon-api" .}: string

    network {.
      desc: "Name or id number of Ethereum network(mainnet(1), sepolia(11155111), holesky(17000), other=custom)"
      longDesc:
        "- mainnet: Ethereum main network\n" &
        "- sepolia: Test network (pow+pos) with merge\n" &
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

    case cmd* {.
      command
      desc: "" }: NRpcCmd

    of `external_sync`:

      # https://github.com/ethereum/execution-apis/blob/v1.0.0-beta.4/src/engine/authentication.md#key-distribution
      jwtSecret* {.
        desc: "Path to a file containing a 32 byte hex-encoded shared secret" &
          " needed for websocket authentication. By default, the secret key" &
          " is auto-generated."
        defaultValueDesc: "\"jwt.hex\" in the data directory (see --data-dir)"
        name: "jwt-secret" .}: Option[InputFile]

      elEngineApi* {.
        desc: "Eth1 Engine API url"
        defaultValue: ""
        name: "el-engine-api" .}: string

func parseCmdArg(T: type NetworkId, p: string): T
    {.gcsafe, raises: [ValueError].} =
  parseInt(p).T

func completeCmdArg(T: type NetworkId, val: string): seq[string] =
  return @[]

func parseCmdArg*(T: type enr.Record, p: string): T {.raises: [ValueError].} =
  result = fromURI(enr.Record, p).valueOr:
    raise newException(ValueError, "Invalid ENR")

func completeCmdArg*(T: type enr.Record, val: string): seq[string] =
  return @[]

proc parseCmdArg(T: type NetworkParams, p: string): T
    {.gcsafe, raises: [ValueError].} =
  try:
    if not loadNetworkParams(p, result):
      raise newException(ValueError, "failed to load customNetwork")
  except CatchableError:
    raise newException(ValueError, "failed to load customNetwork")

func completeCmdArg(T: type NetworkParams, val: string): seq[string] =
  return @[]


proc getNetworkId(conf: NRpcConf): Opt[NetworkId] =
  if conf.network.len == 0:
    return Opt.none NetworkId

  let network = toLowerAscii(conf.network)
  case network
  of "mainnet": return Opt.some MainNet
  of "sepolia": return Opt.some SepoliaNet
  of "holesky": return Opt.some HoleskyNet
  else:
    try:
      Opt.some parseInt(network).NetworkId
    except CatchableError:
      error "Failed to parse network name or id", network
      quit QuitFailure

# KLUDGE: The `load()` template does currently not work within any exception
#         annotated environment.
{.pop.}

proc makeConfig*(cmdLine = commandLineParams()): NRpcConf
    {.raises: [CatchableError].} =
  ## Note: this function is not gc-safe

  # The try/catch clause can go away when `load()` is clean
  try:
    {.push warning[ProveInit]: off.}
    result = NRpcConf.load(
      cmdLine
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
      networkId = Opt.some(NetworkId(result.networkParams.config.chainId))

  if networkId.isNone:
    # bootnodes is set via getBootNodes
    networkId = Opt.some MainNet

  result.networkId = networkId.get()

  if result.customNetwork.isNone:
    result.networkParams = networkParams(result.networkId)


when isMainModule:
  # for testing purpose
  discard makeConfig()
