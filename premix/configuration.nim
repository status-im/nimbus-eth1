import
  std/[os, parseopt, strutils],
  eth/common, stint, ../nimbus/config

from ../nimbus/common/chain_config import
  MainNet,
  GoerliNet

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
    head*: UInt256
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
  result.head = 0.u256
  result.maxBlocks = 0
  result.numCommits = 128
  result.netId = MainNet

proc getConfiguration*(): PremixConfiguration =
  if isNil(premixConfig):
    premixConfig = initConfiguration()
  result = premixConfig

proc processU256(val: string, o: var UInt256): ConfigStatus =
  if val.len > 2 and val[0] == '0' and val[1] == 'x':
    o = UInt256.fromHex(val)
  else:
    o = parse(val, UInt256)
  result = Success

proc processNetId(val: string, o: var NetworkId): ConfigStatus =
  case val.toLowerAscii()
  of "main": o = MainNet
  of "goerli": o = GoerliNet

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
      discard
    of cmdLongOption, cmdShortOption:
      inc(length)
      case key.toLowerAscii()
      of "datadir": config.dataDir = value
      of "maxblocks":
        checkArgument(processInteger, config.maxBlocks, value)
      of "head":
        checkArgument(processU256, config.head, value)
      of "numcommits":
        checkArgument(processInteger, config.numCommits, value)
        config.numCommits = max(config.numCommits, 512)
      of "netid":
        checkArgument(processNetId, config.netId, value)
      else:
        msg = "Unknown option " & key
        if value.len > 0: msg = msg & " : " & value
        result = ErrorUnknownOption
        break
    of cmdEnd:
      msg = "Error processing option [" & key & "]"
      result = ErrorParseOption
      break
