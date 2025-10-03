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
    net
  ],
  pkg/[
    chronicles,
    confutils,
    confutils/defs,
    confutils/std/net
  ],
  eth/[common, net/nat, enr/enr, enode/enode],
  ../execution_chain/[constants, compile_info],
  ../execution_chain/common/chain_config,
  ../execution_chain/db/opts

export net, defs

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
  NRpcCmd* {.pure.} = enum
    `sync`

  NRpcConf* = object of RootObj
    ## Main NRpc configuration object

    beaconApi* {.
      desc: "Beacon API url"
      defaultValue: ""
      name: "beacon-api" .}: string

    network* {.
      desc: "Name or id number of Ethereum network"
      longDesc:
        "- mainnet/1       : Ethereum main network\n" &
        "- sepolia/11155111: Test network (proof-of-work)\n" &
        "- holesky/17000   : The holesovice post-merge testnet\n" &
        "- hoodi/560048    : The second long-standing, merged-from-genesis, public Ethereum testnet\n" &
        "- path            : Custom config for private Ethereum Network (as /path/to/metadata)\n" &
        "                    Path to a folder containing custom network configuration files\n" &
        "                    such as genesis.json, config.yaml, etc.\n" &
        "                    config.yaml is the configuration file for the CL client"
      defaultValue: "" # the default value is set in makeConfig
      defaultValueDesc: "mainnet(1)"
      abbr: "i"
      name: "network" }: string

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

    of `sync`:

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

func parseHexOrDec256(p: string): UInt256 {.raises: [ValueError].} =
  if startsWith(p, "0x"):
    parse(p, UInt256, 16)
  else:
    parse(p, UInt256, 10)

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

proc parseCmdArg(T: type NetworkParams, p: string): T
    {.gcsafe, raises: [ValueError].} =
  try:
    if not loadNetworkParams(p, result):
      raise newException(ValueError, "failed to load customNetwork")
  except CatchableError:
    raise newException(ValueError, "failed to load customNetwork")

func completeCmdArg(T: type NetworkParams, val: string): seq[string] =
  return @[]

func decOrHex(s: string): bool =
  const allowedDigits = Digits + HexDigits + {'x', 'X'}
  for c in s:
    if c notin allowedDigits:
      return false
  true

proc parseNetworkId(network: string): Opt[NetworkId] =
  try:
    Opt.some parseHexOrDec256(network)
  except CatchableError:
    error "Failed to parse network id", id=network
    Opt.none NetworkId

proc getNetworkId(conf: NRpcConf): Opt[NetworkId] =
  if conf.network.len == 0:
    return Opt.some MainNet

  let network = toLowerAscii(conf.network)
  case network
  of "mainnet": return Opt.some MainNet
  of "sepolia": return Opt.some SepoliaNet
  of "holesky": return Opt.some HoleskyNet
  of "hoodi"  : return Opt.some HoodiNet
  else:
    if decOrHex(network):
      return parseNetworkId(network)

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

  var
    networkId = result.getNetworkId()
    customNetwork = false

  if result.network.len > 0 and networkId.isNone:
    customNetwork = true
    var networkParams = NetworkParams()
    if not loadNetworkParams(result.network.joinPath("genesis.json"), networkParams):
      error "Failed to load customNetwork", path=result.network
      quit QuitFailure
    result.networkParams = networkParams
    if networkId.isNone:
      # WARNING: networkId and chainId are two distinct things
      # they usage should not be mixed in other places.
      # We only set networkId to chainId if networkId not set in cli and
      # --custom-network is set.
      # If chainId is not defined in config file, it's ok because
      # zero means CustomNet
      networkId = Opt.some(NetworkId(result.networkParams.config.chainId))

  result.networkId = networkId.expect("Network ID exists")

  if not customNetwork:
    result.networkParams = networkParams(result.networkId)


when isMainModule:
  # for testing purpose
  discard makeConfig()
