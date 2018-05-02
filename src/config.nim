# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import parseopt, strutils, net, ethp2p, eth_keyfile, eth_keys, json,
       nimcrypto

const
  NimbusName* = "Nimbus"
  ## project name string

  NimbusCopyright* = "Copyright (C) 2018 Status Research & Development GmbH"
  ## copyright string

  NimbusMajor*: int = 0
  ## is the major number of Nimbus' version.

  NimbusMinor*: int = 0
  ## is the minor number of Nimbus' version.

  NimbusPatch*: int = 1
  ## is the patch number of Nimbus' version.

  NimbusVersion* = $NimbusMajor & "." & $NimbusMinor & "." & $NimbusPatch
  ## is the version of Nimbus as a string.

type
  ConfigStatus* = enum
    ## Configuration status flags
    Success,                    ## Success
    EmptyOption,                ## No options in category
    ErrorUnknownOption,         ## Unknown option in command line found
    ErrorParseOption,           ## Error in parsing command line option
    Error                       ## Unspecified error

  RpcFlags* {.pure.} = enum
    ## RPC flags
    Enabled                     ## RPC enabled

  RpcConfiguration* = object
    ## JSON-RPC configuration object
    flags*: set[RpcFlags]       ## RPC flags
    bindAddress*: IpAddress     ## RPC bind address
    bindPort*: uint16           ## RPC bind port
    allowedIPs*: seq[IpAddress] ## Sequence of allowed IP addresses
    username*: string           ## RPC authorization username
    password*: string           ## RPC authorization password

  NetworkFlags* = enum
    ## Ethereum network flags
    LocalNet,                   ## Use local network only
    TestNet,                    ## Use test network only
    MainNet,                    ## Use main network only
    NoDiscover,                 ## Peer discovery disabled
    V5Discover,                 ## Dicovery V5 enabled

  DebugFlags* {.pure.} = enum
    ## Debug selection flags
    Enabled,                    ## Debugging enabled
    Test1,                      ## Test1 enabled
    Test2,                      ## Test2 enabled
    Test3                       ## Test3 enabled

  NetConfiguration* = object
    ## Network configuration object
    flags*: set[NetworkFlags]
    bootNodes*: seq[ENode]
    bootNodes4*: seq[ENode]
    bootNodes5*: seq[ENode]
    bindPort*: uint16
    discPort*: uint16
    maxPeers*: int
    maxPendingPeers*: int
    nodeKey*: PrivateKey

  DebugConfiguration* = object
    ## Debug configuration object
    flags*: set[DebugFlags]

  NimbusConfiguration* = ref object
    ## Main Nimbus configuration object
    rpc*: RpcConfiguration       ## JSON-RPC configuration
    net*: NetConfiguration       ## Network configuration
    debug*: DebugConfiguration   ## Debug configuration

var nimbusConfig {.threadvar.}: NimbusConfiguration

proc initConfiguration(): NimbusConfiguration =
  ## Allocates and initializes `NimbusConfiguration` with default values
  result = new NimbusConfiguration

  ## RPC defaults
  result.rpc.flags = {}
  result.rpc.bindAddress = parseIpAddress("127.0.0.1")
  result.rpc.bindPort = uint16(7654)
  result.rpc.username = ""
  result.rpc.password = ""
  result.rpc.allowedIPs = newSeq[IpAddress]()

  ## Network defaults
  result.net.flags = {TestNet}
  result.net.bootNodes = newSeq[ENode]()
  result.net.bootNodes4 = newSeq[ENode]()
  result.net.bootNodes5 = newSeq[ENode]()
  result.net.maxPeers = 25
  result.net.maxPendingPeers = 0
  result.net.bindPort = 30303'u16
  result.net.discPort = 30303'u16

  ## Debug defaults
  result.debug.flags = {}

proc getConfiguration*(): NimbusConfiguration =
  ## Retreive current configuration object `NimbusConfiguration`.
  if isNil(nimbusConfig):
    nimbusConfig = initConfiguration()
  result = nimbusConfig

proc processList(v: string, o: var seq[string]) =
  ## Process comma-separated list of strings.
  if len(v) > 0:
    for n in v.split({' ', ','}):
      if len(n) > 0:
        o.add(n)

proc processInteger(v: string, o: var int): ConfigStatus =
  ## Convert string to integer.
  try:
    o  = parseInt(v)
    result = Success
  except:
    result = ErrorParseOption

proc processIpAddress(v: string, o: var IpAddress): ConfigStatus =
  ## Convert string to IpAddress.
  try:
    o = parseIpAddress(v)
    result = Success
  except:
    result = ErrorParseOption

proc processAddressesList(v: string, o: var seq[IpAddress]): ConfigStatus =
  ## Convert comma-separated list of strings to list of IpAddress.
  var
    address: IpAddress
    list = newSeq[string]()
  processList(v, list)
  for item in list:
    result = processIpAddress(item, address)
    if result == Success:
      o.add(address)
    else:
      break

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

