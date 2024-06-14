# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, parseopt, strutils],
  eth/common,
  stint,
  chronicles,
  ../nimbus/config

from ../nimbus/common/chain_config import
  MainNet,
  SepoliaNet,
  HoleskyNet

type
  ConfigStatus* = enum
    ## Configuration status flags
    Success,                      ## Success
    EmptyOption,                  ## No options in category
    ErrorUnknownOption,           ## Unknown option in command line found
    ErrorParseOption,             ## Error in parsing command line option
    ErrorIncorrectOption,         ## Option has incorrect value
    Error                         ## Unspecified error

  PremixConfiguration* = ref object
    dataDir*: string
    head*: BlockNumber
    maxBlocks*: int
    numCommits*: int
    netId*: NetworkId

var premixConfig {.threadvar.}: PremixConfiguration

proc getConfiguration*(): PremixConfiguration {.gcsafe.}

proc processInteger(v: string, o: var int): ConfigStatus =
  ## Convert string to integer.
  try:
    o  = parseInt(v)
    result = Success
  except ValueError:
    result = ErrorParseOption

proc initConfiguration(): PremixConfiguration =
  result = new PremixConfiguration

  const dataDir = defaultDataDir()

  result.dataDir = dataDir
  result.head = 0'u64
  result.maxBlocks = 0
  result.numCommits = 128
  result.netId = MainNet

proc getConfiguration*(): PremixConfiguration =
  if isNil(premixConfig):
    premixConfig = initConfiguration()
  result = premixConfig

proc processBlockNumber(val: string, o: var BlockNumber): ConfigStatus =
  if val.len > 2 and val[0] == '0' and val[1] == 'x':
    o = UInt256.fromHex(val).truncate(BlockNumber)
  else:
    o = parse(val, UInt256).truncate(BlockNumber)
  result = Success

func processNetId(val: string, o: var NetworkId): ConfigStatus =
  case val.toLowerAscii()
  of "main": o = MainNet
  of "sepolia": o = SepoliaNet
  of "holesky": o = HoleskyNet

template checkArgument(fun, o, value: untyped) =
  ## Checks if arguments got processed successfully
  let res = fun(value, o)
  if res == Success:
    continue
  elif res == ErrorParseOption:
    msg = "Error processing option [" & key & "] with value [" & value & "]"
    result = res
    break
  elif res == ErrorIncorrectOption:
    msg = "Incorrect value for option [" & key & "] value [" & value & "]"
    result = res
    break

proc processArguments*(msg: var string): ConfigStatus =
  var
    opt = initOptParser()
    length = 0
    config = getConfiguration()

  result = Success
  for kind, key, value in opt.getopt():
    case kind
    of cmdArgument:
      return EmptyOption
    of cmdLongOption, cmdShortOption:
      inc(length)
      case key.toLowerAscii()
      of "help":
        return EmptyOption
      of "datadir": config.dataDir = value
      of "maxblocks":
        checkArgument(processInteger, config.maxBlocks, value)
      of "head":
        checkArgument(processBlockNumber, config.head, value)
      of "numcommits":
        checkArgument(processInteger, config.numCommits, value)
        config.numCommits = max(config.numCommits, 512)
      of "netid":
        checkArgument(processNetId, config.netId, value)
      else:
        msg = "Unknown option " & key
        if value.len > 0: msg = msg & " : " & value
        return ErrorUnknownOption
    of cmdEnd:
      msg = "Error processing option [" & key & "]"
      return ErrorParseOption

  info "Using configuration parameters: ",
      datadir = config.dataDir,
      maxblocks = config.maxBlocks,
      head = config.head,
      numcommits = config.numCommits,
      netid = config.netId
