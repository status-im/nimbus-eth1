# Nimbus
# Copyright (c) 2019-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[parseopt, strutils],
  results

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
    fork*: string
    index*: Opt[int]
    trace*: bool
    legacy*: bool
    subFixture*: Opt[int]
    json*: bool

var testConfig {.threadvar.}: Configuration

proc initConfiguration(): Configuration =
  result = new Configuration
  result.trace = true

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
      of "fork": config.fork = value
      of "index": config.index = Opt.some(parseInt(value))
      of "trace": config.trace = parseBool(value)
      of "legacy": config.legacy = parseBool(value)
      of "sub": config.subFixture = Opt.some(parseInt(value))
      of "json": config.json = parseBool(value)
      else:
        msg = "Unknown option " & key
        if value.len > 0: msg = msg & " : " & value
        result = ErrorUnknownOption
        break
    of cmdEnd:
      doAssert(false)