proc processRpcArguments(key, value: string): ConfigStatus =
  ## Processes only `RPC` related command line options
  result = Success
  let config = getConfiguration()
  let skey = key.toLowerAscii()
  if skey == "rpc":
    config.rpc.flags.incl(Enabled)
  elif skey == "rpcbind":
    result = processIpAddress(value, config.rpc.bindAddress)
  elif skey == "rpcport":
    var res = 0
    result = processInteger(value, res)
    if result == Success:
      config.rpc.bindPort = uint16(res and 0xFFFF)
  elif skey == "rpcuser":
    config.rpc.username = value
  elif skey == "rpcpassword":
    config.rpc.password = value
  elif skey == "rpcallowip":
    result = processAddressesList(value, config.rpc.allowedIPs)
  else:
    result = EmptyOption

proc processNetArguments(key, value: string): ConfigStatus =
  ## Processes only `Networking` related command line options
  result = Success
  let config = getConfiguration()
  let skey = key.toLowerAscii()
  if skey == "bootnodes":
    result = processENodesList(value, config.net.bootnodes)
  elif skey == "bootnodesv4":
    result = processENodesList(value, config.net.bootNodes4)
  elif skey == "bootnodesv5":
    result = processENodesList(value, config.net.bootNodes5)
  elif skey == "testnet":
    config.net.flags.incl(TestNet)
    config.net.flags.excl(LocalNet)
    config.net.flags.excl(MainNet)
  elif skey == "localnet":
    config.net.flags.incl(LocalNet)
    config.net.flags.excl(TestNet)
    config.net.flags.excl(MainNet)
  elif skey == "mainnet":
    config.net.flags.incl(MainNet)
    config.net.flags.excl(LocalNet)
    config.net.flags.excl(TestNet)
  elif skey == "nodiscover":
    config.net.flags.incl(NoDiscover)
  elif skey == "v5discover":
    config.net.flags.incl(V5Discover)
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
  else:
    result = EmptyOption

proc dumpConfiguration*(): string =
  ## Dumps current configuration as string
  let config = getConfiguration()
  result = repr config

template checkArgument(a, b, c, e: untyped) =
  var res = (a)(string((b)), string((c)))
  if res == Success:
    continue
  elif res == ErrorParseOption:
    (e) = "Error processing option [" & key & "] with value [" & value & "]"
    result = res
    break

proc getVersionString*(): string =
  result = NimbusName & ", " & NimbusVersion & "\n" & NimbusCopyright & "\n"

proc getHelpString*(): string =
  result = getVersionString()
  result &= """

USAGE:
  nimbus [options]

ETHEREUM OPTIONS:
  --keyfile:<value>       Use keyfile storage file

NETWORKING OPTIONS:
  --bootnodes:<value>     Comma separated enode URLs for P2P discovery bootstrap (set v4+v5 instead for light servers)
  --bootnodesv4:<value>   Comma separated enode URLs for P2P v4 discovery bootstrap (light server, full nodes)
  --botnoodesv5:<value>   Comma separated enode URLs for P2P v5 discovery bootstrap (light server, light nodes)
  --port:<value>          Network listening TCP port (default: 30303)
  --discport:<value>      Netowkr listening UDP port (default: 30303)
  --maxpeers:<value>      Maximum number of network peers (default: 25)
  --maxpendpeers:<value>  Maximum number of pending connection attempts (default: 0)
  --nodiscover            Disables the peer discovery mechanism (manual peer addition)
  --v5discover            Enables the experimental RLPx V5 (Topic Discovery) mechanism
  --nodekey:<value>       P2P node private key (as hexadecimal string)
  --testnet               Use Ethereum Test Network
  --mainnet               Use Ethereum Main Network
  --localnet              Use local network only

API AND CONSOLE OPTIONS:
  --rpc                   Enable the HTTP-RPC server
  --rpcbind:<value>       HTTP-RPC server will bind to given address (default: 127.0.0.1)
  --rpcport:<value>       HTTP-RPC server listening port (default: 7654)
  --rpcuser:<value>       HTTP-RPC authorization username
  --rpcpassword:<value>   HTTP-RPC authorization password
  --rpcallowip:<value>    Allow HTTP-RPC connections from specified IP addresses

LOGGING AND DEBUGGING OPTIONS:
  --debug                 Enable debug mode
  --test:<value>          Perform specified test
"""

proc processArguments*(msg: var string): ConfigStatus =
  ## Process command line argument and update `NimbusConfiguration`.
  var opt = initOptParser()
  var length = 0
  for kind, key, value in opt.getopt():
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
          msg = getVersionString()
          result = Success
          break
        else:
          checkArgument processRpcArguments, key, value, msg
          checkArgument processNetArguments, key, value, msg
          checkArgument processDebugArguments, key, value, msg
    of cmdEnd:
      msg = "Error processing option [" & key & "]"
      result = ErrorParseOption
      break

  if length == 0 and result == Success:
    msg = getHelpString()
    result = Success

proc processConfig*(pathname: string): ConfigStatus =
  ## Process configuration file `pathname` and update `NimbusConfiguration`.
  result = Success
