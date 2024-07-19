# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import chronicles, "."/[config, transition]

# we are using chronicles LogLevel
# instead of our LogLevel
import types except LogLevel

template wrapException(body) =
  when wrapExceptionEnabled:
    try:
      body
    except T8NError as e:
      stderr.writeLine(e.msg)
      quit(e.exitCode.int)
    except CatchableError as e:
      stderr.writeLine($e.name & " : " & e.msg)
      quit(QuitFailure)
    except AssertionDefect as e:
      stderr.writeLine($e.name & " : " & e.msg)
      quit(QuitFailure)
  else:
    body

when defined(chronicles_runtime_filtering):
  proc toLogLevel(v: int): LogLevel =
    case v
    of 1: LogLevel.ERROR
    of 2: LogLevel.WARN
    of 3: LogLevel.INFO
    of 4: LogLevel.DEBUG
    of 5: LogLevel.TRACE
    else: LogLevel.NONE

  proc setVerbosity(v: int) =
    let level = v.toLogLevel
    setLogLevel(level)

proc main() =
  wrapException:
    let conf = T8NConf.init()
    when defined(chronicles_runtime_filtering):
      setVerbosity(conf.verbosity)
    var ctx = TransContext()
    ctx.transitionAction(conf)

main()
