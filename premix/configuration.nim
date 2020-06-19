import stint, os, parseopt, strutils
from ../nimbus/config import getDefaultDataDir, ConfigStatus, processInteger, PublicNetwork

export ConfigStatus

type
  PremixConfiguration* = ref object
    dataDir*: string
    head*: Uint256
    maxBlocks*: int
    numCommits*: int
    netId*: PublicNetwork

var premixConfig {.threadvar.}: PremixConfiguration

proc getConfiguration*(): PremixConfiguration {.gcsafe.}

proc initConfiguration(): PremixConfiguration =
  result = new PremixConfiguration

  const dataDir = getDefaultDataDir()

  result.dataDir = getHomeDir() / dataDir
  result.head = 0.u256
  result.maxBlocks = 0
  result.numCommits = 128
  result.netId = MainNet

proc getConfiguration*(): PremixConfiguration =
  if isNil(premixConfig):
    premixConfig = initConfiguration()
  result = premixConfig

proc processU256(val: string, o: var Uint256): ConfigStatus =
  if val.len > 2 and val[0] == '0' and val[1] == 'x':
    o = Uint256.fromHex(val)
  else:
    o = parse(val, Uint256)
  result = Success

proc processNetId(val: string, o: var PublicNetwork): ConfigStatus =
  case val.toLowerAscii()
  of "main": o = MainNet
  of "morden": o = MordenNet
  of "ropsten": o = RopstenNet
  of "rinkeby": o = RinkebyNet
  of "goerli": o = GoerliNet
  of "kovan": o = KovanNet

template checkArgument(fun, o: untyped) =
  ## Checks if arguments got processed successfully
  var res = (fun)(value, o)
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
        checkArgument processInteger, config.maxBlocks
      of "head":
        checkArgument processU256, config.head
      of "numcommits":
        checkArgument processInteger, config.numCommits
        config.numCommits = max(config.numCommits, 512)
      of "netid":
        checkArgument processNetId, config.netId
      else:
        msg = "Unknown option " & key
        if value.len > 0: msg = msg & " : " & value
        result = ErrorUnknownOption
        break
    of cmdEnd:
      msg = "Error processing option [" & key & "]"
      result = ErrorParseOption
      break
