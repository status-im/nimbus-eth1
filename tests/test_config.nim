import
  parseopt, strutils,
  ../nimbus/vm/interpreter/vm_forks

type
  ConfigStatus* = enum
    ## Configuration status flags
    Success,                      ## Success
    EmptyOption,                  ## No options in category
    ErrorUnknownOption,           ## Unknown option in command line found
    ErrorParseOption,             ## Error in parsing command line option
    ErrorIncorrectOption,         ## Option has incorrect value
    Error                         ## Unspecified error

  Configuration = ref object
    testSubject*: string
    fork*: Fork
    index*: int
    trace*: bool
    legacy*: bool
    pruning*: bool

var testConfig {.threadvar.}: Configuration

proc initConfiguration(): Configuration =
  result = new Configuration
  result.fork = FkFrontier
  result.index = 0
  result.trace = true
  result.pruning = true

proc getConfiguration*(): Configuration {.gcsafe.} =
  if isNil(testConfig):
    testConfig = initConfiguration()
  result = testConfig

proc processArguments*(msg: var string): ConfigStatus =
  var
    opt = initOptParser()
    config = getConfiguration()

  result = Success
  for kind, key, value in opt.getopt():
    case kind
    of cmdArgument:
      config.testSubject = key
    of cmdLongOption, cmdShortOption:
      case key.toLowerAscii()
      of "fork": config.fork = parseEnum[Fork](strip(value))
      of "index": config.index = parseInt(value)
      of "trace": config.trace = parseBool(value)
      of "legacy": config.legacy = parseBool(value)
      of "pruning": config.pruning = parseBool(value)
      else:
        msg = "Unknown option " & key
        if value.len > 0: msg = msg & " : " & value
        result = ErrorUnknownOption
        break
    of cmdEnd:
      doAssert(false)
